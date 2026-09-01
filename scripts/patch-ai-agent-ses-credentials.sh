#!/usr/bin/env bash
set -euo pipefail

DEFAULT_NS="${DEFAULT_NS:-default}"
PLATFORM_SECRET="${PLATFORM_SECRET:-platform-secrets}"
AI_AGENT_DEPLOY="${AI_AGENT_DEPLOY:-ai-agent}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

need kubectl
need base64

if [ -z "${AI_AGENT_SES_ACCESS_KEY_ID:-}" ]; then
  read -rp "AI agent SES access key id: " AI_AGENT_SES_ACCESS_KEY_ID
fi

if [ -z "${AI_AGENT_SES_SECRET_ACCESS_KEY:-}" ]; then
  read -rsp "AI agent SES secret access key: " AI_AGENT_SES_SECRET_ACCESS_KEY
  echo
fi

access_key_b64="$(printf '%s' "$AI_AGENT_SES_ACCESS_KEY_ID" | base64 | tr -d '\n')"
secret_key_b64="$(printf '%s' "$AI_AGENT_SES_SECRET_ACCESS_KEY" | base64 | tr -d '\n')"

kubectl get secret "$PLATFORM_SECRET" -n "$DEFAULT_NS" >/dev/null

kubectl patch secret "$PLATFORM_SECRET" -n "$DEFAULT_NS" --type=merge \
  -p "{\"data\":{\"ai-agent-ses-access-key-id\":\"${access_key_b64}\",\"ai-agent-ses-secret-access-key\":\"${secret_key_b64}\"}}"

unset AI_AGENT_SES_ACCESS_KEY_ID AI_AGENT_SES_SECRET_ACCESS_KEY
unset access_key_b64 secret_key_b64

if [ -f apps/ai-agent.yaml ]; then
  kubectl apply -f apps/ai-agent.yaml
fi

kubectl rollout restart deploy/"$AI_AGENT_DEPLOY" -n "$DEFAULT_NS"
kubectl rollout status deploy/"$AI_AGENT_DEPLOY" -n "$DEFAULT_NS" --timeout=180s

echo "patched ai-agent SES credentials without replacing other ${PLATFORM_SECRET} keys"
echo "verify with: kubectl exec deploy/${AI_AGENT_DEPLOY} -n ${DEFAULT_NS} -- sh -c 'test -n \"\$AWS_ACCESS_KEY_ID\" && test -n \"\$AWS_SECRET_ACCESS_KEY\" && echo SES_CREDS_LOADED'"
