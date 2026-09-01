# AI Agent Secret Rotation Runbook

## Purpose

Rotate the `alert-webhook-token` without replacing the rest of
`default/platform-secrets`.

Do not recreate `platform-secrets` with only one `--from-literal` value. That
overwrites the Secret data and removes keys required by `ai-agent`, PostgreSQL,
LiteLLM, and Grafana.

## Incident Signature

The broken rollout shows:

```text
CreateContainerConfigError
Error: couldn't find key postgres-password in Secret default/platform-secrets
```

This means `platform-secrets` was applied without all required keys.

## Standard Rotation

Run the guarded script from this repository:

```bash
cd ~/platform-gitops
git pull --ff-only
bash scripts/rotate-ai-agent-webhook-token.sh
```

The script patches only:

```text
default/platform-secrets: alert-webhook-token
monitoring/ai-agent-webhook-token: token
```

It preserves the other keys in `platform-secrets`.

## Preflight Guard

The script refuses to rotate if `default/platform-secrets` is missing any of:

```text
alert-webhook-token
postgres-password
litellm-master-key
grafana-admin-password
```

Restore missing keys first, then rerun the script.

## Verification

Check key names only. Do not print secret values:

```bash
kubectl get secret platform-secrets -n default -o json | jq -r '.data | keys[]'
```

Expected keys include:

```text
alert-webhook-token
grafana-admin-password
litellm-master-key
postgres-password
```

Verify rollout:

```bash
kubectl rollout status deploy/ai-agent -n default --timeout=180s
kubectl get pods -n default -l app=ai-agent -o wide
```

Verify runtime secret loading without printing the values:

```bash
kubectl exec deploy/ai-agent -n default -- sh -c 'test -n "$ALERT_WEBHOOK_TOKEN" && test -n "$PGPASSWORD" && test -n "$LITELLM_MASTER_KEY" && echo SECRETS_LOADED'
```

Expected:

```text
SECRETS_LOADED
```

## Forbidden Pattern

Do not run this for token-only rotation:

```bash
kubectl create secret generic platform-secrets -n default \
  --from-literal=alert-webhook-token="$NEW_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
```

It replaces the whole Secret data set and can break the next rollout.
