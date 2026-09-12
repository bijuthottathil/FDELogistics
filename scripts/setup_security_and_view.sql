-- ====================================================================
-- FDE ENTERPRISE SECURITY & SEMANTIC LAYER SCRIPT
-- Purpose: Protect the legacy DB from LLM hallucinations and mutations
-- Idempotent: safe to re-run against an already-initialized database.
-- ====================================================================

-- 1. Create a dedicated schema for our clean AI views
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'FDE_VIEWS')
BEGIN
    EXEC('CREATE SCHEMA FDE_VIEWS');
END
GO -- GO only works inside Microsoft terminal tools.

-- 2. Create the Semantic View (Translating legacy junk to clean English)
CREATE OR ALTER VIEW FDE_VIEWS.VW_ACTIVE_FLEET AS
SELECT
    TS_UTC AS [Timestamp],
    V_LAT AS [Latitude],
    V_LON AS [Longitude],
    CAST(IOT_TEMP_VAL_C AS FLOAT) AS [Current_Temperature_C],
    CGO_COND_CD AS [Cargo_Condition_Code],
    RISK_CLS_TXT AS [Risk_Classification],
    DELAY_PROB_DEC AS [Delay_Probability],
    PRT_CNG_LVL AS [Port_Congestion_Level],
    RT_RSK_IDX AS [Route_Risk_Index]
FROM dbo.TBL_SC_FLEET_HIST_RAW;
GO

-- 3. Create a strict Read-Only Login and User for the AI Agent
-- (Guarded rather than dropped/recreated, so re-running this script never
-- resets a password that was rotated after initial setup.)
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'USR_FDE_RO')
BEGIN
    CREATE LOGIN USR_FDE_RO WITH PASSWORD = 'AgentPassword2026!';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'USR_FDE_RO')
BEGIN
    CREATE USER USR_FDE_RO FOR LOGIN USR_FDE_RO;
END
GO

-- 4. Grant access ONLY to the semantic view, explicitly denying everything else
GRANT SELECT ON FDE_VIEWS.VW_ACTIVE_FLEET TO USR_FDE_RO;
DENY SELECT ON dbo.TBL_SC_FLEET_HIST_RAW TO USR_FDE_RO;
DENY INSERT, UPDATE, DELETE, ALTER ON SCHEMA::dbo TO USR_FDE_RO;
GO

PRINT 'Security & semantic view setup complete.';
GO

-- # About line 33 :
-- ON SCHEMA::dbo: The dbo (Database Owner) schema is the default folder structure where your python ingestion script just dumped the TBL_SC_FLEET_HIST_RAW table. This target applies the rules to every single table or view currently inside dbo, or any tables you might add there in the future.