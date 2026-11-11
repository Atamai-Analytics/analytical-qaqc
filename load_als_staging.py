#!/usr/bin/env python
"""
Load ALS certificate CSVs (CSVRW_*.csv) into raw staging tables in SQL Server.

    python load_als_staging.py                      # load all files in the config folder
    python load_als_staging.py --dry-run            # parse only, print a summary
    python load_als_staging.py --create-schema      # run sql/01_lab_schema.sql first
    python load_als_staging.py --file <path.csv>    # one file

What it does: splits each certificate into
  lab.STG_ALS_HEADER  (KEY : value lines)     lab.STG_ALS_COLUMN (method/analyte/unit rows)
  lab.STG_ALS_SAMPLE  (each data line, raw)   lab.STG_ALS_VALUE  (each non-blank cell, raw text)
and records the file in lab.STG_FILE / lab.STG_LOAD_LOG.

What it does NOT do: any business rule. Values stay text ("<0.005", "Listed", "NSS"),
nothing is renamed or converted, and no acQuire (dbo) table is touched.

Idempotent: a file whose LABJOBNO is already staged with the same SHA-256 is skipped;
a changed file replaces that certificate's rows. Each file is one transaction.
"""
from __future__ import annotations

import argparse
import csv
import glob
import hashlib
import logging
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

import yaml

log = logging.getLogger("als_staging")
HERE = Path(__file__).resolve().parent

# "KEY : value" pairs; one line can hold two ("DATE RECEIVED : x  DATE FINALIZED : y")
HDR_PAIR = re.compile(r'([#A-Za-z][#A-Za-z ]*?)\s+:\s+("(?:[^"]|"")*"|\S+)')


@dataclass
class Certificate:
    path: Path
    file_hash: str
    file_bytes: int
    line_count: int
    labjobno: str = ""
    header: list[tuple] = field(default_factory=list)   # (line_no, key, value)
    columns: list[tuple] = field(default_factory=list)  # (col_no, method, analyte, unit)
    samples: list[tuple] = field(default_factory=list)  # (seq, line_no, text, cells, raw)
    values: list[tuple] = field(default_factory=list)   # (seq, col_no, raw_value)


def parse_als(path: Path, encoding: str) -> Certificate:
    data = path.read_bytes()
    text = data.decode(encoding)
    lines = text.splitlines()
    cert = Certificate(path, hashlib.sha256(data).hexdigest(), len(data), len(lines))

    # --- title line: "AB12345678 - Finalized"
    title = lines[0].strip()
    m = re.match(r"^(\S+)\s*-\s*(.*)$", title)
    if not m:
        raise ValueError(f"Unrecognised title line: {title!r}")
    cert.labjobno = m.group(1)
    cert.header.append((1, "TITLE", title))
    cert.header.append((1, "CERT STATUS", m.group(2).strip()))

    # --- locate the 3 column-header rows: method row, "SAMPLE" row, "DESCRIPTION" row
    rows = [next(csv.reader([ln])) if ln.strip() else [] for ln in lines]
    try:
        s_idx = next(i for i, r in enumerate(rows) if r and r[0].strip().upper() == "SAMPLE")
    except StopIteration:
        raise ValueError("No SAMPLE header row found")
    if s_idx < 2 or not rows[s_idx + 1] or rows[s_idx + 1][0].strip().upper() != "DESCRIPTION":
        raise ValueError("Expected method row above and DESCRIPTION row below SAMPLE row")

    # --- header block between title and method row
    for i in range(1, s_idx - 1):
        ln = lines[i].strip()
        if not ln:
            continue
        pairs = HDR_PAIR.findall(ln)
        if not pairs:
            cert.header.append((i + 1, f"LINE {i + 1}", ln))
        for key, val in pairs:
            val = val[1:-1].replace('""', '"') if val.startswith('"') else val
            cert.header.append((i + 1, key.strip().upper(), val.strip()))

    methods, analytes, units = rows[s_idx - 1], rows[s_idx], rows[s_idx + 1]
    width = max(len(methods), len(analytes), len(units))
    cell = lambda r, k: (r[k].strip() or None) if k < len(r) else None
    for k in range(1, width):
        cert.columns.append((k, cell(methods, k), cell(analytes, k), cell(units, k)))

    # --- data section
    seq = 0
    for i in range(s_idx + 2, len(lines)):
        r = rows[i]
        if not r or not any(c.strip() for c in r):
            continue
        seq += 1
        cert.samples.append((seq, i + 1, r[0].strip(), len(r), lines[i]))
        for k in range(1, len(r)):
            v = r[k].strip()
            if v:
                cert.values.append((seq, k, v))
    return cert


# --------------------------------------------------------------------------- #
def connect(odbc: str):
    import pyodbc

    conn = pyodbc.connect(odbc, autocommit=False)
    return conn


def run_schema(conn):
    sql = (HERE / "sql" / "01_lab_schema.sql").read_text()
    cur = conn.cursor()
    for batch in re.split(r"^\s*GO\s*$", sql, flags=re.M | re.I):
        if batch.strip():
            cur.execute(batch)
    conn.commit()
    log.info("Schema lab.* is in place")


def log_run(cur, path, file_hash, labjobno, status, message=None):
    cur.execute(
        "INSERT INTO lab.STG_LOAD_LOG (SOURCE_PATH, FILE_HASH, LABJOBNO, STATUS, MESSAGE) VALUES (?,?,?,?,?)",
        str(path), file_hash, labjobno, status, (message or "")[:4000] or None,
    )


def load(conn, cert: Certificate) -> str:
    cur = conn.cursor()
    cur.fast_executemany = True
    cur.execute("SELECT FILE_HASH, SOURCE_PATH FROM lab.STG_FILE WHERE LABJOBNO = ?", cert.labjobno)
    existing = cur.fetchone()
    if existing and existing[0] == cert.file_hash:
        log_run(cur, cert.path, cert.file_hash, cert.labjobno, "skipped", "already staged (same hash)")
        conn.commit()
        return "skipped"

    status = "reloaded" if existing else "loaded"
    j = cert.labjobno
    if existing:
        for t in ("STG_ALS_VALUE", "STG_ALS_SAMPLE", "STG_ALS_COLUMN", "STG_ALS_HEADER", "STG_FILE"):
            cur.execute(f"DELETE FROM lab.{t} WHERE LABJOBNO = ?", j)

    cur.execute(
        "INSERT INTO lab.STG_FILE (LABJOBNO, LAB_SOURCE, SOURCE_PATH, FILE_HASH, FILE_BYTES, LINE_COUNT,"
        " SAMPLE_LINES, VALUE_CELLS) VALUES (?,?,?,?,?,?,?,?)",
        j, "ALS", str(cert.path), cert.file_hash, cert.file_bytes, cert.line_count,
        len(cert.samples), len(cert.values),
    )
    cur.executemany("INSERT INTO lab.STG_ALS_HEADER VALUES (?,?,?,?)", [(j, *h) for h in cert.header])
    cur.executemany("INSERT INTO lab.STG_ALS_COLUMN VALUES (?,?,?,?,?)", [(j, *c) for c in cert.columns])
    cur.executemany("INSERT INTO lab.STG_ALS_SAMPLE VALUES (?,?,?,?,?,?)", [(j, *s) for s in cert.samples])
    if cert.values:
        cur.executemany("INSERT INTO lab.STG_ALS_VALUE VALUES (?,?,?,?)", [(j, *v) for v in cert.values])
    log_run(cur, cert.path, cert.file_hash, j, status)
    conn.commit()
    return status


# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser(description="Stage ALS certificate CSVs (raw)")
    ap.add_argument("--config", default=str(HERE / "als_config.yaml"))
    ap.add_argument("--file", help="load a single file instead of the config folder")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--create-schema", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(message)s")

    cfg = yaml.safe_load(Path(args.config).read_text())
    src = cfg["source"]
    files = [Path(args.file)] if args.file else sorted(
        Path(p) for p in glob.glob(str(Path(src["folder"]) / src.get("pattern", "*.csv")))
    )
    log.info("%d file(s) to process", len(files))

    conn = None if args.dry_run else connect(cfg["database"]["odbc"])
    if conn and args.create_schema:
        run_schema(conn)

    stats: dict[str, int] = {}
    for f in files:
        file_hash = None
        try:
            cert = parse_als(f, src.get("encoding", "latin-1"))
            file_hash = cert.file_hash
            if args.dry_run:
                status = "parsed"
            else:
                status = load(conn, cert)
            log.info("%-9s %s  %s: %d header, %d cols, %d samples, %d values",
                     status, cert.labjobno, f.name, len(cert.header), len(cert.columns),
                     len(cert.samples), len(cert.values))
        except Exception as exc:
            status = "failed"
            log.error("failed    %s: %s", f.name, exc)
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
