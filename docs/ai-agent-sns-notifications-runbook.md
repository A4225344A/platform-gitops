# AI Agent SES → SNS Notification Migration Runbook

## Problem

`ai-agent`'s `notify_owner()` sent email via `ses.send_email()`, with the
`Source` address set to a personal webmail identity (Yahoo/Gmail) configured
through `ALERT_EMAIL`. Once the IAM/SES identity mismatch that originally
caused `AccessDenied` was fixed, sends still failed — this time past IAM,
past SES, and into an actual bounce:

```text
Delivery Status Notification (Failure)
An error occurred while trying to deliver the mail to the following recipients:
<the exact address configured as ALERT_EMAIL>
```

This happened for **both** a self-send (Yahoo → Yahoo) and a cross-provider
send (Yahoo → Gmail). Root cause: Yahoo and Gmail both publish a strict
DMARC policy (`p=reject`) for their own domains. SES is not an authorized
sender for `yahoo.com.tw` or `gmail.com` — it can only sign with its own
`amazonses.com` domain — so any message claiming `From: someone@yahoo.com.tw`
sent through SES fails DMARC alignment at any DMARC-enforcing receiver. This
is not fixable by changing which free webmail address you use; it applies to
all of them equally. The only SES-side fix is verifying a domain you control
DNS for (SPF/DKIM records), which this project's ADR-11.5-001 deliberately
avoids paying for.

## Decision

Stop calling SES directly. Publish notifications to an SNS topic instead.
SNS sends its notification emails from Amazon's own already-authenticated
sending domain — it never claims to be the recipient's own provider — so it
never hits the DMARC wall SES does.

Trade-off accepted: SNS only delivers to addresses that have confirmed a
subscription to the topic (one-time click per recipient). This replaces the
old dynamic per-service routing (`service_catalog.owner_email` /
`escalation_email` chosen as the SES `Destination` per alert) with a fixed
subscriber list maintained out of band via `aws sns subscribe`.
`owner_email`/`escalation_email` are still looked up and now appear as a
"Route to" line inside the message body, for a human to act on, instead of
being the actual delivery target.

## What Changed (three repos)

| Repo | File | Change |
|---|---|---|
| `platform-infra` | `modules/aws-infra/sns.tf` (new) | `aws_sns_topic.ai_agent_alerts` (`platform-ai-agent-alerts`) + `aws_iam_user_policy.ai_agent_sns` granting `sns:Publish` on that topic to the **existing** `platform-ai-agent-ses` IAM user — same access key already injected into the pod, no credential rotation needed |
| `platform-infra` | `outputs.tf` (both module + root) | new `ai_agent_alerts_topic_arn` output |
| `platform-gitops` | `apps/platform-config.yaml.tmpl`, `.github/workflows/render-platform-config.yml` | render a new `sns-topic-arn` ConfigMap key from repo variable `SNS_TOPIC_ARN`, same pattern as `PGHOST`/`ALERT_EMAIL` |
| `platform-gitops` | `apps/ai-agent.yaml` | new `SNS_ALERT_TOPIC_ARN` env var, sourced from that ConfigMap key |
| `platform-agent` | `src/agent.py` | `notify_owner()` calls `sns.publish(TopicArn=SNS_ALERT_TOPIC_ARN, Subject=..., Message=...)` instead of `ses.send_email()` |

## Step-by-Step

### 1. CloudShell / control node — create the SNS topic + IAM permission

```bash
cd ~/platform-infra
git pull --ff-only
terraform plan
terraform apply
terraform output ai_agent_alerts_topic_arn
```

Expected plan: `Plan: 2 to add, 0 to change, 0 to destroy` — only
`aws_sns_topic.ai_agent_alerts` and `aws_iam_user_policy.ai_agent_sns`. If
this ran via the `Terraform Apply` GitHub Actions workflow (triggered
automatically on push to `modules/**`/`*.tf`), the `apply` job targets the
`production` environment and needs a reviewer to approve it before it runs.

If the plan shows unrelated resource changes (e.g. an RDS parameter group
update), that's a different pending change already in the repo — approve or
defer it separately, don't conflate it with this migration.

### 2. GitHub — set the `platform-gitops` repo variable

Settings → Secrets and variables → Actions → Variables → add:

```text
SNS_TOPIC_ARN = <ARN printed in step 1>
```

### 3. GitHub — re-render `platform-config`

Actions → **"Render platform-config"** → Run workflow (`main` branch). This
regenerates `apps/platform-config.yaml`'s `sns-topic-arn` key and commits it;
ArgoCD's `selfHeal` picks it up within its sync interval.

### 4. Subscribe a real recipient

Run this from a session with real IAM permissions — **not** the control
EC2 node's own AWS CLI session. The EC2 instance's assumed role
(`platform-node-role`) is deliberately scoped narrow and lacks
`sns:Subscribe`/`sns:ListTopics`/`ses:GetIdentityVerificationAttributes`;
those calls fail with `AccessDenied` from that role regardless of whether
anything else is wrong.

```bash
aws sns subscribe --region ap-northeast-1 \
  --topic-arn "<ARN from step 1>" \
  --protocol email --notification-endpoint <recipient-address>
```

Open the "AWS Notification - Subscription Confirmation" email and click
**Confirm subscription**. One-time per recipient. This is the one failure
mode the API never surfaces: `sns:Publish` succeeds with no error even when
nobody has confirmed yet, so an unconfirmed subscription looks identical to
a working one from the pod's side — always double check this step directly.

### 5. Control node — confirm ConfigMap synced, restart the pod

```bash
kubectl get configmap platform-config -o jsonpath='{.data.sns-topic-arn}{"\n"}'
# empty → force a sync instead of waiting for the interval
kubectl -n argocd patch app platform-apps --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'

kubectl rollout restart deploy/ai-agent
kubectl rollout status deploy/ai-agent --timeout=180s
```

`ConfigMap` changes are not hot-reloaded into a running container's
environment — the restart is required, independent of whatever image tag is
currently deployed.

### 6. Trigger a test alert and verify

```bash
TOKEN=$(kubectl get secret platform-secrets -o jsonpath='{.data.alert-webhook-token}' | base64 -d)
kubectl port-forward svc/ai-agent 18080:8080 >/tmp/ai-agent-pf.log 2>&1 &
PF_PID=$!
sleep 2
curl -fsS -X POST http://127.0.0.1:18080/alert \
  -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
  -d '{"groupKey":"sns-check","commonLabels":{},
       "alerts":[{"status":"firing","labels":{"alertname":"PodCrashLooping","service":"<unused-service-name>"}}]}'
kill "$PF_PID" 2>/dev/null || true
```

Use a service name never tested this session — `in_cooldown()` silently
short-circuits repeat tests of the same `(alertname, service)` pair within
`COOLDOWN_MIN` (default 10 minutes) before `notify_owner()` is ever called.

Wait at least 30-60 seconds (the full pipeline calls Presidio, embeddings,
and the LLM, each with its own timeout up to 60s) before checking:

```bash
kubectl logs deploy/ai-agent --since=10m | grep -v -E "GET /healthz|GET /metrics"
```

No `SNS publish failed` line → published cleanly. If timing is uncertain or
the log window may have missed it, check the database directly — it's
ground truth, `kubectl logs` isn't always (see pitfall #3 below):

```bash
PG=$(kubectl get secret platform-secrets -o jsonpath='{.data.postgres-password}' | base64 -d)
RDS_HOST=$(kubectl get configmap platform-config -o jsonpath='{.data.PGHOST}')
kubectl run pg-debug --rm -i --restart=Never --image=postgres:16-bookworm \
  --env="PGPASSWORD=${PG}" -- psql -h "${RDS_HOST}" -U postgres -d postgres -c \
  "SELECT id, service, status, outcome, ended_at FROM incidents
     WHERE service='<unused-service-name>' ORDER BY id DESC LIMIT 1;"
```

`status=closed` confirms the pipeline actually ran end to end. Finally,
confirm the subscribed recipient's inbox — subject line will be plain ASCII,
e.g. `[AIOps][SEV3] <service> - PodCrashLooping - needs decision`.

## Known Pitfalls (all hit during this migration, in order)

1. **`platform-infra` and `platform-gitops` each keep their own copy of
   `ALERT_EMAIL`** as separate GitHub Actions repo variables. They can drift
   out of sync silently — this is exactly why SES kept failing: one had a
   typo, the other pointed at a completely different, already-verified
   identity from an earlier, unrelated setup. `ALERT_EMAIL` still exists
   post-migration (for the "Route to" body line) but no longer needs to be a
   verified SES sender at all.
2. **SNS `Subject` must be plain ASCII, ≤100 characters, no line breaks**
   (RFC 2822 header constraint). A non-conforming subject is silently
   replaced with the generic `"AWS Notification Message"` — not rejected,
   just wrong. `agent.py` keeps a small English-only status map for the
   subject line specifically; the rich Chinese explanation stays in the
   message body, which has no such restriction.
3. **`kubectl logs --since=Nm` gets buried under health-check/scrape
   noise.** The readinessProbe (`/healthz`, every 10s) and Prometheus scrape
   (`/metrics`, every 30s) produce a steady stream of log lines; `tail -N`
   on a busy pod will cut the one interesting line before you ever see it,
   and a `--since` window computed from "now" can miss an event that
   happened right at its edge. Filter noise out
   (`grep -v -E "GET /healthz|GET /metrics"`) instead of tailing, and when
   timing is uncertain, check `incidents`/`alert_queue` in Postgres
   directly.
4. **10-minute cooldown** (`COOLDOWN_MIN`, keyed on `(alertname, service)`)
   silently short-circuits a repeat test of the same combo — the incident
   still gets recorded (`status='skipped_cooldown'`), but `notify_owner()`
   is never called and nothing resembling an error appears in the logs.
   Always use a fresh, never-tested service name when retesting.
5. **The control EC2 node's own AWS CLI session has much narrower IAM
   permissions than an admin session.** Its assumed role
   (`platform-node-role`) can publish to the one specific SNS topic granted
   in step 1, but cannot `sns:Subscribe`, `sns:ListTopics`, or
   `ses:GetIdentityVerificationAttributes`. An `AccessDenied` from control
   EC2 on one of those calls is a permission-boundary issue, not proof of a
   broader account-level problem — rerun the same command from a session
   with real IAM/console access instead.
6. **A confirmed `sns:Publish` call is not proof of delivery.** If nobody
   has clicked "Confirm subscription" yet, publish still succeeds with no
   error. Absence of `SNS publish failed` in the logs means the API call
   worked, not that a human received anything.

## Verification Checklist

- [ ] `terraform output ai_agent_alerts_topic_arn` returns a real ARN
- [ ] `kubectl get configmap platform-config -o jsonpath='{.data.sns-topic-arn}'` matches it
- [ ] recipient has clicked "Confirm subscription"
- [ ] `kubectl rollout status deploy/ai-agent` shows the restarted rollout succeeded
- [ ] a fresh test alert produces `status=closed` in `incidents` with no `SNS publish failed` in the logs
- [ ] the subscribed recipient actually received the email, plain-ASCII subject intact

## References

- SNS email notifications and subscription confirmation:
  https://docs.aws.amazon.com/sns/latest/dg/sns-email-notifications.html
- SNS `Publish` API subject/message constraints:
  https://docs.aws.amazon.com/sns/latest/api/API_Publish.html
- Why sending "From" a personal webmail address via a third party fails DMARC:
  https://docs.aws.amazon.com/ses/latest/dg/send-email-authentication-dmarc.html
- Superseded: [ai-agent-ses-credentials-runbook.md](ai-agent-ses-credentials-runbook.md)
  (SES credential setup — no longer used for sending, kept for history)
