#!/usr/bin/env bash
set -euo pipefail

DEFAULT_NS="${DEFAULT_NS:-default}"
AI_AGENT_DEPLOY="${AI_AGENT_DEPLOY:-ai-agent}"
PLATFORM_SECRET="${PLATFORM_SECRET:-platform-secrets}"
EXPECTED_PGHOST="${EXPECTED_PGHOST:-}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

section() {
  printf '\n== %s ==\n' "$1"
}

need kubectl
need jq

section "Kubernetes Secret key presence"
kubectl get secret "$PLATFORM_SECRET" -n "$DEFAULT_NS" -o json \
  | jq -r '.data | keys[]'

kubectl get secret "$PLATFORM_SECRET" -n "$DEFAULT_NS" -o json \
  | jq -e '.data["postgres-password"] != null' >/dev/null

section "ai-agent RDS runtime wiring"
agent_pghost="$(kubectl exec deploy/"$AI_AGENT_DEPLOY" -n "$DEFAULT_NS" -- printenv PGHOST)"
printf 'ai_agent_pghost=%s\n' "$agent_pghost"

if [ -n "$EXPECTED_PGHOST" ]; then
  test "$agent_pghost" = "$EXPECTED_PGHOST"
fi

kubectl exec deploy/"$AI_AGENT_DEPLOY" -n "$DEFAULT_NS" -- sh -c \
  'test -n "$PGPASSWORD" && test -n "$LITELLM_MASTER_KEY" && echo REQUIRED_SECRETS_LOADED'

section "pgvector availability from ai-agent"
kubectl exec -i deploy/"$AI_AGENT_DEPLOY" -n "$DEFAULT_NS" -- python - <<'PY'
import os
import psycopg2

conn = psycopg2.connect(
    host=os.environ["PGHOST"],
    user="postgres",
    password=os.environ["PGPASSWORD"],
    dbname="postgres",
    connect_timeout=10,
)
try:
    with conn.cursor() as cur:
        cur.execute("select version()")
        print("postgres_connection=ok")
        cur.execute("select default_version from pg_available_extensions where name = 'vector'")
        row = cur.fetchone()
        if not row:
            raise SystemExit("pg_available_extension.vector=missing")
        print(f"pg_available_extension.vector={row[0]}")
        cur.execute("select extname, extversion from pg_extension where extname = 'vector'")
        ext = cur.fetchone()
        if ext:
            print(f"pg_extension.vector={ext[1]}")
        else:
            print("pg_extension.vector=not_installed")
finally:
    conn.close()
PY

section "Task 11.2 Kubernetes runtime result"
echo "PASS: Kubernetes runtime layer can reach RDS and pgvector validation completed without printing secrets."
