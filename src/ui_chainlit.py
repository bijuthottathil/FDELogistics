import os
import sys
import json
import uuid
import urllib
from pathlib import Path
from typing import Optional

import pandas as pd
import chainlit as cl
from dotenv import load_dotenv
from sqlalchemy import create_engine, text
from langchain_core.messages import HumanMessage, ToolMessage

# ==========================================
# 1. IMMEDIATE PATH & ENVIRONMENT RESOLUTION
# ==========================================
script_dir = Path(__file__).resolve().parent  # points to src/
project_root = script_dir.parent              # climbs to project root

if str(project_root) not in sys.path:
    sys.path.insert(0, str(project_root))

load_dotenv(project_root / ".env")

from src.orchestrator import fde_agent

# ==========================================
# 2. SQL CONNECTION HELPERS
# ==========================================
db_host = os.getenv("SQL_SERVER_HOST", "localhost")
db_port = os.getenv("SQL_SERVER_PORT", "1433")


def _build_engine(user: str, password: str):
    connection_string = (
        f"DRIVER={{ODBC Driver 18 for SQL Server}};"
        f"SERVER={db_host},{db_port};"
        f"DATABASE=master;"
        f"UID={user};"
        f"PWD={password};"
        f"Encrypt=no;"
        f"TrustServerCertificate=yes;"
    )
    params = urllib.parse.quote_plus(connection_string)
    return create_engine(f"mssql+pyodbc:///?odbc_connect={params}")


# Engine for the agent to write audit logs, using its standard read/insert-only credentials
log_engine = _build_engine(
    os.getenv("SQL_AGENT_USER", "USR_FDE_RO"),
    os.getenv("SQL_AGENT_PASSWORD", ""),
)


def write_audit_log(session_id: str, node_name: str, tool_name: str, content: str):
    """Silently writes agent execution traces to the SQL audit table using agent permissions."""
    try:
        with log_engine.connect() as conn:
            conn.execute(
                text(
                    """
                    INSERT INTO FDE_VIEWS.AgentAuditLog (SessionID, NodeExecuted, ToolName, Content)
                    VALUES (:session_id, :node_name, :tool_name, :content)
                    """
                ),
                {
                    "session_id": session_id,
                    "node_name": node_name,
                    "tool_name": tool_name,
                    "content": content,
                },
            )
            conn.commit()
    except Exception as e:
        print(f"Audit Log Failed (Silent): {e}")


# ==========================================
# 3. AUTHENTICATION
# ==========================================
# Two-tier login, reusing the same SQL credentials the database already trusts:
#   SQL_AGENT_USER/PASSWORD -> role "dispatcher" (Dispatch Console only)
#   SQL_ADMIN_USER/PASSWORD -> role "admin"      (Dispatch Console + audit log)
# Requires CHAINLIT_AUTH_SECRET in .env (generate with: chainlit create-secret)
@cl.password_auth_callback
async def auth_callback(username: str, password: str) -> Optional[cl.User]:
    if username == os.getenv("SQL_AGENT_USER") and password == os.getenv("SQL_AGENT_PASSWORD"):
        return cl.User(identifier=username, metadata={"role": "dispatcher"})

    if username == os.getenv("SQL_ADMIN_USER") and password == os.getenv("SQL_ADMIN_PASSWORD"):
        # stash the password so the audit view can open its own admin-scoped connection
        return cl.User(identifier=username, metadata={"role": "admin", "db_password": password})

    return None


# ==========================================
# 4. CHAT LIFECYCLE
# ==========================================
@cl.on_chat_start
async def start():
    cl.user_session.set("thread_id", str(uuid.uuid4()))

    user = cl.user_session.get("user")
    role = (user.metadata or {}).get("role", "dispatcher") if user else "dispatcher"
    cl.user_session.set("role", role)

    greeting = (
        "**Cold-Chain Incident Control Dashboard**\n\n"
        "Query fleet telemetry, corridor updates, or compliance thresholds."
    )
    if role == "admin":
        greeting += "\n\nType `audit` at any time to view the agent's audit trail."

    await cl.Message(content=greeting).send()


@cl.on_message
async def main(message: cl.Message):
    role = cl.user_session.get("role", "dispatcher")

    if role == "admin" and message.content.strip().lower() == "audit":
        await show_audit_log()
        return

    thread_id = cl.user_session.get("thread_id")
    thread_config = {"configurable": {"thread_id": thread_id}}

    final_response = ""
    pending_tool_calls: dict[str, dict] = {}

    events = fde_agent.stream(
        {"messages": [HumanMessage(content=message.content)]},
        config=thread_config,
        stream_mode="updates",
    )

    for event in events:
        for node_name, node_state in event.items():

            if node_name == "reasoner":
                latest_msg = node_state["messages"][-1]

                if getattr(latest_msg, "tool_calls", None):
                    for tool_call in latest_msg.tool_calls:
                        pending_tool_calls[tool_call["id"]] = tool_call
                        write_audit_log(
                            thread_id, "reasoner", tool_call["name"], json.dumps(tool_call["args"])
                        )

                if latest_msg.content:
                    final_response = latest_msg.content
                    write_audit_log(thread_id, "reasoner_final", "LLM Text Synthesis", final_response)

            elif node_name == "tools":
                for msg in node_state.get("messages", []):
                    if isinstance(msg, ToolMessage):
                        tool_call = pending_tool_calls.pop(msg.tool_call_id, None)

                        async with cl.Step(name=msg.name, type="tool") as step:
                            step.input = tool_call["args"] if tool_call else {}
                            step.output = msg.content

                        write_audit_log(thread_id, "tools", msg.name, msg.content)

    if final_response:
        await cl.Message(content=final_response).send()
    else:
        await cl.Message(
            content="⚠️ Execution Timeout: System engine encountered an unresolved processing edge case."
        ).send()


# ==========================================
# 5. ADMIN-ONLY AUDIT LOG VIEW
# ==========================================
async def show_audit_log():
    user = cl.user_session.get("user")
    admin_user = user.identifier if user else None
    admin_password = (user.metadata or {}).get("db_password") if user else None

    try:
        admin_engine = _build_engine(admin_user, admin_password)
        with admin_engine.connect() as conn:
            df = pd.read_sql(
                """
                SELECT LogID, Timestamp, SessionID, NodeExecuted, ToolName, Content
                FROM FDE_VIEWS.AgentAuditLog
                ORDER BY Timestamp DESC
                """,
                conn,
            )

        if df.empty:
            await cl.Message(content="No audit logs found yet. Run a query in the console first.").send()
        else:
            await cl.Message(
                content=f"**{len(df)} audit log entries** (`FDE_VIEWS.AgentAuditLog`):",
                elements=[cl.Dataframe(data=df, name="AgentAuditLog", display="inline")],
            ).send()

    except Exception as e:
        await cl.Message(content=f"Database query failed: {e}").send()
