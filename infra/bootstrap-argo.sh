#!/bin/bash
# 執行地點:控制節點(root),不是 CloudShell —— CloudShell 沒有叢集存取權
set -euo pipefail
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "--- 確認叢集就緒 ---"
kubectl wait --for=condition=Ready node --all --timeout=300s
kubectl get gatewayclass cilium

echo "--- 安裝 Argo CD ---"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
# ⚠️ 必要:用一般 kubectl apply(client-side)套用這份 install.yaml,
# applicationsets.argoproj.io 這個 CRD 本身太大,存進
# kubectl.kubernetes.io/last-applied-configuration annotation 時會超過
# K8s 對單一 annotation 262144 bytes 的硬限制而報錯,直接讓這一步(以及
# set -e 底下的整個腳本)中止。改用 server-side apply 天生不受這個限制影響。
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

echo "--- 接回 GitOps ---"
# 若 platform-gitops 是 private repo,先建 repo 憑證(public 則整段 if 不會執行)。
# 用環境變數傳入 PAT,避免寫死在腳本裡:GITHUB_USER=... GITOPS_PAT=... bash bootstrap-argo.sh
if [ -n "${GITOPS_PAT:-}" ]; then
  kubectl create secret generic gitops-repo -n argocd \
    --from-literal=type=git \
    --from-literal=url="https://github.com/${GITHUB_USER}/platform-gitops.git" \
    --from-literal=username="${GITHUB_USER}" \
    --from-literal=password="${GITOPS_PAT}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl label secret gitops-repo -n argocd \
    argocd.argoproj.io/secret-type=repository --overwrite
fi
kubectl apply -f "$(dirname "$0")/../application.yaml"

echo "--- Argo initial admin password ---"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
