#!/usr/bin/env python
"""
Load lab "Final Report" CSVs (ALS and Bureau Veritas layouts) into raw staging.

    python load_report_staging.py --dry-run
    python load_report_staging.py --create-schema
    python load_report_staging.py --file path\\to\\report.csv

Splits each file into lab.STG_REPORT, STG_REPORT_HEADER, STG_REPORT_COLUMN,
STG_REPORT_ROW and STG_REPORT_VALUE. Values stay as text (trimmed); no business
rules are applied and no dbo table is touched. Runs are logged in lab.STG_LOAD_LOG.

Idempotent per Job Number: same file hash -> skipped; changed file -> replaced.
"""
from __future__ import annotations

import argparse
import csv
import glob
import hashlib
import io
import logging
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

import yaml

log = logging.getLogger("report_staging")
HERE = Path(__file__).resolve().parent


@dataclass
class Report:
    path: Path
    file_hash: str
    encoding: str
    line_count: int
    job_number: str = ""
    line1: str = ""
    header: list[tuple] = field(default_factory=list)   # (line_no, key, value)
    columns: list[tuple] = field(default_factory=list)  # (line_no, attr, col_no, value)
    column_rows: int = 0
    rows: list[tuple] = field(default_factory=list)     # (seq, line_no, sample, cells, raw)
    values: list[tuple] = field(default_factory=list)   # (seq, col_no, value)


def decode(data: bytes) -> tuple[str, str]:
    try:
        return data.decode("utf-8-sig"), "utf-8"
    except UnicodeDecodeError:
        return data.decode("latin-1"), "latin-1"


def nonblank(cells):
    return [(i, c.strip()) for i, c in enumerate(cells) if c.strip()]


def parse_report(path: Path, sample_labels: set[str], job_keys: set[str]) -> Report:
    data = path.read_bytes()
    text, enc = decode(data)
    lines = text.splitlines()
    rows = list(csv.reader(io.StringIO("\n".join(lines))))
    rep = Report(path, hashlib.sha256(data).hexdigest(), enc, len(lines))

    i = 0
    # ---- 1. header block (until first blank line)
    first = nonblank(rows[0]) if rows else []
    rep.line1 = " | ".join(c for _, c in first)
    i = 1
    while i < len(rows) and nonblank(rows[i]):
        cells = nonblank(rows[i])
        key, value = cells[0][1], " | ".join(c for _, c in cells[1:]) or None
        rep.header.append((i + 1, key, value))
        if key.rstrip(":").strip().lower() in job_keys and value:
            rep.job_number = value
        i += 1
    if not rep.job_number:
        raise ValueError("No 'Job Number' found in header block")

    # ---- 2. column-definition rows (until the SAMPLES / Sample row, inclusive)
    found_sample_row = False
    while i < len(rows):
        cells = nonblank(rows[i])
        i += 1
        if not cells:
            continue
        label_idx, label = cells[0]
        rep.column_rows += 1
        for idx, val in cells[1:]:
            rep.columns.append((i, label, idx + 1, val))
        if label.strip().lower() in sample_labels:
            found_sample_row = True
            break
    if not found_sample_row:
        raise ValueError(f"No sample header row labelled one of {sorted(sample_labels)}")

    # ---- 3. sample rows
    seq = 0
    while i < len(rows):
        r = rows[i]
        i += 1
        if not nonblank(r):
            continue
        seq += 1
        rep.rows.append((seq, i, r[0].strip(), len(r), lines[i - 1]))
        for idx, val in nonblank(r):
            if idx > 0:
                rep.values.append((seq, idx + 1, val))
    return rep


# --------------------------------------------------------------------------- #
def run_schema(conn):
    sql = (HERE / "sql" / "02_report_staging.sql").read_text()
    cur = conn.cursor()
    for batch in re.split(r"^\s*GO\s*$", sql, flags=re.M | re.I):
        if batch.strip():
            cur.execute(batch)
    conn.commit()
    log.info("Report staging tables are in place")


def log_run(cur, path, file_hash, job, status, message=None):
    cur.execute(
        "INSERT INTO lab.STG_LOAD_LOG (SOURCE_PATH, FILE_HASH, LABJOBNO, STATUS, MESSAGE) VALUES (?,?,?,?,?)",
        str(path), file_hash, job, status, (message or "")[:4000] or None,
    )


def load(conn, rep: Report) -> str:
    cur = conn.cursor()
    cur.fast_executemany = True
    j = rep.job_number
    cur.execute("SELECT FILE_HASH FROM lab.STG_REPORT WHERE JOB_NUMBER = ?", j)
    existing = cur.fetchone()
    if existing and existing[0] == rep.file_hash:
        log_run(cur, rep.path, rep.file_hash, j, "skipped", "already staged (same hash)")
        conn.commit()
        return "skipped"
    if existing:
        for t in ("STG_REPORT_VALUE", "STG_REPORT_ROW", "STG_REPORT_COLUMN", "STG_REPORT_HEADER", "STG_REPORT"):
            cur.execute(f"DELETE FROM lab.{t} WHERE JOB_NUMBER = ?", j)

    cur.execute(
        "INSERT INTO lab.STG_REPORT (JOB_NUMBER, REPORT_LINE1, SOURCE_PATH, FILE_HASH, FILE_ENCODING,"
        " LINE_COUNT, HEADER_LINES, COLUMN_ROWS, SAMPLE_ROWS, VALUE_CELLS) VALUES (?,?,?,?,?,?,?,?,?,?)",
        j, rep.line1, str(rep.path), rep.file_hash, rep.encoding, rep.line_count,
        len(rep.header), rep.column_rows, len(rep.rows), len(rep.values),
    )
    cur.executemany("INSERT INTO lab.STG_REPORT_HEADER VALUES (?,?,?,?)", [(j, *h) for h in rep.header])
    cur.executemany("INSERT INTO lab.STG_REPORT_COLUMN VALUES (?,?,?,?,?)", [(j, *c) for c in rep.columns])
    cur.executemany("INSERT INTO lab.STG_REPORT_ROW VALUES (?,?,?,?,?,?)", [(j, *r) for r in rep.rows])
    if rep.values:
        cur.executemany("INSERT INTO lab.STG_REPORT_VALUE VALUES (?,?,?,?)", [(j, *v) for v in rep.values])
    status = "reloaded" if existing else "loaded"
    log_run(cur, rep.path, rep.file_hash, j, status)
    conn.commit()
    return status


# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser(description="Stage lab Final Report CSVs (raw)")
    ap.add_argument("--config", default=str(HERE / "report_config.yaml"))
    ap.add_argument("--file", help="load one file instead of the config folder")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--create-schema", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s")

    cfg = yaml.safe_load(Path(args.config).read_text())
    src = cfg["source"]
    sample_labels = {s.lower() for s in src.get("sample_header_labels", ["SAMPLES", "Sample"])}
    job_keys = {s.lower() for s in src.get("job_number_keys", ["Job Number"])}
    if args.file:
        files = [Path(args.file)]
    else:
        files = sorted({Path(p) for pat in src.get("patterns", ["*.csv"])
                        for p in glob.glob(str(Path(src["folder"]) / pat))})
    log.info("%d file(s) to process", len(files))

    conn = None
    if not args.dry_run:
        import pyodbc
        conn = pyodbc.connect(cfg["database"]["odbc"], autocommit=False)
        if args.create_schema:
            run_schema(conn)

    stats: dict[str, int] = {}
    for f in files:
        file_hash = None
        try:
            rep = parse_report(f, sample_labels, job_keys)
            file_hash = rep.file_hash
            status = "parsed" if args.dry_run else load(conn, rep)
            log.info("%-8s %s  %s (%s): %d header, %d column rows / %d attrs, %d samples, %d values",
                     status, rep.job_number, f.name, rep.encoding, len(rep.header), rep.column_rows,
                     len(rep.columns), len(rep.rows), len(rep.values))
        except Exception as exc:
            status = "failed"
            log.error("failed   %s: %s", f.name, exc)
            if conn:
                conn.rollback()
                log_run(conn.cursor(), f, file_hash, None, "failed", str(exc))
                conn.commit()
        stats[status] = stats.get(status, 0) + 1

    if conn:
        conn.close()
    log.info("Done: %s", stats)
    sys.exit(1 if stats.get("failed") else 0)


if __name__ == "__main__":
    main()
