/* =====================================================================
   Business rule definitions. Re-runnable: rules are upserted by RULE_ID,
   and each rule's steps are replaced by the list defined here.

   FLAG (PASS | WARN | FAIL | INACTIVE)
     Rule: how a failure is reported, or INACTIVE to skip the rule.
     Step: outcome when the step matches, or INACTIVE to skip the step.

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
('DespatchSend', 10, 'Identify the despatch (DESPATCHSEND) each lab report belongs to. Runs first.')
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
  + 'it is not yet in DESPATCHSEND).')
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

COMMIT;
