# analytical-qaqc

Tools for loading laboratory assay certificates into SQL Server and preparing them for QA/QC.

## Stage 1: raw staging of ALS certificates

`load_als_staging.py` loads ALS certificate CSVs (`CSVRW_*.csv`) into a `lab` schema. Every value is stored **as text exactly as certificated**, for example `<0.005`, `>10.0` or `NSS`. No business rules are applied, and no existing (`dbo`) table is read or written. Rules for naming, detection limits, status codes and promotion to the production schema belong in a later stage.

### Setup

```bash
pip install -r requirements.txt
cp als_config.example.yaml als_config.yaml   # then set server, database, folder
```

Requires the Microsoft ODBC Driver 18 for SQL Server. `als_config.yaml` is git-ignored, so connection details and data paths stay local.

### Run

```bash
python load_als_staging.py --dry-run          # parse only, print a summary
python load_als_staging.py --create-schema    # first run: create lab.* then load
python load_als_staging.py                    # later runs: new/changed files only
python load_als_staging.py --file path\to\one.csv
```

Re-running is safe:

- Files are identified by SHA-256, and unchanged files are skipped.
- A changed file replaces that certificate's rows in a single transaction.
- Source files are never moved or modified.

### ALS certificate layout handled

```
AB12345678 - Finalized                      <- title: LABJOBNO - status
CLIENT : "..."                              <- header block, KEY : value
DATE RECEIVED : YYYY-MM-DD  DATE FINALIZED : YYYY-MM-DD   (two keys on one line)
...
,WEI-21,Au-AA23,ME-ICP41,...                <- method row
SAMPLE,Recvd Wt.,Au,Ag,...                  <- analyte row
DESCRIPTION,kg,ppm,ppm,...                  <- unit row
<sample>, 2.66,<0.005,<0.2,...              <- data lines
```

### Tables (`sql/01_lab_schema.sql`)

| Table | Grain | Holds |
|---|---|---|
| `lab.STG_FILE` | file | LABJOBNO, path, SHA-256, line/sample/value counts |
| `lab.STG_ALS_HEADER` | header key | TITLE, CERT STATUS, CLIENT, # OF SAMPLES, dates, PROJECT, comments, PO NUMBER |
| `lab.STG_ALS_COLUMN` | certificate column | LAB_METHOD / LAB_ANALYTE / LAB_UNIT |
| `lab.STG_ALS_SAMPLE` | data line | sample text, cell count, complete raw line |
| `lab.STG_ALS_VALUE` | non-blank cell | RAW_VALUE text |
| `lab.STG_LOAD_LOG` | run × file | loaded / reloaded / skipped / failed |
| `lab.V_STG_ALS_LONG` | view | values joined to their method/analyte/unit |

### Known quirks preserved as-is

- `Listed, NR` means "Listed Not Received". The comma splits it, so those lines carry one more cell than the header has. `CELL_COUNT` flags them.
- Other status values such as `Not Recvd` and `NSS` stay as text in `RAW_VALUE`.
- Repeat columns (e.g. `Au Check`) keep their own `COL_NO`.

## Stage 1b: raw staging of lab "Final Report" CSVs (ALS and Bureau Veritas)

`load_report_staging.py` loads the current ALS and Bureau Veritas / Inspectorate "Final Report" CSV layouts into `lab.STG_REPORT*` tables. As in stage 1, values are stored as text and no business rules are applied.

```bash
cp report_config.example.yaml report_config.yaml   # then set server, database, folder
python load_report_staging.py --dry-run
python load_report_staging.py --create-schema      # first run
python load_report_staging.py
```

Layout handled:

1. **Header block:** `Key:,value` lines, ended by the first blank line.
2. **Column-definition rows:** for example `Method:`, `Units:`, `Det. Lim:` (ALS) or `Method`, `Analyte`, `Unit`, `MDL` (BV). The block ends with the `SAMPLES` / `Sample` row.
3. **Sample rows:** one per line.

Encoding (UTF-8 with BOM, or Latin-1) is detected per file. Each report is keyed on its `Job Number:`.

| Table | Grain | Holds |
|---|---|---|
| `lab.STG_REPORT` | file | job number, first line, path, hash, encoding, counts |
| `lab.STG_REPORT_HEADER` | header line | raw label and value |
| `lab.STG_REPORT_COLUMN` | label × column | column attributes; `COL_NO` joins to values |
| `lab.STG_REPORT_ROW` | sample line | sample text, cell count, complete raw line |
| `lab.STG_REPORT_VALUE` | non-blank cell | `RAW_VALUE` text |
| `lab.V_STG_REPORT_VALUE` | view | values with their sample text |

## Next stages (planned)

- Business-rule transform: assay naming, detection-limit handling, status codes, check assays and sample-ID parsing.
- QA/QC checks: standards, blanks and duplicates.
- Additional lab formats.
