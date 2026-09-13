# Cold-Chain Logistics FDE Assistant

<img width="1532" height="1028" alt="image" src="https://github.com/user-attachments/assets/9c826a11-48d4-47b9-85eb-06435678f4bc" />


An AI agent that lets logistics dispatchers **"chat with their data"** to investigate cold-chain incidents — reasoning across live fleet telemetry, real-time weather/corridor conditions, and enterprise SOP documents to produce a structured, cited action plan.

Built as a Forward Deployed Engineering (FDE) style project: a legacy enterprise SQL database, a semantic security layer on top of it, a LangGraph tool-calling agent, and a Chainlit dispatch console.

## Why this needs an FDE

This isn't a "call an API, get an answer" LLM app — it's an AI system wired directly into a client's real (messy, locked-down) enterprise stack, end to end. That's exactly the gap an FDE fills: someone who sits with the client's actual infrastructure and data instead of handing back a generic notebook or slide deck.

- **Reverse-engineering a legacy system.** The source telemetry lives in a deliberately obscure legacy schema (`TBL_SC_FLEET_HIST_RAW` with columns like `V_LAT`, `IOT_TEMP_VAL_C`, `RT_RSK_IDX`) — the kind of undocumented table an FDE actually finds on-site. Someone has to understand it and translate it into something an LLM (and a business user) can reason about.
- **Designing the semantic + security layer.** `FDE_VIEWS.VW_ACTIVE_FLEET` and the `USR_FDE_RO` read-only login (`scripts/setup_security_and_view.sql`) aren't things a client's existing DBA tooling hands you for free — an FDE has to design the exact boundary between "what the agent is allowed to touch" and "the raw production data underneath," so the agent can't hallucinate a mutation or leak columns it shouldn't see.
- **Standing up infrastructure the client doesn't have yet.** A Dockerized SQL Server, Pinecone indexing with hash-based re-ingestion caching, a managed Chainlit deployment, and a repeatable deploy pipeline — this is applied deployment work, not model tuning.
- **Encoding domain/business logic into the agent, not just prompting it.** The system prompt (`src/prompts/system_prompt.txt`) hard-codes the client's actual operating procedure — check telemetry → check corridor conditions → check the SOP → answer in a fixed exec-report format with a cited rule. That sequencing and output contract comes from sitting with the business process, not from a generic assistant persona.
- **Owning the last mile of trust.** The audit log (`FDE_VIEWS.AgentAuditLog`) and the admin-gated audit view in `src/ui_chainlit.py` exist because a client won't adopt an agent touching operational decisions unless every tool call and answer is inspectable after the fact — that accountability layer is part of the delivery, not an afterthought.

In short: the ML/agent logic here is the easy 20%. The other 80% — untangling the legacy data, locking down access, deploying it where the client's people actually work, and encoding their SOPs correctly — is FDE work, and the project is structured to make that explicit.

## What it does

A dispatcher asks a question like:

> *"Find any active shipments near Los Angeles (Lat ~33.8, Lon ~-118.1). Check the local weather there, and tell me if the current cargo temperature violates the SOP for fresh perishables."*

The agent (LangGraph state machine) autonomously decides which tools to call, pulls together telemetry, weather, and compliance context, and responds in a fixed business report format:

1. **Executive Summary** — the anomaly and immediate risk
2. **Telemetry & Environment Analysis** — a table of location, temperature, cargo risk, weather/congestion
3. **Required Action Plan** — concrete next steps with an exact SOP citation

It also knows when *not* to use tools — e.g. a general policy question gets answered directly instead of triggering a database query.

## Architecture

```
Dispatcher (Chainlit UI)
        │
        ▼
LangGraph Agent  ──►  query_telemetry_db        SQL Server (read-only semantic view)
 (reasoner ⇄ tools)──►  fetch_corridor_conditions  Open-Meteo live weather API
        │           ──►  search_compliance_sop     Pinecone vector store (SOP docs)
        ▼
Structured incident report + audit log (SQL)
```

- **Orchestrator** (`src/orchestrator.py`) — a LangGraph `StateGraph` with a `reasoner` node (LLM bound to tools) and a `tools` node, looping until the LLM produces a final answer. Swappable LLM backend via `.env` (`Agent_llm`): OpenAI, DeepSeek, or a local Ollama model as the offline fallback.
- **Agent tools** (`src/agent_tools.py`):
  - `query_telemetry_db` — runs read-only T-SQL against a clean semantic view of fleet telemetry (location, temperature, cargo condition, risk classification, delay probability, congestion).
  - `fetch_corridor_conditions` — live weather/wind lookup per GPS coordinate, computing a corridor congestion index.
  - `search_compliance_sop` — semantic search over ingested SOP documents in Pinecone (local HuggingFace or OpenAI embeddings, selectable via `.env`).
- **UI** (`src/ui_chainlit.py`) — Chainlit "Dispatch Console" for chatting with the agent (with live tool-call traces) plus a separate admin-gated "Security & Audit Logs" view backed by a SQL audit table.
- **Data security layer** (`scripts/setup_security_and_view.sql`) — the raw legacy table is never exposed to the agent. A dedicated `FDE_VIEWS.VW_ACTIVE_FLEET` view translates cryptic legacy columns into clean names, and a locked-down `USR_FDE_RO` SQL login is granted `SELECT` on the view only — explicitly denied on the raw table and denied any write/alter access.

## Data pipeline

| Stage | Script | Purpose |
|---|---|---|
| Legacy ingestion | `scripts/ingest_legacy_data.py` | Loads the source CSV (`data/raw/`) and writes it into a deliberately "messy" legacy-style MSSQL table, simulating a real enterprise system. |
| Security & views | `scripts/setup_security_and_view.sql` | Creates the semantic view and read-only agent login on top of the legacy table. |
| SOP ingestion | `scripts/ingest_sop_pinecone.py` | Chunks and embeds SOP documents (`data/policy/`) into Pinecone, with hash-based caching (`data/cache/ingestion_hash_cache.json`) to skip unchanged files on re-runs. |

Full step-by-step setup (Docker MSSQL, Pinecone, security grants, audit table DDL, deployment) is documented in [`docs/instrutions.md`](docs/instrutions.md).

## Tech stack

LangGraph + LangChain (agent orchestration) · Chainlit (UI) · SQL Server via SQLAlchemy/pyodbc (telemetry store) · Pinecone (vector store) · HuggingFace / OpenAI embeddings · OpenAI / DeepSeek / Ollama (LLM backends)

## Running it

```bash
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt

# configure .env: SQL_*, PINECONE_API_KEY, Agent_llm, Embeddings_model, etc.

chainlit run src/ui_chainlit.py -w
```

A `workflow_dispatch` GitHub Actions pipeline (`.github/workflows/deploy.yml`) is also available for pushing updates to a running host.

### Running it on minikube

The whole stack (app + in-cluster SQL Server) can also run locally on Kubernetes via minikube — see [`k8s/README.md`](k8s/README.md) for the full walkthrough. Quick start:

```bash
minikube start
eval $(minikube docker-env)                 # build the image where minikube can see it
docker build -t fde-cold-chain:local .

cp k8s/app-secrets.env.example k8s/app-secrets.env   # fill in real values, then:
kubectl create secret generic app-secrets --from-env-file=k8s/app-secrets.env

kubectl apply -f k8s/mssql/
kubectl apply -f k8s/app/
kubectl apply -f k8s/jobs/db-init-job.yaml      # creates the semantic view + audit table
kubectl apply -f k8s/jobs/sop-ingest-job.yaml   # embeds SOPs into Pinecone

minikube service fde-app --url               # open the Chainlit dispatch console
```

## Sample questions

Try these in the Dispatch Console (`chainlit run src/ui_chainlit.py -w`, or the minikube-deployed UI) to see the agent's tool-routing and restraint in action:

| Question | What it demonstrates |
|---|---|
| *"Find any active shipments near Los Angeles (Latitude ~33.8, Longitude ~-118.1). Check the local weather there, and tell me if the current cargo temperature violates the SOP for fresh perishables."* | The full "Domino Effect" flow — all three tools chained: `query_telemetry_db` → `fetch_corridor_conditions` → `search_compliance_sop` — resolved into a cited action plan. |
| *"I'm a new dispatcher on the night shift. Can you quickly explain the difference between a Tier 1 and Tier 2 escalation?"* | The "Restraint" test — a general policy question the agent answers directly from the SOP without needlessly querying the telemetry database. |
| *"What are the temperature thresholds for fresh perishables under our cold-chain SOP?"* | A `search_compliance_sop`-only lookup, useful for sanity-checking the Pinecone index after ingestion. |
| *"Show me the current risk classification and delay probability for active shipments."* | A `query_telemetry_db`-only lookup against the `FDE_VIEWS.VW_ACTIVE_FLEET` semantic view. |
| *"One of our trailers just reported a DAMAGED cargo condition code on a route with a Route Risk Index of 8.1 — what's the required escalation?"* | Exercises the Cargo Condition & Route Risk SOP's Compound Incident trigger (damaged cargo + severe route risk → Tier 2 Logistics Manager + Regional Safety Officer). |
| *"What's the difference in escalation between an Elevated and a Severe Route Risk Index?"* | A `search_compliance_sop`-only lookup validating that `Cargo_Condition_And_Route_Risk_SOP_v1.pdf` was chunked and indexed correctly. |

After running a query, switch to **🛡️ Security & Audit Logs** in the sidebar (admin credentials from `.env`/`k8s/app-secrets.env`) to see every tool call the agent made, logged to `FDE_VIEWS.AgentAuditLog`.



