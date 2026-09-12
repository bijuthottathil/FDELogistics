# Running on minikube

Deploys the full stack locally on Kubernetes: the Chainlit app (UI + LangGraph agent + tools) and an in-cluster SQL Server instance. Pinecone stays external — it's a managed cloud vector store, not something to run in-cluster.

```
┌─────────────────────────── minikube ───────────────────────────┐
│                                                                  │
│  Deployment: fde-app  ──►  Service: fde-app (NodePort, 8000)    │
│       │                                                          │
│       ▼                                                          │
│  Deployment: mssql  ──►  Service: mssql (ClusterIP, 1433)        │
│       │                                                          │
│       ▼                                                          │
│  PVC: mssql-data (persists /var/opt/mssql across pod restarts)   │
│                                                                  │
│  Job: db-init     (ingest_legacy_data.py + security/view SQL)    │
│  Job: sop-ingest   (ingest_sop_pinecone.py)                      │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
                          │
                          ▼
                  Pinecone (external, cloud)
```

## Prerequisites

- `minikube`, `kubectl`, `docker` installed and on `PATH`
- A Pinecone API key (and an OpenAI key, if using OpenAI as the LLM/embeddings backend)

## 1. Start minikube and build the image

Build the image directly inside minikube's Docker daemon so you don't need to push it to a registry:

```bash
minikube start
eval $(minikube docker-env)
docker build -t fde-cold-chain:local .
```

> The image bundles `msodbcsql18`/`sqlcmd` (SQL Server connectivity) and the full Python stack from `requirements.txt` (including `torch`/`sentence-transformers` for local embeddings), so the first build can take several minutes.

## 2. Create the secret

```bash
cp k8s/app-secrets.env.example k8s/app-secrets.env
# edit k8s/app-secrets.env with real values

kubectl create secret generic app-secrets --from-env-file=k8s/app-secrets.env
```

`k8s/app-secrets.env` is gitignored — never commit it. Non-sensitive, cluster-specific config (`SQL_SERVER_HOST`, `Agent_llm`, `Embeddings_model`, …) lives separately in `k8s/app/configmap.yaml` so it isn't overwritten by your local secret values.

**Important:** `scripts/setup_security_and_view.sql` hardcodes the `USR_FDE_RO` login password as `AgentPassword2026!`. Your secret's `SQL_AGENT_PASSWORD` must match that value unless you also edit the SQL file.

## 3. Deploy SQL Server and the app

```bash
kubectl apply -f k8s/mssql/
kubectl apply -f k8s/app/

kubectl get pods -w   # wait until mssql and fde-app are Running/Ready
```

## 4. Initialize the database and SOP index

These are one-shot Jobs, run once the `mssql` pod is up:

```bash
kubectl apply -f k8s/jobs/db-init-job.yaml
kubectl logs -f job/db-init

kubectl apply -f k8s/jobs/sop-ingest-job.yaml
kubectl logs -f job/sop-ingest
```

`db-init` waits for SQL Server to accept logins, loads the legacy telemetry CSV into `dbo.TBL_SC_FLEET_HIST_RAW`, creates the `FDE_VIEWS.VW_ACTIVE_FLEET` semantic view + read-only `USR_FDE_RO` login, and creates the `FDE_VIEWS.AgentAuditLog` table. It's safe to re-run (schema/login-already-exists errors from the security script are treated as non-fatal).

## 5. Open the app

```bash
minikube service fde-app --url
```

## Redeploying via GitHub Actions

Once the one-time setup above (secret, SQL Server, app, init Jobs) is done, `.github/workflows/deploy.yml` gives you a one-click redeploy for code changes — no SSH, no remote host. It runs on a **self-hosted runner** registered on the same machine that runs minikube, so the job executes locally: rebuild the image into minikube's Docker daemon, re-apply `k8s/app/`, then `kubectl rollout restart` the app deployment.

**One-time runner setup:**

1. In the GitHub repo: **Settings → Actions → Runners → New self-hosted runner**, and follow the download/config commands it gives you (`config.sh --url ... --token ...`).
2. Either run `./run.sh` in a terminal you leave open, or install it as a background service (`./svc.sh install && ./svc.sh start`) so it stays online.

**Every time you want to redeploy:**

1. Make sure `minikube start` and the runner are both up.
2. In GitHub: **Actions → Enterprise Manual Deploy → Run workflow**.

Gotchas specific to this setup:
- If the runner is installed as a background service (not run from an interactive terminal), it may not inherit your shell's `PATH` — make sure `minikube`, `kubectl`, and `docker` resolve for the service user, or use full binary paths in the workflow.
- `workflow_dispatch` only queues the job if the runner is offline; it doesn't fail, but it also won't come back on its own once you close the terminal running `./run.sh` unless you installed it as a service.
- This workflow only redeploys the **app** (equivalent to step 3's `kubectl apply -f k8s/app/` + a rollout). It doesn't touch `k8s/mssql/` or re-run the init Jobs — do that manually (steps 3–4 above) if the database/security setup itself changed.

## Re-running / cleaning up

```bash
kubectl delete job db-init sop-ingest   # Jobs must be deleted before re-applying
kubectl delete -f k8s/app/ -f k8s/mssql/ -f k8s/jobs/
kubectl delete secret app-secrets
```

## Notes / possible follow-ups

- `mssql` uses a single `ReadWriteOnce` PVC — fine for local minikube use, not meant for multi-node production.
- `data/cache/ingestion_hash_cache.json` (SOP re-ingestion cache) isn't persisted between `sop-ingest` Job runs; mount a small PVC at `/app/data/cache` if you want re-runs to skip unchanged SOP files.
- `Agent_llm=OPENAI` is the default in `k8s/app/configmap.yaml` because the `OLLAMA` fallback in `src/orchestrator.py` needs a local Ollama server, which isn't part of this deployment.
- `src/agent_tools.py` connects to Pinecone at **import time** and raises immediately if `PINECONE_API_KEY` is missing/invalid — the `fde-app` pod will crash-loop until `app-secrets` has a real, working Pinecone key (a placeholder from the `.example` file is not enough).
