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

## Stage 2: business rules

The rules are data in the database, not code. `sql/03_business_rules.sql` creates the tables and procedures. `sql/04_rules_seed.sql` defines the rules and can be re-run safely.

```sql
EXEC lab.usp_RUN_BUSINESS_RULES;                          -- all non-INACTIVE rules
EXEC lab.usp_RUN_BUSINESS_RULES @Label = 'DespatchSend';  -- one label
EXEC lab.usp_RUN_BUSINESS_RULES @RuleId = 1;              -- one rule
SELECT * FROM lab.V_RULE_RESULT_LATEST;                   -- latest outcome per rule / report
```

| Table | Holds |
|---|---|
| `lab.BUSINESS_RULE_LABEL` | Rule groups and `LABEL_ORDER`; labels run lowest first |
| `lab.BUSINESS_RULE` | One row per rule: label, `RUN_ORDER` within the label, type, level, `FLAG` |
| `lab.BUSINESS_RULE_STEP` | Ordered steps for CHAIN rules |
| `lab.BUSINESS_RULE_PARAM` | Parameter values for a rule, e.g. the prefixes an IGNORE rule uses |
| `lab.RULE_RUN` / `lab.RULE_RESULT` | Run history and every outcome, including the value a rule resolved |
| `lab.V_STG_SAMPLE_IGNORED` | Sample lines excluded by active IGNORE rules, with the reason |
| `lab.V_STG_SAMPLE_IN_SCOPE` | Sample lines left after ignoring; sample-level rules read from this |

**FLAG** can be `PASS`, `WARN`, `FAIL` or `INACTIVE`:

- **On a rule:** how a failure is reported, or `INACTIVE` to skip the rule.
- **On a step:** the outcome when that step matches, or `INACTIVE` to skip the step.
- **On a param:** the outcome recorded when that value applies, or `INACTIVE` to switch the value off.

**Rule types:**

- **CHAIN:** ordered fallback steps, where the first step that matches wins. Each step reads a value from a source and tests a condition:
  - **Source:** a report header line (`HEADER`) or a `lab.STG_REPORT` column (`REPORT`).
  - **Condition:** `NOT_BLANK`, or `EXISTS` in a lookup table and column.

  If no step matches, the rule's FLAG is used. Each result records the winning step, the value it produced, and every step tried.
- **SQL:** a single `SELECT` returning `JOB_NUMBER`, `SAMPLE_TEXT`, `OUTCOME` (PASS/WARN/FAIL), `DETAIL` and `RESOLVED_VALUE`. A FAIL is reported using the rule's FLAG. Sample-level SQL rules should read `lab.V_STG_SAMPLE_IN_SCOPE`.
- **IGNORE_PREFIX:** sample lines that start with an active `PREFIX` param are taken out of scope. Matching is exact, including trailing spaces.
- **IGNORE_REPEAT_OF:** a lab repeat line is taken out of scope when both of these hold:
  - it starts with an active `REPEAT_PREFIX`, e.g. `REP `;
  - its parent ID is a check in `QV_SAMPLE_CHECK` whose DuplicateNo is an active `PARENT_DUPLICATENO`, e.g. `FSTD`.

Rules only read data and never modify staging or production tables.

**Current rules:**

| Order | Label | Rule | Type | What it does |
|---|---|---|---|---|
| 10 | DespatchSend | R001 Resolve DespatchNo | CHAIN | P.O. Number in `DESPATCHSEND`, else Shipment ID in `DESPATCHSEND`, else the lab job number |
| 20 | SampleFilter | R002 Ignore samples by prefix | IGNORE_PREFIX | Drops lab-internal QC lines: `STD`, `BLK` |
| 20 | SampleFilter | R005 Ignore lab repeats of field standards | IGNORE_REPEAT_OF | Drops `REP ` lines whose parent is an `FSTD` check |
| 30 | SampleDespatch | R003 SampleID exists in database | SQL | In-scope SampleID is in `QV_SAMPLE_CHECK` |
| 30 | SampleDespatch | R004 Sample on DespatchNo | SQL | (DespatchNo, SampleID, DuplicateNo) is in `QV_SAMPLE_CHECK_DESPATCH`; records the DuplicateNo found (e.g. `UMPREP` on umpire despatches) |

## Next stages (planned)

- Business-rule transform: assay naming, detection-limit handling, status codes, check assays and sample-ID parsing.
- QA/QC checks: standards, blanks and duplicates.
- Additional lab formats.
