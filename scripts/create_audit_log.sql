-- ====================================================================
-- FDE AGENT AUDIT LOG
-- Purpose: Give the agent a write target for tool-call/response traces,
--          scoped so it can only INSERT into this one table.
-- Idempotent: safe to re-run against an already-initialized database.
-- ====================================================================

IF NOT EXISTS (
    SELECT 1 FROM sys.tables WHERE name = 'AgentAuditLog' AND SCHEMA_NAME(schema_id) = 'FDE_VIEWS'
)
BEGIN
    CREATE TABLE FDE_VIEWS.AgentAuditLog (
        LogID INT IDENTITY(1,1) PRIMARY KEY,
        Timestamp DATETIME DEFAULT GETDATE(),
        SessionID VARCHAR(50),
        NodeExecuted VARCHAR(50),
        ToolName VARCHAR(100),
        Content NVARCHAR(MAX) -- NVARCHAR to safely handle JSON strings and large LLM outputs
    );
END
GO

-- Grant the agent user permission to write only to this specific table
GRANT INSERT ON FDE_VIEWS.AgentAuditLog TO USR_FDE_RO;
GO

PRINT 'Agent audit log setup complete.';
GO
