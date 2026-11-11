/* =====================================================================
   Raw staging for lab "Final Report" CSVs (ALS and Bureau Veritas layouts)

   Layout handled (both labs):
     1. Header block      "Key:,value" lines, ended by the first blank line
     2. Column rows       one row per attribute (Method, Units, Det. Lim, ...),
                          label in the first non-blank cell, values per column
                          ... ended by the row labelled SAMPLES / Sample
     3. Sample rows       first cell = sample text, other cells = values

   Everything is stored as TEXT exactly as in the file (trimmed only).
   No business rules, no references to dbo tables. Re-runnable.
   ===================================================================== */
IF SCHEMA_ID('lab') IS NULL EXEC('CREATE SCHEMA lab');
GO

/* One row per report file */
IF OBJECT_ID('lab.STG_REPORT') IS NULL
CREATE TABLE lab.STG_REPORT (
    JOB_NUMBER    varchar(30)    NOT NULL CONSTRAINT PK_lab_STG_REPORT PRIMARY KEY,  -- "Job Number:" value
    REPORT_LINE1  varchar(400)   NULL,      -- first line, non-blank cells joined with " | "
    SOURCE_PATH   varchar(400)   NOT NULL,
    FILE_HASH     char(64)       NOT NULL,
    FILE_ENCODING varchar(20)    NOT NULL,
    LINE_COUNT    int            NOT NULL,
    HEADER_LINES  int            NOT NULL,
    COLUMN_ROWS   int            NOT NULL,
    SAMPLE_ROWS   int            NOT NULL,
    VALUE_CELLS   int            NOT NULL,
    LOADED_AT     datetime2(0)   NOT NULL CONSTRAINT DF_lab_STG_REPORT_LOADED DEFAULT SYSDATETIME()
);
GO

/* Header block: one row per "Key:,value" line */
IF OBJECT_ID('lab.STG_REPORT_HEADER') IS NULL
CREATE TABLE lab.STG_REPORT_HEADER (
    JOB_NUMBER    varchar(30)    NOT NULL,
    LINE_NO       int            NOT NULL,  -- line in file (1-based)
    HDR_KEY       varchar(100)   NOT NULL,  -- raw label, e.g. "P.O. Number:"
    HDR_VALUE     varchar(4000)  NULL,      -- raw value (non-blank cells after the label)
    CONSTRAINT PK_lab_STG_REPORT_HEADER PRIMARY KEY (JOB_NUMBER, LINE_NO)
);
GO

/* Column-definition rows, long form: one row per attribute x column */
IF OBJECT_ID('lab.STG_REPORT_COLUMN') IS NULL
CREATE TABLE lab.STG_REPORT_COLUMN (
    JOB_NUMBER    varchar(30)    NOT NULL,
    LINE_NO       int            NOT NULL,  -- line in file
    ATTR_NAME     varchar(100)   NOT NULL,  -- raw label, e.g. "Method:", "Det. Lim:", "Analyte", "MDL"
    COL_NO        smallint       NOT NULL,  -- 1-based column in file; joins to STG_REPORT_VALUE.COL_NO
    ATTR_VALUE    varchar(100)   NOT NULL,
    CONSTRAINT PK_lab_STG_REPORT_COLUMN PRIMARY KEY (JOB_NUMBER, LINE_NO, COL_NO)
);
GO

/* Sample rows */
IF OBJECT_ID('lab.STG_REPORT_ROW') IS NULL
CREATE TABLE lab.STG_REPORT_ROW (
    JOB_NUMBER    varchar(30)    NOT NULL,
    ROW_SEQ       int            NOT NULL,  -- order in the sample section
    LINE_NO       int            NOT NULL,
    SAMPLE_TEXT   varchar(100)   NOT NULL,  -- column 1, raw
    CELL_COUNT    smallint       NOT NULL,
    RAW_LINE      varchar(4000)  NOT NULL,
    CONSTRAINT PK_lab_STG_REPORT_ROW PRIMARY KEY (JOB_NUMBER, ROW_SEQ)
);
GO

/* Sample values: one row per non-blank cell from column 2 onwards */
IF OBJECT_ID('lab.STG_REPORT_VALUE') IS NULL
CREATE TABLE lab.STG_REPORT_VALUE (
    JOB_NUMBER    varchar(30)    NOT NULL,
    ROW_SEQ       int            NOT NULL,
    COL_NO        smallint       NOT NULL,
    RAW_VALUE     varchar(100)   NOT NULL,
    CONSTRAINT PK_lab_STG_REPORT_VALUE PRIMARY KEY (JOB_NUMBER, ROW_SEQ, COL_NO)
);
GO

/* Values with their sample text (still raw) */
CREATE OR ALTER VIEW lab.V_STG_REPORT_VALUE AS
SELECT  r.JOB_NUMBER, r.ROW_SEQ, r.SAMPLE_TEXT, v.COL_NO, v.RAW_VALUE
FROM    lab.STG_REPORT_ROW r
JOIN    lab.STG_REPORT_VALUE v ON v.JOB_NUMBER = r.JOB_NUMBER AND v.ROW_SEQ = r.ROW_SEQ;
GO
