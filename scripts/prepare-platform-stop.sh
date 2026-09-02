#!/usr/bin/env bash
set -euo pipefail

REGION="${REGION:-ap-northeast-1}"
ASG_NAME="${ASG_NAME:-platform-worker}"
DELETE_NODES="${DELETE_NODES:-true}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-180s}"

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

section "Current Kubernetes nodes"
kubectl get nodes -o wide

mapfile -t worker_nodes < <(
  kubectl get nodes -o json \
    | jq -r '.items[]
      | select((.metadata.labels["node-role.kubernetes.io/control-plane"] // "") != "true")
      | .metadata.name'
)

if [ "${#worker_nodes[@]}" -eq 0 ]; then
  echo "no worker nodes found; continuing with ASG scale-down"
else
  section "Drain worker nodes"
  for node in "${worker_nodes[@]}"; do
    echo "draining $node"
    kubectl drain "$node" \
      --ignore-daemonsets \
      --delete-emptydir-data \
      --force \
      --timeout="$DRAIN_TIMEOUT" || {
        echo "drain failed for $node; inspect PDBs and pods before stopping" >&2
        echo "hint: kubectl get pdb -A" >&2
        echo "hint: kubectl get pods -A -o wide | grep '$node'" >&2
        exit 1
      }
  done
fi

section "Scale worker ASG to zero"
aws autoscaling update-auto-scaling-group \
  --region "$REGION" \
  --auto-scaling-group-name "$ASG_NAME" \
  --min-size 0 \
  --desired-capacity 0

section "Wait for ASG instances to drain"
for _ in $(seq 1 60); do
  instance_count="$(aws autoscaling describe-auto-scaling-groups \
    --region "$REGION" \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'length(AutoScalingGroups[0].Instances)' \
    --output text)"
  echo "asg_instance_count=$instance_count"
  if [ "$instance_count" = "0" ]; then
    break
  fi
  sleep 10
done

if [ "$instance_count" != "0" ]; then
  echo "ASG still has instances; refusing to delete node objects" >&2
  exit 1
fi

if [ "$DELETE_NODES" = "true" ] && [ "${#worker_nodes[@]}" -gt 0 ]; then
  section "Delete drained worker node objects"
  kubectl delete node "${worker_nodes[@]}" --ignore-not-found
fi

section "Final Kubernetes nodes"
kubectl get nodes -o wide

section "Stop preparation result"
echo "PASS: worker workloads drained, ASG scaled to zero, and old worker node objects removed."
echo "Next: stop the platform-control EC2 instance from CloudShell."
