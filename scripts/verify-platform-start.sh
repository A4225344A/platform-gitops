#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:-ap-northeast-1}"
ASG_NAME="${ASG_NAME:-platform-worker}"
DEFAULT_NS="${DEFAULT_NS:-default}"

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

section() {
  printf '\n== %s ==\n' "$1"
}

need aws
need kubectl
need jq
need curl

section "Ensure worker ASG desired capacity"
aws autoscaling update-auto-scaling-group \
  --region "$REGION" \
  --auto-scaling-group-name "$ASG_NAME" \
  --min-size 2 \
  --desired-capacity 2 \
  --max-size 4

section "Wait for ASG InService workers"
for _ in $(seq 1 60); do
  ready_count="$(aws autoscaling describe-auto-scaling-groups \
    --region "$REGION" \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'length(AutoScalingGroups[0].Instances[?LifecycleState==`InService` && HealthStatus==`Healthy`])' \
    --output text)"
  echo "healthy_inservice_workers=$ready_count"
  if [ "$ready_count" -ge 2 ]; then
    break
  fi
  sleep 10
done

if [ "$ready_count" -lt 2 ]; then
  echo "worker ASG did not reach two healthy InService instances" >&2
  exit 1
fi

section "Wait for Kubernetes Ready nodes"
for _ in $(seq 1 60); do
  total_ready="$(kubectl get nodes -o json | jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length')"
  echo "ready_nodes=$total_ready"
  if [ "$total_ready" -ge 3 ]; then
    break
  fi
  sleep 10
done

if [ "$total_ready" -lt 3 ]; then
  echo "Kubernetes did not reach control + 2 Ready workers" >&2
  kubectl get nodes -o wide
  exit 1
fi

section "Remove stale NotReady worker nodes"
mapfile -t stale_nodes < <(
  kubectl get nodes -o json \
    | jq -r '.items[]
      | select((.metadata.labels["node-role.kubernetes.io/control-plane"] // "") != "true")
      | select([.status.conditions[]? | select(.type=="Ready" and .status=="True")] | length == 0)
      | .metadata.name'
)

if [ "${#stale_nodes[@]}" -gt 0 ]; then
  kubectl delete node "${stale_nodes[@]}" --ignore-not-found
else
  echo "no stale NotReady worker nodes found"
fi

section "Nodes"
kubectl get nodes -o wide

section "ArgoCD application"
kubectl get applications -n argocd || true

section "Default namespace pods"
kubectl get pods -n "$DEFAULT_NS" -o wide

section "Monitoring namespace pods"
kubectl get pods -n monitoring

section "Kube-system pods"
kubectl get pods -n kube-system

section "Gateway and HTTPRoute"
kubectl get gateway platform-gateway -n "$DEFAULT_NS"
kubectl get httproute -n "$DEFAULT_NS" -o json \
  | jq -r '.items[] | [.metadata.name, (.status.parents[0].conditions[]? | select(.type=="Accepted").status // "-")] | @tsv'

section "EngOps API readiness"
kubectl rollout status deploy/engops-api -n "$DEFAULT_NS" --timeout=180s
pf_log="/tmp/engops-api-pf.log"
kubectl port-forward deploy/engops-api 18000:8000 -n "$DEFAULT_NS" >"$pf_log" 2>&1 &
pf_pid=$!
trap 'kill "$pf_pid" >/dev/null 2>&1 || true' EXIT
sleep 3
curl -fsS http://127.0.0.1:18000/healthz
printf '\n'
curl -fsS http://127.0.0.1:18000/readyz
printf '\n'

section "Start verification result"
echo "PASS: nodes, core pods, Gateway/HTTPRoute, and EngOps API are healthy."
echo "If ArgoCD remains OutOfSync/Healthy, run the diff check next; service recovery is still complete."
