# Task 11.2 Kubernetes Runtime Validation Runbook

## Scope

Run this validation from the EC2 control node, not from CloudShell. The EC2
control node already has K3s kubeconfig and can query in-cluster resources.

The CloudShell / management shell validates only the AWS/RDS layer through
`platform-infra`.

## Standard Command

```bash
cd ~/platform-gitops
git pull --ff-only
bash scripts/validate-task-11-2-k8s-runtime.sh
```

Optional endpoint comparison:

```bash
EXPECTED_PGHOST=platform-postgres.c7sucg26mtos.ap-northeast-1.rds.amazonaws.com \
bash scripts/validate-task-11-2-k8s-runtime.sh
```

## Expected Result

```text
REQUIRED_SECRETS_LOADED
postgres_connection=ok
pg_available_extension.vector=<version>
PASS: Kubernetes runtime layer can reach RDS and pgvector validation completed without printing secrets.
```

`pg_extension.vector=not_installed` is acceptable when pgvector is available but
not installed in the `postgres` database. Install it only if the application
needs vector columns in that database.

## Security Notes

The script does not print secret values. It only prints Secret key names and
boolean/runtime status.

Do not run:

```bash
kubectl exec deploy/ai-agent -- printenv
```

That can expose `PGPASSWORD`, `LITELLM_MASTER_KEY`, and webhook tokens.
