/* =====================================================================
   Business rule definitions. Re-runnable: rules are upserted by RULE_ID,
   and each rule's steps are replaced by the list defined here.

   FLAG (PASS | WARN | FAIL | INACTIVE)
     Rule: how a failure is reported, or INACTIVE to skip the rule.
     Step: outcome when the step matches, or INACTIVE to skip the step.
     Param: outcome recorded when the value applies, or INACTIVE to switch the value off.

   Add or change rules here, re-run this file, then:
       EXEC lab.usp_RUN_BUSINESS_RULES;            -- all non-INACTIVE rules
       EXEC lab.usp_RUN_BUSINESS_RULES @RuleId=1;  -- one rule
       EXEC lab.usp_RUN_BUSINESS_RULES @Label='DespatchSend';  -- all rules with a label
   ===================================================================== */
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRAN;

/* ---- labels: groups of rules, run in LABEL_ORDER */
MERGE lab.BUSINESS_RULE_LABEL AS t
USING (VALUES
/* RULE_LABEL, LABEL_ORDER, DESCRIPTION */
('DespatchSend', 10, 'Identify the despatch (DESPATCHSEND) each lab report belongs to. Runs first.'),
('SampleFilter', 20, 'Decide which sample lines are in scope for sample-level rules.'),
('SampleDespatch', 30, 'Check in-scope samples exist in the database and are on the resolved despatch.')
) AS s (RULE_LABEL, LABEL_ORDER, DESCRIPTION)
ON t.RULE_LABEL = s.RULE_LABEL
WHEN MATCHED THEN UPDATE SET LABEL_ORDER = s.LABEL_ORDER, DESCRIPTION = s.DESCRIPTION
WHEN NOT MATCHED THEN INSERT (RULE_LABEL, LABEL_ORDER, DESCRIPTION)
    VALUES (s.RULE_LABEL, s.LABEL_ORDER, s.DESCRIPTION);

/* ---- rules: RUN_ORDER is the order within the label */
MERGE lab.BUSINESS_RULE AS t
USING (VALUES
/* RULE_ID, RULE_LABEL, RULE_CODE, RULE_NAME, DESCRIPTION, RULE_TYPE, RULE_LEVEL, FLAG, RUN_ORDER, CHECK_SQL, NOTES */
(1, 'DespatchSend', 'R001_DESPATCHNO', 'Resolve DespatchNo',
    'Find the DespatchNo for each report: P.O. Number if it is in DESPATCHSEND, else Shipment ID if '
  + 'it is in DESPATCHSEND, else the lab Job Number (LabJobNo).',
    'CHAIN', 'REPORT', 'FAIL', 10, NULL,
    '2026-11-11: Shipment ID fallback added (ALS uses P.O. Number, Bureau Veritas uses Shipment ID). '
  + '2026-11-11: LabJobNo added as last fallback, flag PASS (an accepted DespatchNo even though '
  + 'it is not yet in DESPATCHSEND).'),
(2, 'SampleFilter', 'R002_IGNORE_SAMPLE_PREFIX', 'Ignore samples by prefix',
    'Sample lines whose sample text starts with an active PREFIX (see BUSINESS_RULE_PARAM) are '
  + 'excluded from sample-level rules. Used for lab-internal QC lines (standards, blanks).',
    'IGNORE_PREFIX', 'SAMPLE', 'PASS', 10, NULL,
    '2026-11-12: created; STD and BLK prefixes switched on.'),

(3, 'SampleDespatch', 'R003_SAMPLE_EXISTS', 'SampleID exists in database',
    'Each in-scope sample line''s SampleID must exist in dbo.QV_SAMPLE_CHECK (samples and checks). '
  + 'RESOLVED_VALUE lists the DuplicateNos found for it.',
    'SQL', 'SAMPLE', 'FAIL', 10,
    N'SELECT s.JOB_NUMBER, s.SAMPLE_TEXT,
            CASE WHEN c.N > 0 THEN ''PASS'' ELSE ''FAIL'' END,
            CASE WHEN c.N > 0
                 THEN CONCAT(''Line '', s.ROW_SEQ, '': SampleID found in QV_SAMPLE_CHECK ('', c.N, '' DuplicateNo: '', c.DUPS, '')'')
                 ELSE CONCAT(''Line '', s.ROW_SEQ, '': SampleID not found in QV_SAMPLE_CHECK'') END,
            c.DUPS
     FROM lab.V_STG_SAMPLE_IN_SCOPE s
     OUTER APPLY (SELECT COUNT(*) AS N,
                         STRING_AGG(CAST(q.DUPLICATENO AS varchar(400)), '','') WITHIN GROUP (ORDER BY q.DUPLICATENO) AS DUPS
                  FROM dbo.QV_SAMPLE_CHECK q WHERE q.SAMPLEID = s.SAMPLE_TEXT) c',
    '2026-11-12: created. Runs before R004.'),

(4, 'SampleDespatch', 'R004_SAMPLE_ON_DESPATCH', 'Sample on DespatchNo',
    'For in-scope samples that exist in QV_SAMPLE_CHECK: of the SampleID''s DuplicateNos, find those where '
  + '(DespatchNo, SampleID, DuplicateNo) exists in dbo.QV_SAMPLE_CHECK_DESPATCH, using the DespatchNo '
  + 'resolved by R001. One match = PASS (DuplicateNo recorded); none = FAIL; more than one = WARN (ambiguous).',
    'SQL', 'SAMPLE', 'FAIL', 20,
    N'WITH d AS (SELECT r.JOB_NUMBER, r.RESOLVED_VALUE AS DESPATCHNO
               FROM lab.RULE_RESULT r
               WHERE r.RULE_ID = 1
                 AND r.RUN_ID = (SELECT MAX(RUN_ID) FROM lab.RULE_RESULT WHERE RULE_ID = 1)),
          s AS (SELECT i.JOB_NUMBER, i.ROW_SEQ, i.SAMPLE_TEXT, d.DESPATCHNO
                FROM lab.V_STG_SAMPLE_IN_SCOPE i
                LEFT JOIN d ON d.JOB_NUMBER = i.JOB_NUMBER
                WHERE EXISTS (SELECT 1 FROM dbo.QV_SAMPLE_CHECK c WHERE c.SAMPLEID = i.SAMPLE_TEXT))
     SELECT s.JOB_NUMBER, s.SAMPLE_TEXT,
            CASE WHEN s.DESPATCHNO IS NULL THEN ''FAIL''
                 WHEN m.N = 1 THEN ''PASS''
                 WHEN m.N > 1 THEN ''WARN''
                 ELSE ''FAIL'' END,
            CASE WHEN s.DESPATCHNO IS NULL
                   THEN CONCAT(''Line '', s.ROW_SEQ, '': no DespatchNo resolved for the report (R001)'')
                 WHEN m.N = 1
                   THEN CONCAT(''Line '', s.ROW_SEQ, '': '', s.DESPATCHNO, '' / '', s.SAMPLE_TEXT, '' / '', m.DUPS, '' found'')
                 WHEN m.N > 1
                   THEN CONCAT(''Line '', s.ROW_SEQ, '': ambiguous - several DuplicateNos on '', s.DESPATCHNO, '': '', m.DUPS)
                 ELSE CONCAT(''Line '', s.ROW_SEQ, '': no DuplicateNo of '', s.SAMPLE_TEXT, '' is on '', s.DESPATCHNO) END,
            m.DUPS
     FROM s
     OUTER APPLY (SELECT COUNT(*) AS N,
                         STRING_AGG(CAST(c.DUPLICATENO AS varchar(400)), '','') WITHIN GROUP (ORDER BY c.DUPLICATENO) AS DUPS
                  FROM dbo.QV_SAMPLE_CHECK c
                  WHERE c.SAMPLEID = s.SAMPLE_TEXT
                    AND EXISTS (SELECT 1 FROM dbo.QV_SAMPLE_CHECK_DESPATCH q
                                WHERE q.SAMPLEID = c.SAMPLEID AND q.DUPLICATENO = c.DUPLICATENO
                                  AND q.DESPATCHNO = s.DESPATCHNO)) m',
    '2026-11-12: created. Only samples passing R003 are checked. Umpire despatches carry the UMPREP '
  + 'check, not PRIMARY, so the DuplicateNo is resolved per despatch rather than assumed.'),

(5, 'SampleFilter', 'R005_IGNORE_REPEAT_OF_FSTD', 'Ignore lab repeats of field standards',
    'Lab repeat lines (REPEAT_PREFIX, e.g. "REP ") whose parent ID is a field standard check '
  + '(PARENT_DUPLICATENO, e.g. FSTD) in QV_SAMPLE_CHECK are excluded from sample-level rules.',
    'IGNORE_REPEAT_OF', 'SAMPLE', 'PASS', 20, NULL,
    '2026-11-12: created. A lab repeat of a field standard is not useful and is not registered as a '
  + 'LABREP check.')
) AS s (RULE_ID, RULE_LABEL, RULE_CODE, RULE_NAME, DESCRIPTION, RULE_TYPE, RULE_LEVEL, FLAG, RUN_ORDER, CHECK_SQL, NOTES)
ON t.RULE_ID = s.RULE_ID
WHEN MATCHED THEN UPDATE SET
    RULE_LABEL = s.RULE_LABEL, RULE_CODE = s.RULE_CODE, RULE_NAME = s.RULE_NAME, DESCRIPTION = s.DESCRIPTION,
    RULE_TYPE = s.RULE_TYPE, RULE_LEVEL = s.RULE_LEVEL, FLAG = s.FLAG,
    RUN_ORDER = s.RUN_ORDER, CHECK_SQL = s.CHECK_SQL, NOTES = s.NOTES, UPDATED_AT = SYSDATETIME()
WHEN NOT MATCHED THEN INSERT
    (RULE_ID, RULE_LABEL, RULE_CODE, RULE_NAME, DESCRIPTION, RULE_TYPE, RULE_LEVEL, FLAG, RUN_ORDER, CHECK_SQL, NOTES)
    VALUES (s.RULE_ID, s.RULE_LABEL, s.RULE_CODE, s.RULE_NAME, s.DESCRIPTION, s.RULE_TYPE, s.RULE_LEVEL, s.FLAG,
            s.RUN_ORDER, s.CHECK_SQL, s.NOTES);

/* ---- steps: replaced wholesale for the rules defined above */
DELETE FROM lab.BUSINESS_RULE_STEP WHERE RULE_ID IN (1);

INSERT lab.BUSINESS_RULE_STEP
    (RULE_ID, STEP_NO, STEP_NAME, SOURCE_TYPE, SOURCE_KEY, CONDITION, LOOKUP_TABLE, LOOKUP_COLUMN, FLAG)
VALUES
    (1, 10, 'P.O. Number in DESPATCHSEND', 'HEADER', 'P.O. Number:', 'EXISTS',    'dbo.DESPATCHSEND', 'DESPATCHNO', 'PASS'),
    (1, 20, 'Shipment ID in DESPATCHSEND', 'HEADER', 'Shipment ID:', 'EXISTS',    'dbo.DESPATCHSEND', 'DESPATCHNO', 'PASS'),
    (1, 30, 'LabJobNo',                    'REPORT', 'JOB_NUMBER',   'NOT_BLANK', NULL,               NULL,         'PASS');

/* ---- params: replaced wholesale for the rules defined above */
DELETE FROM lab.BUSINESS_RULE_PARAM WHERE RULE_ID IN (2, 5);

INSERT lab.BUSINESS_RULE_PARAM (RULE_ID, PARAM_NAME, PARAM_VALUE, FLAG, NOTES)
VALUES
    (2, 'PREFIX',             'STD',  'PASS', 'Lab standards (certified reference material) - lab internal QC'),
    (2, 'PREFIX',             'BLK',  'PASS', 'Lab blanks - lab internal QC'),
    (5, 'REPEAT_PREFIX',      'REP ', 'PASS', 'Lab repeat lines: "REP " followed by the parent ID (note trailing space)'),
    (5, 'PARENT_DUPLICATENO', 'FSTD', 'PASS', 'Ignore lab repeats whose parent is a field standard check');

COMMIT;
