/* =====================================================================
   Raw staging for ALS laboratory certificates (SQL Server)

   Landing zone only: every value is stored as TEXT exactly as it appears
   in the certificate file. No business rules are applied here (no assay
   name mapping, no detection-limit / status interpretation, no type casts).
   Nothing references or writes to acQuire (dbo) tables.

   Re-runnable: creates objects only if missing.
   ===================================================================== */
IF SCHEMA_ID('lab') IS NULL EXEC('CREATE SCHEMA lab');
GO

/* Certificate header block: one row per header line ("KEY : value") */
IF OBJECT_ID('lab.STG_ALS_HEADER') IS NULL
CREATE TABLE lab.STG_ALS_HEADER (
    LABJOBNO     varchar(20)    NOT NULL,   -- from title line, e.g. AB12345678
    LINE_NO      smallint       NOT NULL,   -- line number in file (1-based)
    HDR_KEY      varchar(100)   NOT NULL,   -- e.g. CLIENT, DATE RECEIVED, TITLE
    HDR_VALUE    varchar(4000)  NULL,       -- raw text, quotes stripped
    CONSTRAINT PK_lab_STG_ALS_HEADER PRIMARY KEY (LABJOBNO, LINE_NO, HDR_KEY)
);
GO

/* The three column-header rows: method / analyte / unit, per column */
IF OBJECT_ID('lab.STG_ALS_COLUMN') IS NULL
CREATE TABLE lab.STG_ALS_COLUMN (
    LABJOBNO     varchar(20)    NOT NULL,
    COL_NO       smallint       NOT NULL,   -- 1 = first column after SAMPLE
    LAB_METHOD   varchar(50)    NULL,       -- e.g. ME-ICP41
    LAB_ANALYTE  varchar(50)    NULL,       -- e.g. Au Check
    LAB_UNIT     varchar(20)    NULL,       -- e.g. %
    CONSTRAINT PK_lab_STG_ALS_COLUMN PRIMARY KEY (LABJOBNO, COL_NO)
);
GO

/* Sample lines: one row per line in the data section */
IF OBJECT_ID('lab.STG_ALS_SAMPLE') IS NULL
CREATE TABLE lab.STG_ALS_SAMPLE (
    LABJOBNO     varchar(20)    NOT NULL,
    SAMPLE_SEQ   int            NOT NULL,   -- order within the data section
    LINE_NO      int            NOT NULL,   -- line number in file
    SAMPLE_TEXT  varchar(100)   NOT NULL,   -- first cell, raw (e.g. "WR-3-585-590")
    CELL_COUNT   smallint       NOT NULL,   -- cells on the line (flags ragged rows)
    RAW_LINE     varchar(4000)  NOT NULL,   -- complete original line
    CONSTRAINT PK_lab_STG_ALS_SAMPLE PRIMARY KEY (LABJOBNO, SAMPLE_SEQ)
);
GO

/* Cell values: one row per non-blank cell after the SAMPLE column */
IF OBJECT_ID('lab.STG_ALS_VALUE') IS NULL
CREATE TABLE lab.STG_ALS_VALUE (
    LABJOBNO     varchar(20)    NOT NULL,
    SAMPLE_SEQ   int            NOT NULL,
    COL_NO       smallint       NOT NULL,   -- may exceed header width on ragged rows
    RAW_VALUE    varchar(100)   NOT NULL,   -- trimmed text, e.g. "<0.005", " 1.270" -> "1.270"
    CONSTRAINT PK_lab_STG_ALS_VALUE PRIMARY KEY (LABJOBNO, SAMPLE_SEQ, COL_NO)
);
GO

/* One row per file loaded into staging */
IF OBJECT_ID('lab.STG_FILE') IS NULL
CREATE TABLE lab.STG_FILE (
    LABJOBNO     varchar(20)    NOT NULL CONSTRAINT PK_lab_STG_FILE PRIMARY KEY,
    LAB_SOURCE   varchar(20)    NOT NULL,   -- ALS
    SOURCE_PATH  varchar(400)   NOT NULL,
    FILE_HASH    char(64)       NOT NULL,
    FILE_BYTES   int            NOT NULL,
    LINE_COUNT   int            NOT NULL,
    SAMPLE_LINES int            NOT NULL,
    VALUE_CELLS  int            NOT NULL,
    LOADED_AT    datetime2(0)   NOT NULL CONSTRAINT DF_lab_STG_FILE_LOADED DEFAULT SYSDATETIME()
);
GO

/* Run history, including skipped / failed files */
IF OBJECT_ID('lab.STG_LOAD_LOG') IS NULL
CREATE TABLE lab.STG_LOAD_LOG (
    LOAD_ID      int IDENTITY   CONSTRAINT PK_lab_STG_LOAD_LOG PRIMARY KEY,
    SOURCE_PATH  varchar(400)   NOT NULL,
    FILE_HASH    char(64)       NULL,
    LABJOBNO     varchar(20)    NULL,
    STATUS       varchar(10)    NOT NULL,   -- loaded | reloaded | skipped | failed
    MESSAGE      varchar(4000)  NULL,
    RUN_AT       datetime2(0)   NOT NULL CONSTRAINT DF_lab_STG_LOAD_LOG_RUN DEFAULT SYSDATETIME()
);
GO

/* Convenience view: values joined to their column headers (still raw text) */
CREATE OR ALTER VIEW lab.V_STG_ALS_LONG AS
SELECT  s.LABJOBNO, s.SAMPLE_SEQ, s.SAMPLE_TEXT,
        v.COL_NO, c.LAB_METHOD, c.LAB_ANALYTE, c.LAB_UNIT, v.RAW_VALUE
FROM    lab.STG_ALS_SAMPLE s
JOIN    lab.STG_ALS_VALUE  v ON v.LABJOBNO = s.LABJOBNO AND v.SAMPLE_SEQ = s.SAMPLE_SEQ
LEFT JOIN lab.STG_ALS_COLUMN c ON c.LABJOBNO = v.LABJOBNO AND c.COL_NO = v.COL_NO;
GO
