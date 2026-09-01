# AI Agent SES Credentials Runbook

## Problem

`ai-agent` can decide and log incidents, but email notification currently logs:

```text
ERROR:agent:SES send failed: Unable to locate credentials
```

## Decision

Use a dedicated IAM user for ai-agent SES sends instead of exposing the EC2 node
role to the pod.

The Terraform user is:

```text
platform-ai-agent-ses
```

Its IAM policy allows only:

```text
ses:SendEmail
ses:SendRawEmail
```

from the configured `alert_email` SES identity.

## CloudShell Step

Run Terraform from `platform-infra` and capture outputs:

```bash
cd ~/platform-infra
git pull --ff-only
terraform plan -var="alert_email=<your-alert-email>"
terraform apply -var="alert_email=<your-alert-email>"

terraform output -raw ai_agent_ses_access_key_id
terraform output -raw ai_agent_ses_secret_access_key
```

If applying through GitHub Actions instead of CloudShell, apply the
`platform-infra/bootstrap-oidc` stack first so the `gha_apply` role can manage
the dedicated `platform-ai-agent-ses` IAM user and access key.

The secret access key is sensitive. Do not paste it into chat or shell history
with `echo`.

Terraform also creates an SES email identity for `alert_email`. Open the SES
verification email and complete verification before expecting delivery.

If the SES account is still in sandbox mode, both sender and recipient must be
verified identities. In this lab, `ai-agent` uses `ALERT_EMAIL` as both source
and fallback destination, so verifying the configured `alert_email` is enough
for the fallback path.

## EC2 Control Node Step

Patch Kubernetes Secret from the EC2 control node:

```bash
cd ~/platform-gitops
git pull --ff-only
bash scripts/patch-ai-agent-ses-credentials.sh
```

The script prompts for the access key id and secret access key, patches only
these keys, and restarts ai-agent:

```text
ai-agent-ses-access-key-id
ai-agent-ses-secret-access-key
```

It does not replace the rest of `platform-secrets`.

If `apps/ai-agent.yaml` is present in the current repository checkout, the
script applies it before the rollout so the Deployment consumes the new
optional SES credential environment variables.

## Verification

Confirm environment variables are present without printing values:

```bash
kubectl exec deploy/ai-agent -n default -- sh -c 'test -n "$AWS_ACCESS_KEY_ID" && test -n "$AWS_SECRET_ACCESS_KEY" && echo SES_CREDS_LOADED'
```

Expected:

```text
SES_CREDS_LOADED
```

Then trigger or wait for an ai-agent notification and confirm the previous
error no longer appears:

```bash
kubectl logs deploy/ai-agent -n default --since=10m | grep -E 'SES send failed|Unable to locate credentials'
```

Expected:

```text
no output
```

If SES identity is not verified, the credential error should be gone but SES may
return a message rejection until verification is complete.

## References

- AWS SES IAM access control:
  https://docs.aws.amazon.com/ses/latest/dg/control-user-access.html
- AWS SES email identity verification:
  https://docs.aws.amazon.com/ses/latest/APIReference/API_VerifyEmailIdentity.html
