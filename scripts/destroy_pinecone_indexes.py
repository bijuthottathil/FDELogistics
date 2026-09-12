import os
import sys
from pathlib import Path
from dotenv import load_dotenv
from pinecone import Pinecone

# ==========================================
# PINECONE TEARDOWN
# Deletes the two indexes scripts/ingest_sop_pinecone.py can create.
# Irreversible: once dropped, the embedded SOP corpus is gone until
# scripts/ingest_sop_pinecone.py is re-run in full.
# ==========================================
script_dir = Path(__file__).resolve().parent
project_root = script_dir.parent
load_dotenv(project_root / ".env")

PINECONE_API_KEY = os.getenv("PINECONE_API_KEY")
TARGET_INDEXES = ["fde-sop-index-local", "fde-sop-index-openai"]

if not PINECONE_API_KEY:
    print("PINECONE_API_KEY not set in .env — nothing to do.")
    sys.exit(0)

pc = Pinecone(api_key=PINECONE_API_KEY)
existing = pc.list_indexes().names()

deleted = []
for name in TARGET_INDEXES:
    if name in existing:
        print(f"Deleting Pinecone index: {name}")
        pc.delete_index(name)
        deleted.append(name)
    else:
        print(f"Skipping (not found): {name}")

# The hash cache only makes sense relative to a live index; once the index is
# gone, a stale cache would make the next sop-ingest run skip files it thinks
# are already embedded.
cache_file = project_root / "data" / "cache" / "ingestion_hash_cache.json"
if deleted and cache_file.exists():
    cache_file.write_text("{}\n")
    print(f"Reset {cache_file.relative_to(project_root)} so the next ingest re-embeds everything.")

print("Pinecone teardown complete.")
