#!/usr/bin/env bash
#
# scripts/destroy_installation.sh
#
# Tears down everything the k8s/ manifests and ingestion scripts created:
#   - k8s Jobs (db-init, sop-ingest)
#   - k8s Deployments/Services for fde-app and mssql
#   - the mssql-data PVC        <-- deletes the ONLY copy of the SQL Server data
#   - the app-secrets Secret and app-config ConfigMap
#   - the Pinecone indexes (fde-sop-index-local, fde-sop-index-openai)
# Optional, opt-in only:
#   - the local fde-cold-chain:local docker image     (--docker-image)
#   - the entire minikube cluster                      (--minikube)
#
# IRREVERSIBLE. There is no snapshot/backup step here. Re-creating the stack
# afterwards means re-running the k8s/README.md setup from step 1 and letting
# db-init / sop-ingest repopulate SQL Server and Pinecone from scratch.
#
# Usage:
#   scripts/destroy_installation.sh [--dry-run] [--yes]
#                                    [--no-k8s] [--no-pinecone]
#                                    [--minikube] [--docker-image]
#                                    [--i-know-this-is-not-minikube]

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DO_K8S=1
DO_PINECONE=1
DO_MINIKUBE=0
DO_IMAGE=0
ASSUME_YES=0
DRY_RUN=0
ALLOW_NON_MINIKUBE=0

usage() {
    sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-k8s) DO_K8S=0 ;;
        --no-pinecone) DO_PINECONE=0 ;;
        --minikube) DO_MINIKUBE=1 ;;
        --docker-image) DO_IMAGE=1 ;;
        --yes) ASSUME_YES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --i-know-this-is-not-minikube) ALLOW_NON_MINIKUBE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
    esac
    shift
done

run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] $*"
    else
        echo "==> $*"
        "$@"
    fi
}

echo "=================================================================="
echo " FDE Cold-Chain — DESTROY installation"
echo "=================================================================="

if [[ $DO_K8S -eq 1 ]]; then
    if ! command -v kubectl >/dev/null 2>&1; then
        echo "kubectl not found on PATH — cannot tear down k8s resources." >&2
        exit 1
    fi

    CTX="$(kubectl config current-context 2>/dev/null || echo '<none>')"
    echo "kubectl context: $CTX"

    if [[ "$CTX" != *minikube* && $ALLOW_NON_MINIKUBE -ne 1 ]]; then
        echo
        echo "!! Current kubectl context does not look like minikube." >&2
        echo "!! This script deletes Deployments, Services, a PVC (SQL Server data)," >&2
        echo "!! a Secret and a ConfigMap named the same as in this repo's k8s/ manifests." >&2
        echo "!! If that context points at a shared/production cluster, this is destructive there too." >&2
        echo "!! Re-run with --i-know-this-is-not-minikube if you really mean this context." >&2
        exit 1
    fi
fi

echo
echo "This will PERMANENTLY delete:"
if [[ $DO_K8S -eq 1 ]]; then
    cat <<EOF
  - k8s Jobs:            db-init, sop-ingest
  - k8s Deployments:     fde-app, mssql
  - k8s Services:        fde-app, mssql
  - k8s ConfigMap:       app-config
  - k8s Secret:          app-secrets
  - k8s PVC:             mssql-data   (SQL Server data — TBL_SC_FLEET_HIST_RAW, AgentAuditLog, etc.)
EOF
fi
if [[ $DO_PINECONE -eq 1 ]]; then
    cat <<EOF
  - Pinecone indexes:    fde-sop-index-local, fde-sop-index-openai
                         (via PINECONE_API_KEY in .env)
EOF
fi
if [[ $DO_IMAGE -eq 1 ]]; then
    echo "  - local docker image:  fde-cold-chain:local"
fi
if [[ $DO_MINIKUBE -eq 1 ]]; then
    echo "  - the ENTIRE minikube cluster (minikube delete)"
fi
echo

if [[ $DRY_RUN -eq 1 ]]; then
    echo "(--dry-run: listing the plan only, nothing below will execute)"
elif [[ $ASSUME_YES -ne 1 ]]; then
    read -rp "Type DESTROY to continue: " confirm
    if [[ "$confirm" != "DESTROY" ]]; then
        echo "Aborted — no changes made."
        exit 1
    fi
fi

if [[ $DO_K8S -eq 1 ]]; then
    echo
    echo "-- Kubernetes --"
    run kubectl delete job db-init sop-ingest --ignore-not-found
    run kubectl delete -f "$PROJECT_ROOT/k8s/app/" -f "$PROJECT_ROOT/k8s/mssql/" --ignore-not-found
    run kubectl delete pvc mssql-data --ignore-not-found
    run kubectl delete secret app-secrets --ignore-not-found
fi

if [[ $DO_PINECONE -eq 1 ]]; then
    echo
    echo "-- Pinecone --"
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] python3 $PROJECT_ROOT/scripts/destroy_pinecone_indexes.py"
    else
        python3 "$PROJECT_ROOT/scripts/destroy_pinecone_indexes.py"
    fi
fi

if [[ $DO_IMAGE -eq 1 ]]; then
    echo
    echo "-- Docker image --"
    echo "(if this image was built inside minikube's daemon, run"
    echo " 'eval \$(minikube docker-env)' in this shell before this script"
    echo " so the removal targets the same daemon it was built in)"
    run docker rmi fde-cold-chain:local
fi

if [[ $DO_MINIKUBE -eq 1 ]]; then
    echo
    echo "-- minikube --"
    run minikube delete
fi

echo
echo "Done."
