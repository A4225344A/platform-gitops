# 2026-09-07 實際執行紀錄

## 執行分工

```text
Codex（本機，Windows CloudShell 目錄）：
  讀取 platform-agent / platform-gitops 程式碼與既有部署設定，定位通知信模板、
  Job 證據收集邏輯、CloudFront 網址設定來源，修改程式碼、本機測試、commit、
  push。

GitHub Actions（自動，push 後觸發）：
  platform-agent push 到 main 後執行 Python CI、build/push GHCR image，成功後
  自動回寫 platform-gitops/apps/ai-agent.yaml 的 image tag 與 AGENT_VERSION。

ArgoCD / GitOps（自動，platform-gitops main 更新後同步）：
  套用 ai-agent Deployment、platform-config ConfigMap、monitoring namespace
  read-only RBAC。實際同步狀態需到 ArgoCD 或 kubectl 確認。
```

本次任務不是 UI 靜態網站改版，而是 AI Agent 通知信與 Kubernetes 證據收集修正。
CloudFront 網站網址仍由既有 UI hosting 提供，agent 只透過 `ENGOPS_UI_URL`
把事故頁連結放進信件。

---

# AI Agent 通知信可執行化修復：手把手執行文件

## 目的

修復使用者回報的告警信問題：

```text
1. 信件看不到真正可用的 logs。
2. 信件只有「為什麼不自動修」，沒有清楚告訴人要怎麼處置。
3. 信件沒有網站 / 事故頁網址。
```

同時針對實際收到的 `KubeJobFailed` 信件修正一個根因：該告警代表 Kubernetes
Job 失敗，不是 Deployment 故障。舊版 agent 用 Deployment 名稱去抓 logs/events，
因此遇到 `kps-kube-state-metrics` 這類 Job 告警會收到 Kubernetes API `404`，
信件裡只剩「log read failed」而不是可判讀的 Job 證據。

## 1. 本機：定位通知信模板

```powershell
cd C:\AWS\CloudShell
rg -n "notify_only|Route to|SNS|subject|email|mail|通知|incident|remediation|logs|log" -S .
```

定位結果：

```text
platform-agent/src/agent.py
  notify_owner()       組 SNS 通知信 subject/body
  diagnose()           判讀流程，最後呼叫 notify_owner()
  fetch_logs()         以 Deployment selector 找 Pod log
  fetch_events()       以 Deployment selector 找相關 Kubernetes Events
  build_log_query_url() 組完整日誌深連結
```

## 2. 本機：修改信件內容

修改檔案：

```text
platform-agent/src/agent.py
platform-agent/scripts/test_notifications.py
```

主要調整：

```text
1. 新增 ENGOPS_UI_URL 環境變數。
   設定後信件會產生：
     事故頁面 : https://<CloudFront 網址>/incidents/<incident_id>

2. 新增「建議處置」區塊。
   舊版只寫：
     AI 建議動作: notify_only
     AI 判斷理由: 服務分級 tier-0,政策上不自動修復

   新版改成分清楚：
     AI 原始建議
     系統最後動作
     AI 原始理由
     系統改判理由
     系統保護判斷
     人工處置步驟

3. 新增「告警標籤」區塊。
   會列出 Alertmanager labels，例如：
     alertname
     namespace
     job_name
     job
     service
     pod
     container
     severity

4. 保留「原始證據(已脫敏摘錄)」。
   信件內只放已脫敏且截斷的 logs/events 摘錄，避免把 token、email、IP、
   ID 等敏感資訊直接寄出。完整歷史日誌仍透過 service_catalog 的
   log_query_url_template 產生深連結。
```

## 3. 本機：修正 KubeJobFailed 證據收集

修改檔案：

```text
platform-agent/src/agent.py
platform-gitops/apps/ai-agent-rbac.yaml
```

新增 agent 行為：

```text
alertname == "KubeJobFailed" 時：
  1. 從 Alertmanager labels 讀 namespace。
  2. 從 labels 讀 job_name 或 job。
  3. 用 Kubernetes BatchV1 API read_namespaced_job() 確認 Job 存在。
  4. 用 label selector job-name=<job> 找 failed Pod。
  5. 讀取最多前三個 Job Pod 的 logs。
  6. 讀取該 namespace 的 Events，過濾 Job 與 Pod 相關事件。

其他 Deployment / Pod / Service 類告警：
  維持原本 Deployment selector -> Pod logs/events 的流程。
```

新增 GitOps RBAC：

```text
namespace: monitoring
Role: ai-agent-monitoring-reader
verbs: get, list
resources:
  core: pods, pods/log, events
  batch: jobs

RoleBinding:
  把 default namespace 的 ServiceAccount ai-agent 綁到 monitoring namespace
  的 read-only Role。
```

這是只讀權限，不包含 create、update、patch、delete。

## 4. 本機：補 CloudFront 事故頁設定入口

修改檔案：

```text
platform-agent/.env.example
platform-gitops/apps/ai-agent.yaml
platform-gitops/apps/platform-config.yaml.tmpl
platform-gitops/apps/platform-config.yaml
platform-gitops/.github/workflows/render-platform-config.yml
```

新增設定方式：

```text
platform-gitops GitHub repo variables:
  ENGOPS_UI_URL=https://<CloudFront distribution domain>
```

agent Deployment 從 ConfigMap 讀取：

```yaml
- name: ENGOPS_UI_URL
  valueFrom:
    configMapKeyRef:
      name: platform-config
      key: engops-ui-url
      optional: true
```

如果尚未設定，信件會明確顯示：

```text
事故頁面 : 尚未設定 ENGOPS_UI_URL,無法產生網站網址
```

## 5. 本機：驗證

執行：

```powershell
cd C:\AWS\CloudShell\platform-agent
python -m py_compile src\agent.py src\genai_semconv.py scripts\test_notifications.py
python scripts\test_notifications.py
python scripts\smoke_import.py
python scripts\test_sanitize_resources.py
python scripts\test_ask_incident.py
git diff --check
```

實際結果：

```text
py_compile: PASS
test_notifications.py: PASS，2 tests OK
smoke_import.py: PASS
test_sanitize_resources.py: PASS，1 test OK
test_ask_incident.py: PASS，6 tests OK
git diff --check: PASS
```

GitOps YAML 驗證：

```powershell
cd C:\AWS\CloudShell\platform-gitops
python -c "import yaml; [doc for doc in yaml.safe_load_all(open('apps/ai-agent-rbac.yaml', encoding='utf-8'))]; print('rbac yaml ok')"
```

實際結果：

```text
rbac yaml ok
```

## 6. 本機：commit / push

platform-agent：

```text
1636452 feat: enrich incident alert emails
aa34106 test: cover incident alert email content
bd5d422 fix: make alert emails actionable
```

platform-gitops：

```text
d20698f feat: expose engops ui url to agent
799c5c3 fix: quote engops ui url config
884ca48 fix: allow agent to read monitoring job evidence
92e4b89 Deploy ai-agent bd5d4221ecca
```

GitHub Actions 已回寫：

```text
platform-gitops/apps/ai-agent.yaml
  image: ghcr.io/a4225344a/ai-agent:sha-bd5d4221ecca
  AGENT_VERSION: sha-bd5d4221ecca
```

## 尚未執行/未驗證項目

```text
1. ENGOPS_UI_URL 尚未填入實際 CloudFront 網址。
   本機 AWS CLI 回報 NoCredentials，無法查出 E1VMEDDXP35S53 對應的
   *.cloudfront.net。需由 AWS Console / Terraform output / AWS CLI 查到
   CloudFront domain 後，填入 platform-gitops repo variable ENGOPS_UI_URL。

2. ArgoCD 是否已同步到叢集尚未在本機確認。
   本工作階段沒有 kubectl cluster credential 驗證線上 Pod / RoleBinding 狀態。

3. 下一封真實 SNS email 尚未重新觸發告警驗證。
   本機已用 mocked SNS publish 驗證信件 body 內容，但尚未透過真實
   Alertmanager -> ai-agent -> SNS 全鏈路重新寄一封確認。
```

## 驗收結果

```text
agent py_compile: PASS
agent notification regression: PASS
agent smoke import: PASS
agent sanitizer regression: PASS
agent ask-incident regression: PASS
GitOps RBAC YAML parse: PASS
agent image 回寫 GitOps: PASS，sha-bd5d4221ecca
CloudFront 事故頁 URL: 待設定 ENGOPS_UI_URL
真實告警信 end-to-end: 待下一次告警或手動觸發 webhook 驗證
```
