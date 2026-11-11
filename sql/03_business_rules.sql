/* =====================================================================
   Business rules for staged lab reports

   lab.BUSINESS_RULE_LABEL  rule groups and the order they run in (LABEL_ORDER)
   lab.BUSINESS_RULE        one row per rule; RULE_LABEL groups rules (e.g. DespatchSend),
                            RUN_ORDER orders rules within their label
   lab.BUSINESS_RULE_STEP   ordered steps for CHAIN rules (first match wins)
   lab.RULE_RUN             one row per execution of the rule runner
   lab.RULE_RESULT          one row per rule x report (or x sample) outcome
   lab.usp_RUN_BUSINESS_RULES   runs all non-INACTIVE rules (or one) and logs results
   lab.usp_EVAL_CHAIN_RULE      evaluator for CHAIN rules (called by the runner)
   lab.V_RULE_RESULT_LATEST     latest outcome per rule / report / sample

   FLAG (PASS | WARN | FAIL | INACTIVE)
     Rule  FLAG = how a failure of the rule is reported. FAIL = hard failure,
                  WARN = warning only, PASS = informational. INACTIVE = rule is skipped.
     Step  FLAG = the outcome when this step matches. INACTIVE = step is skipped.

   Two rule types:

   CHAIN  Ordered steps. Each step reads a value from a SOURCE and tests a CONDITION.
          The first step whose condition is true wins. Its FLAG and value are
          recorded (RESOLVED_STEP, RESOLVED_VALUE). If no step matches, the
          rule's FLAG is recorded.
            SOURCE_TYPE  HEADER  -> lab.STG_REPORT_HEADER.HDR_VALUE where HDR_KEY = SOURCE_KEY
                         REPORT  -> column SOURCE_KEY of lab.STG_REPORT (e.g. JOB_NUMBER)
            CONDITION    NOT_BLANK -> value is not empty
                         EXISTS    -> value exists in LOOKUP_TABLE.LOOKUP_COLUMN

   SQL    CHECK_SQL is a single SELECT returning exactly:
            JOB_NUMBER varchar(30), SAMPLE_TEXT varchar(100) NULL,
            OUTCOME varchar(10) (PASS | FAIL), DETAIL varchar(4000)
          A FAIL row is recorded with the rule's FLAG (FAIL or WARN or PASS).

   Rules only read data; they never modify staging or dbo tables.
   Re-runnable: creates objects, or upgrades ones made by earlier versions.
   ===================================================================== */
IF SCHEMA_ID('lab') IS NULL EXEC('CREATE SCHEMA lab');
GO

/* ---------------------------------------------------------------- labels */
IF OBJECT_ID('lab.BUSINESS_RULE_LABEL') IS NULL
CREATE TABLE lab.BUSINESS_RULE_LABEL (
    RULE_LABEL   varchar(50)    NOT NULL CONSTRAINT PK_lab_BUSINESS_RULE_LABEL PRIMARY KEY,
    LABEL_ORDER  int            NOT NULL,          -- labels run in this order (10, 20, 30 ...)
    DESCRIPTION  varchar(4000)  NULL
);
GO
IF NOT EXISTS (SELECT 1 FROM lab.BUSINESS_RULE_LABEL WHERE RULE_LABEL = 'Unlabelled')
    INSERT lab.BUSINESS_RULE_LABEL (RULE_LABEL, LABEL_ORDER, DESCRIPTION)
    VALUES ('Unlabelled', 9999, 'Default for rules added without a label; runs last.');
GO

/* ---------------------------------------------------------------- rules */
IF OBJECT_ID('lab.BUSINESS_RULE') IS NULL
CREATE TABLE lab.BUSINESS_RULE (
    RULE_ID      int            NOT NULL CONSTRAINT PK_lab_BUSINESS_RULE PRIMARY KEY,
    RULE_CODE    varchar(50)    NOT NULL CONSTRAINT UQ_lab_BUSINESS_RULE_CODE UNIQUE,
    RULE_LABEL   varchar(50)    NOT NULL CONSTRAINT DF_lab_BUSINESS_RULE_LABEL DEFAULT 'Unlabelled'
                                CONSTRAINT FK_lab_BUSINESS_RULE_LABEL
                                REFERENCES lab.BUSINESS_RULE_LABEL (RULE_LABEL),  -- group, e.g. DespatchSend
    RULE_NAME    varchar(200)   NOT NULL,
    DESCRIPTION  varchar(4000)  NULL,
    RULE_TYPE    varchar(10)    NOT NULL CONSTRAINT DF_lab_BUSINESS_RULE_TYPE DEFAULT 'SQL'
                                CONSTRAINT CK_lab_BUSINESS_RULE_TYPE CHECK (RULE_TYPE IN ('SQL','CHAIN')),
    RULE_LEVEL   varchar(10)    NOT NULL CONSTRAINT CK_lab_BUSINESS_RULE_LEVEL
                                CHECK (RULE_LEVEL IN ('REPORT','SAMPLE','VALUE')),
    FLAG         varchar(10)    NOT NULL CONSTRAINT DF_lab_BUSINESS_RULE_FLAG DEFAULT 'FAIL'
                                CONSTRAINT CK_lab_BUSINESS_RULE_FLAG CHECK (FLAG IN ('PASS','WARN','FAIL','INACTIVE')),
    RUN_ORDER    int            NOT NULL CONSTRAINT DF_lab_BUSINESS_RULE_ORDER DEFAULT 100,  -- order within the label
    CHECK_SQL    nvarchar(max)  NULL,
    NOTES        varchar(4000)  NULL,
    CREATED_AT   datetime2(0)   NOT NULL CONSTRAINT DF_lab_BUSINESS_RULE_CREATED DEFAULT SYSDATETIME(),
    UPDATED_AT   datetime2(0)   NOT NULL CONSTRAINT DF_lab_BUSINESS_RULE_UPDATED DEFAULT SYSDATETIME()
);
GO

/* ---------------------------------------------------------------- steps */
IF OBJECT_ID('lab.BUSINESS_RULE_STEP') IS NULL
CREATE TABLE lab.BUSINESS_RULE_STEP (
    RULE_ID       int           NOT NULL CONSTRAINT FK_lab_RULE_STEP_RULE
                                REFERENCES lab.BUSINESS_RULE (RULE_ID) ON DELETE CASCADE,
    STEP_NO       int           NOT NULL,          -- evaluation order (10, 20, 30 ...)
    STEP_NAME     varchar(200)  NOT NULL,
    SOURCE_TYPE   varchar(10)   NOT NULL CONSTRAINT CK_lab_RULE_STEP_SRC
                                CHECK (SOURCE_TYPE IN ('HEADER','REPORT')),
    SOURCE_KEY    varchar(128)  NOT NULL,          -- HDR_KEY, or STG_REPORT column name
    CONDITION     varchar(20)   NOT NULL CONSTRAINT CK_lab_RULE_STEP_COND
                                CHECK (CONDITION IN ('NOT_BLANK','EXISTS')),
    LOOKUP_TABLE  varchar(256)  NULL,              -- schema.table, for EXISTS
    LOOKUP_COLUMN varchar(128)  NULL,              -- column,       for EXISTS
    FLAG          varchar(10)   NOT NULL CONSTRAINT DF_lab_RULE_STEP_FLAG DEFAULT 'PASS'
                                CONSTRAINT CK_lab_RULE_STEP_FLAG CHECK (FLAG IN ('PASS','WARN','FAIL','INACTIVE')),
    NOTES         varchar(4000) NULL,
    CONSTRAINT PK_lab_BUSINESS_RULE_STEP PRIMARY KEY (RULE_ID, STEP_NO),
    CONSTRAINT CK_lab_RULE_STEP_LOOKUP CHECK (CONDITION <> 'EXISTS'
        OR (LOOKUP_TABLE IS NOT NULL AND LOOKUP_COLUMN IS NOT NULL))
);
GO

/* ---------------------------------------------------------------- upgrade earlier versions
   v1/v2 used IS_ACTIVE + SEVERITY + NO_MATCH_OUTCOME (rules) and IS_ACTIVE + OUTCOME (steps).
   Add FLAG, carry values across, then drop the old columns and their constraints. */
IF COL_LENGTH('lab.BUSINESS_RULE', 'RULE_TYPE') IS NULL
    ALTER TABLE lab.BUSINESS_RULE ADD RULE_TYPE varchar(10) NOT NULL
        CONSTRAINT DF_lab_BUSINESS_RULE_TYPE DEFAULT 'SQL'
        CONSTRAINT CK_lab_BUSINESS_RULE_TYPE CHECK (RULE_TYPE IN ('SQL','CHAIN'));
IF COL_LENGTH('lab.BUSINESS_RULE', 'RULE_LABEL') IS NULL
    ALTER TABLE lab.BUSINESS_RULE ADD RULE_LABEL varchar(50) NOT NULL
        CONSTRAINT DF_lab_BUSINESS_RULE_LABEL DEFAULT 'Unlabelled';
GO
/* every label used by a rule must exist in BUSINESS_RULE_LABEL before the FK is added */
INSERT lab.BUSINESS_RULE_LABEL (RULE_LABEL, LABEL_ORDER)
SELECT DISTINCT r.RULE_LABEL, 1000
FROM lab.BUSINESS_RULE r
WHERE NOT EXISTS (SELECT 1 FROM lab.BUSINESS_RULE_LABEL l WHERE l.RULE_LABEL = r.RULE_LABEL);
IF OBJECT_ID('lab.FK_lab_BUSINESS_RULE_LABEL', 'F') IS NULL
    ALTER TABLE lab.BUSINESS_RULE ADD CONSTRAINT FK_lab_BUSINESS_RULE_LABEL
        FOREIGN KEY (RULE_LABEL) REFERENCES lab.BUSINESS_RULE_LABEL (RULE_LABEL);
GO
IF COL_LENGTH('lab.BUSINESS_RULE', 'FLAG') IS NULL
    ALTER TABLE lab.BUSINESS_RULE ADD FLAG varchar(10) NOT NULL
        CONSTRAINT DF_lab_BUSINESS_RULE_FLAG DEFAULT 'FAIL'
        CONSTRAINT CK_lab_BUSINESS_RULE_FLAG CHECK (FLAG IN ('PASS','WARN','FAIL','INACTIVE'));
IF COL_LENGTH('lab.BUSINESS_RULE_STEP', 'FLAG') IS NULL
    ALTER TABLE lab.BUSINESS_RULE_STEP ADD FLAG varchar(10) NOT NULL
        CONSTRAINT DF_lab_RULE_STEP_FLAG DEFAULT 'PASS'
        CONSTRAINT CK_lab_RULE_STEP_FLAG CHECK (FLAG IN ('PASS','WARN','FAIL','INACTIVE'));
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('lab.BUSINESS_RULE')
           AND name = 'CHECK_SQL' AND is_nullable = 0)
    ALTER TABLE lab.BUSINESS_RULE ALTER COLUMN CHECK_SQL nvarchar(max) NULL;
GO
DECLARE @mig nvarchar(max);
IF COL_LENGTH('lab.BUSINESS_RULE', 'IS_ACTIVE') IS NOT NULL
BEGIN
    SET @mig = N'UPDATE lab.BUSINESS_RULE SET FLAG = CASE WHEN IS_ACTIVE = 0 THEN ''INACTIVE'' '
             + CASE WHEN COL_LENGTH('lab.BUSINESS_RULE', 'NO_MATCH_OUTCOME') IS NOT NULL
                    THEN N'ELSE NO_MATCH_OUTCOME END' ELSE N'ELSE ''FAIL'' END' END;
    EXEC sp_executesql @mig;
END
IF COL_LENGTH('lab.BUSINESS_RULE_STEP', 'IS_ACTIVE') IS NOT NULL
   AND COL_LENGTH('lab.BUSINESS_RULE_STEP', 'OUTCOME') IS NOT NULL
BEGIN
    SET @mig = N'UPDATE lab.BUSINESS_RULE_STEP SET FLAG = CASE WHEN IS_ACTIVE = 0 THEN ''INACTIVE'' ELSE OUTCOME END';
    EXEC sp_executesql @mig;
END
GO
DECLARE @drop nvarchar(max) = N'';
SELECT @drop += N'ALTER TABLE lab.' + QUOTENAME(OBJECT_NAME(c.object_id))
              + N' DROP CONSTRAINT ' + QUOTENAME(k.name) + N'; '
FROM sys.columns c
JOIN (SELECT name, parent_object_id, parent_column_id FROM sys.default_constraints
      UNION ALL
      SELECT name, parent_object_id, parent_column_id FROM sys.check_constraints) k
  ON k.parent_object_id = c.object_id AND k.parent_column_id = c.column_id
WHERE (c.object_id = OBJECT_ID('lab.BUSINESS_RULE')      AND c.name IN ('IS_ACTIVE','SEVERITY','NO_MATCH_OUTCOME'))
   OR (c.object_id = OBJECT_ID('lab.BUSINESS_RULE_STEP') AND c.name IN ('IS_ACTIVE','OUTCOME'));
SELECT @drop += N'ALTER TABLE lab.' + QUOTENAME(OBJECT_NAME(c.object_id)) + N' DROP COLUMN ' + QUOTENAME(c.name) + N'; '
FROM sys.columns c
WHERE (c.object_id = OBJECT_ID('lab.BUSINESS_RULE')      AND c.name IN ('IS_ACTIVE','SEVERITY','NO_MATCH_OUTCOME'))
   OR (c.object_id = OBJECT_ID('lab.BUSINESS_RULE_STEP') AND c.name IN ('IS_ACTIVE','OUTCOME'));
IF @drop <> N'' EXEC sp_executesql @drop;
GO

/* ---------------------------------------------------------------- runs / results */
IF OBJECT_ID('lab.RULE_RUN') IS NULL
CREATE TABLE lab.RULE_RUN (
    RUN_ID        int IDENTITY  CONSTRAINT PK_lab_RULE_RUN PRIMARY KEY,
    STARTED_AT    datetime2(0)  NOT NULL CONSTRAINT DF_lab_RULE_RUN_START DEFAULT SYSDATETIME(),
    FINISHED_AT   datetime2(0)  NULL,
    RUN_BY        nvarchar(128) NOT NULL CONSTRAINT DF_lab_RULE_RUN_BY DEFAULT SUSER_SNAME(),
    RULES_RUN     int           NULL,
    RULES_ERRORED int           NULL
);
GO

IF OBJECT_ID('lab.RULE_RESULT') IS NULL
CREATE TABLE lab.RULE_RESULT (
    RESULT_ID      bigint IDENTITY CONSTRAINT PK_lab_RULE_RESULT PRIMARY KEY,
    RUN_ID         int           NOT NULL CONSTRAINT FK_lab_RULE_RESULT_RUN
                                 REFERENCES lab.RULE_RUN (RUN_ID) ON DELETE CASCADE,
    RULE_ID        int           NOT NULL CONSTRAINT FK_lab_RULE_RESULT_RULE
                                 REFERENCES lab.BUSINESS_RULE (RULE_ID),
    JOB_NUMBER     varchar(30)   NULL,
    SAMPLE_TEXT    varchar(100)  NULL,
    OUTCOME        varchar(10)   NOT NULL,   -- PASS | WARN | FAIL | ERROR (rule itself failed)
    DETAIL         varchar(4000) NULL,
    RESOLVED_STEP  int           NULL,       -- CHAIN: winning step
    RESOLVED_VALUE varchar(400)  NULL        -- CHAIN: value it produced
);
GO
IF COL_LENGTH('lab.RULE_RESULT', 'RESOLVED_STEP') IS NULL
    ALTER TABLE lab.RULE_RESULT ADD RESOLVED_STEP int NULL;
IF COL_LENGTH('lab.RULE_RESULT', 'RESOLVED_VALUE') IS NULL
    ALTER TABLE lab.RULE_RESULT ADD RESOLVED_VALUE varchar(400) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_lab_RULE_RESULT_RULE_JOB')
    CREATE INDEX IX_lab_RULE_RESULT_RULE_JOB ON lab.RULE_RESULT (RULE_ID, JOB_NUMBER, RUN_ID);
GO

/* ---------------------------------------------------------------- CHAIN evaluator */
CREATE OR ALTER PROCEDURE lab.usp_EVAL_CHAIN_RULE
    @RunId  int,
    @RuleId int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @step int, @stype varchar(10), @skey varchar(128), @cond varchar(20),
            @ltab varchar(256), @lcol varchar(128), @sql nvarchar(max), @lookup nvarchar(600);

    /* COLLATE DATABASE_DEFAULT: tempdb may use a different collation than this database */
    CREATE TABLE #v    (JOB_NUMBER varchar(30) COLLATE DATABASE_DEFAULT, VAL varchar(4000) COLLATE DATABASE_DEFAULT);
    CREATE TABLE #cand (JOB_NUMBER varchar(30) COLLATE DATABASE_DEFAULT, STEP_NO int,
                        VAL varchar(4000) COLLATE DATABASE_DEFAULT, MATCHED bit);

    DECLARE steps CURSOR LOCAL FAST_FORWARD FOR
        SELECT STEP_NO, SOURCE_TYPE, SOURCE_KEY, CONDITION, LOOKUP_TABLE, LOOKUP_COLUMN
        FROM lab.BUSINESS_RULE_STEP WHERE RULE_ID = @RuleId AND FLAG <> 'INACTIVE' ORDER BY STEP_NO;
    OPEN steps;
    FETCH NEXT FROM steps INTO @step, @stype, @skey, @cond, @ltab, @lcol;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        TRUNCATE TABLE #v;

        /* 1. read the candidate value for every staged report */
        IF @stype = 'HEADER'
            INSERT #v (JOB_NUMBER, VAL)
            SELECT r.JOB_NUMBER, NULLIF(LTRIM(RTRIM(h.HDR_VALUE)), '')
            FROM lab.STG_REPORT r
            LEFT JOIN lab.STG_REPORT_HEADER h ON h.JOB_NUMBER = r.JOB_NUMBER AND h.HDR_KEY = @skey;
        ELSE
        BEGIN
            IF COL_LENGTH('lab.STG_REPORT', @skey) IS NULL
                THROW 50001, 'Step SOURCE_KEY is not a column of lab.STG_REPORT', 1;
            SET @sql = N'INSERT #v (JOB_NUMBER, VAL) SELECT JOB_NUMBER, NULLIF(LTRIM(RTRIM(CAST('
                     + QUOTENAME(@skey) + N' AS varchar(4000)))), '''') FROM lab.STG_REPORT;';
            EXEC sp_executesql @sql;
        END

        /* 2. test the condition */
        IF @cond = 'NOT_BLANK'
            INSERT #cand SELECT JOB_NUMBER, @step, VAL, CASE WHEN VAL IS NULL THEN 0 ELSE 1 END FROM #v;
        ELSE  -- EXISTS
        BEGIN
            IF OBJECT_ID(@ltab) IS NULL OR COL_LENGTH(@ltab, @lcol) IS NULL
                THROW 50002, 'Step LOOKUP_TABLE / LOOKUP_COLUMN not found', 1;
            SET @lookup = QUOTENAME(ISNULL(PARSENAME(@ltab, 2), 'dbo')) + N'.' + QUOTENAME(PARSENAME(@ltab, 1));
            SET @sql = N'INSERT #cand SELECT v.JOB_NUMBER, @step, v.VAL,
                         CASE WHEN v.VAL IS NOT NULL AND EXISTS (SELECT 1 FROM ' + @lookup + N' t
                              WHERE t.' + QUOTENAME(@lcol) + N' = v.VAL) THEN 1 ELSE 0 END
                         FROM #v v;';
            EXEC sp_executesql @sql, N'@step int', @step;
        END

        FETCH NEXT FROM steps INTO @step, @stype, @skey, @cond, @ltab, @lcol;
    END
    CLOSE steps; DEALLOCATE steps;

    /* 3. first matching step wins (its FLAG); otherwise the rule's FLAG */
    ;WITH win AS (
        SELECT c.JOB_NUMBER, c.STEP_NO, c.VAL, s.FLAG, s.STEP_NAME,
               ROW_NUMBER() OVER (PARTITION BY c.JOB_NUMBER ORDER BY c.STEP_NO) AS rn
        FROM #cand c
        JOIN lab.BUSINESS_RULE_STEP s ON s.RULE_ID = @RuleId AND s.STEP_NO = c.STEP_NO
        WHERE c.MATCHED = 1
    ), trail AS (
        SELECT c.JOB_NUMBER,
               STRING_AGG(CAST(CONCAT(c.STEP_NO, ' ', s.STEP_NAME, ' = ', ISNULL(c.VAL, '(blank)'),
                          CASE WHEN c.MATCHED = 1 THEN ' [match]' ELSE ' [no]' END) AS varchar(max)), '; ')
                   WITHIN GROUP (ORDER BY c.STEP_NO) AS TRIED
        FROM #cand c
        JOIN lab.BUSINESS_RULE_STEP s ON s.RULE_ID = @RuleId AND s.STEP_NO = c.STEP_NO
        GROUP BY c.JOB_NUMBER
    )
    INSERT lab.RULE_RESULT (RUN_ID, RULE_ID, JOB_NUMBER, SAMPLE_TEXT, OUTCOME, DETAIL, RESOLVED_STEP, RESOLVED_VALUE)
    SELECT @RunId, @RuleId, r.JOB_NUMBER, NULL,
           ISNULL(w.FLAG, b.FLAG),
           LEFT(CASE WHEN w.STEP_NO IS NOT NULL
                     THEN CONCAT('Resolved by step ', w.STEP_NO, ' (', w.STEP_NAME, '): ', w.VAL, '. Tried: ', t.TRIED)
                     ELSE CONCAT('No step matched. Tried: ', ISNULL(t.TRIED, '(no active steps)')) END, 4000),
           w.STEP_NO, LEFT(w.VAL, 400)
    FROM lab.STG_REPORT r
    CROSS JOIN (SELECT FLAG FROM lab.BUSINESS_RULE WHERE RULE_ID = @RuleId) b
    LEFT JOIN win   w ON w.JOB_NUMBER = r.JOB_NUMBER AND w.rn = 1
    LEFT JOIN trail t ON t.JOB_NUMBER = r.JOB_NUMBER;
END;
GO

/* ---------------------------------------------------------------- runner */
CREATE OR ALTER PROCEDURE lab.usp_RUN_BUSINESS_RULES
    @RuleId int         = NULL,   -- run one rule
    @Label  varchar(50) = NULL    -- run every rule with this RULE_LABEL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run int, @rid int, @type varchar(10), @flag varchar(10), @sql nvarchar(max),
            @n int = 0, @err int = 0;

    INSERT lab.RULE_RUN DEFAULT VALUES;
    SET @run = SCOPE_IDENTITY();

    CREATE TABLE #out (JOB_NUMBER varchar(30) COLLATE DATABASE_DEFAULT, SAMPLE_TEXT varchar(100) COLLATE DATABASE_DEFAULT,
                       OUTCOME varchar(10) COLLATE DATABASE_DEFAULT, DETAIL varchar(4000) COLLATE DATABASE_DEFAULT);

    DECLARE rules CURSOR LOCAL FAST_FORWARD FOR
        SELECT b.RULE_ID, b.RULE_TYPE, b.FLAG, b.CHECK_SQL
        FROM lab.BUSINESS_RULE b
        JOIN lab.BUSINESS_RULE_LABEL l ON l.RULE_LABEL = b.RULE_LABEL
        WHERE b.FLAG <> 'INACTIVE'
          AND (@RuleId IS NULL OR b.RULE_ID = @RuleId)
          AND (@Label  IS NULL OR b.RULE_LABEL = @Label)
        ORDER BY l.LABEL_ORDER, b.RUN_ORDER, b.RULE_ID;   -- label order first, then rule order
    OPEN rules;
    FETCH NEXT FROM rules INTO @rid, @type, @flag, @sql;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @n += 1;
        BEGIN TRY
            IF @type = 'CHAIN'
                EXEC lab.usp_EVAL_CHAIN_RULE @RunId = @run, @RuleId = @rid;
            ELSE
            BEGIN
                TRUNCATE TABLE #out;
                INSERT #out (JOB_NUMBER, SAMPLE_TEXT, OUTCOME, DETAIL) EXEC sp_executesql @sql;
                INSERT lab.RULE_RESULT (RUN_ID, RULE_ID, JOB_NUMBER, SAMPLE_TEXT, OUTCOME, DETAIL)
                SELECT @run, @rid, JOB_NUMBER, SAMPLE_TEXT,
                       CASE WHEN OUTCOME = 'FAIL' THEN @flag ELSE OUTCOME END, DETAIL
                FROM #out;
            END
        END TRY
        BEGIN CATCH
            SET @err += 1;
            INSERT lab.RULE_RESULT (RUN_ID, RULE_ID, OUTCOME, DETAIL)
            VALUES (@run, @rid, 'ERROR', LEFT(ERROR_MESSAGE(), 4000));
        END CATCH;
        FETCH NEXT FROM rules INTO @rid, @type, @flag, @sql;
    END
    CLOSE rules; DEALLOCATE rules;

    UPDATE lab.RULE_RUN SET FINISHED_AT = SYSDATETIME(), RULES_RUN = @n, RULES_ERRORED = @err
    WHERE RUN_ID = @run;

    SELECT l.LABEL_ORDER, b.RULE_LABEL, b.RUN_ORDER, b.RULE_ID, b.RULE_CODE, b.FLAG AS RULE_FLAG,
           r.JOB_NUMBER, r.SAMPLE_TEXT, r.OUTCOME, r.RESOLVED_STEP, r.RESOLVED_VALUE, r.DETAIL
    FROM lab.RULE_RESULT r
    JOIN lab.BUSINESS_RULE b       ON b.RULE_ID = r.RULE_ID
    JOIN lab.BUSINESS_RULE_LABEL l ON l.RULE_LABEL = b.RULE_LABEL
    WHERE r.RUN_ID = @run
    ORDER BY l.LABEL_ORDER, b.RUN_ORDER, b.RULE_ID, r.JOB_NUMBER, r.SAMPLE_TEXT;
END;
GO

/* ---------------------------------------------------------------- latest results */
CREATE OR ALTER VIEW lab.V_RULE_RESULT_LATEST AS
SELECT  l.LABEL_ORDER, b.RULE_LABEL, b.RUN_ORDER, b.RULE_ID, b.RULE_CODE, b.RULE_NAME, b.FLAG AS RULE_FLAG,
        r.JOB_NUMBER, r.SAMPLE_TEXT, r.OUTCOME, r.RESOLVED_STEP, r.RESOLVED_VALUE, r.DETAIL,
        r.RUN_ID, u.STARTED_AT AS RUN_AT
FROM    lab.RULE_RESULT r
JOIN    lab.BUSINESS_RULE b       ON b.RULE_ID = r.RULE_ID
JOIN    lab.BUSINESS_RULE_LABEL l ON l.RULE_LABEL = b.RULE_LABEL
JOIN    lab.RULE_RUN u      ON u.RUN_ID  = r.RUN_ID
WHERE   r.RUN_ID = (SELECT MAX(r2.RUN_ID) FROM lab.RULE_RESULT r2 WHERE r2.RULE_ID = r.RULE_ID);
GO
