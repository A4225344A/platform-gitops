#!/usr/bin/env bash
set -euo pipefail

DEFAULT_NS="${DEFAULT_NS:-default}"
MONITORING_NS="${MONITORING_NS:-monitoring}"
PLATFORM_SECRET="${PLATFORM_SECRET:-platform-secrets}"
ALERTMANAGER_SECRET="${ALERTMANAGER_SECRET:-ai-agent-webhook-token}"

required_platform_keys=(
  "alert-webhook-token"
  "postgres-password"
  "litellm-master-key"
  "grafana-admin-password"
)

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

has_secret_key() {
  local namespace="$1"
  local secret="$2"
  local key="$3"

  kubectl get secret "$secret" -n "$namespace" -o json \
    | jq -e --arg key "$key" '.data[$key] != null' >/dev/null
}

need kubectl
need openssl
need base64
need jq

kubectl get secret "$PLATFORM_SECRET" -n "$DEFAULT_NS" >/dev/null

for key in "${required_platform_keys[@]}"; do
  if ! has_secret_key "$DEFAULT_NS" "$PLATFORM_SECRET" "$key"; then
    echo "refusing to rotate: Secret ${DEFAULT_NS}/${PLATFORM_SECRET} is missing key ${key}" >&2
    echo "restore the missing key first, then rerun this script." >&2
    exit 1
  fi
done

new_token="$(openssl rand -hex 32)"
token_b64="$(printf '%s' "$new_token" | base64 | tr -d '\n')"

kubectl patch secret "$PLATFORM_SECRET" -n "$DEFAULT_NS" --type=merge \
  -p "{\"data\":{\"alert-webhook-token\":\"${token_b64}\"}}"

if kubectl get secret "$ALERTMANAGER_SECRET" -n "$MONITORING_NS" >/dev/null 2>&1; then
  kubectl patch secret "$ALERTMANAGER_SECRET" -n "$MONITORING_NS" --type=merge \
    -p "{\"data\":{\"token\":\"${token_b64}\"}}"
else
  kubectl create secret generic "$ALERTMANAGER_SECRET" -n "$MONITORING_NS" \
    --from-literal=token="$new_token"
fi

kubectl rollout restart deploy/ai-agent -n "$DEFAULT_NS"
kubectl rollout status deploy/ai-agent -n "$DEFAULT_NS" --timeout=180s

echo "rotated ai-agent webhook token without replacing other ${PLATFORM_SECRET} keys"
echo "verify with: kubectl exec deploy/ai-agent -n ${DEFAULT_NS} -- sh -c 'test -n \"\$ALERT_WEBHOOK_TOKEN\" && echo TOKEN_LOADED'"
