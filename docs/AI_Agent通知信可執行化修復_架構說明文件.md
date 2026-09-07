# 2026-09-07 實際整改紀錄

## 問題發現方式

```text
使用者提供實際 SNS email 內容，指出雖然信件已新增「建議處置」與
「原始證據」區塊，但收件人仍看不到 AI 要自己怎麼處置。

實際讀 platform-agent/src/agent.py 後確認：問題不是單一文案不足，而是
三個資料流混在一起：
  1. AI 原始判斷。
  2. 系統 guard 最後把動作降成 notify_only 的理由。
  3. 人工接手時需要的具體處置步驟。

此外，使用者信件中的 `KubeJobFailed / kps-kube-state-metrics` 顯示
logs/events 都是 Kubernetes API 404。這代表 agent 用 Deployment 邏輯
處理了 Job 類告警，證據收集目標錯誤。
```

## 找到的問題點

```text
1. notify_owner() 把 action/reason 當成信件裡的主要「AI 建議」。
   但 diagnose() 會經過 tier policy、human approval、circuit breaker 等
   guard。guard 一旦把 action 改成 notify_only，信件就只剩「系統最後動作」，
   看不到模型原本的判斷脈絡。

2. 信件的「建議處置」沒有 runbook-style 的人工步驟。
   對值班者來說，「服務分級 tier-0 不自動修復」只是治理原因，不是處置方法。
   收件人需要知道下一步要查哪個 Kubernetes 物件、怎麼判斷、什麼情況要清理、
   什麼情況要修 GitOps / Helm / Job template。

3. KubeJobFailed 不是 Deployment 告警。
   舊流程固定呼叫 fetch_logs(service) / fetch_events(service)，而這兩個函式
   都先 read_namespaced_deployment(service)。Job 類告警沒有同名 Deployment
   時必然 404，導致信件內的「原始證據」只剩 API error。

4. 網站網址不應硬寫在程式碼。
   platform-ui 是 S3 + CloudFront 靜態網站，網址屬部署環境設定。agent 只應
   讀取環境變數並組事故頁 URL，避免不同 AWS 帳號、不同 CloudFront distribution
   或自訂 domain 時需要改 code。
```

---

# AI Agent 通知信可執行化修復：架構說明文件

## 範圍

```text
本次改動涵蓋：
  platform-agent/src/agent.py
    - 通知信 body 組裝
    - KubeJobFailed 的 Job logs/events 收集
    - ENGOPS_UI_URL 事故頁連結
    - Alertmanager labels 顯示
    - AI 原始判斷與系統最後動作分離

  platform-agent/scripts/test_notifications.py
    - SNS publish mock regression test
    - 驗證 logs、網站網址、人工處置步驟、告警標籤都會出現在信件中

  platform-gitops/apps/ai-agent.yaml
    - agent Deployment 讀取 ENGOPS_UI_URL

  platform-gitops/apps/platform-config.yaml.tmpl
  platform-gitops/apps/platform-config.yaml
  platform-gitops/.github/workflows/render-platform-config.yml
    - 新增 engops-ui-url ConfigMap key 與 ENGOPS_UI_URL repo variable

  platform-gitops/apps/ai-agent-rbac.yaml
    - 新增 monitoring namespace read-only Role / RoleBinding
```

不涉及：

```text
1. platform-ui React 程式碼。
2. platform-backend API contract。
3. CloudFront / S3 基礎設施重建。
4. Kubernetes 寫入權限或自動修復權限擴張。
```

## 架構決策：AI 原始建議與系統最後動作分離

舊版信件只有：

```text
AI 建議動作: notify_only
AI 判斷理由: 服務分級 tier-0,政策上不自動修復
```

這在工程語意上其實是「guard 後的結果」，不是完整的判斷紀錄。新版信件把
兩層拆開：

```text
AI 原始建議: <model_action>
系統最後動作: <action after guard>
AI 原始理由: <model_reason>
系統改判理由: <guard-adjusted reason>
系統保護判斷: <downgraded_by 的中文說明>
```

這樣值班者可以同時知道：

```text
1. 模型原本看到證據後怎麼判斷。
2. 為什麼系統沒有照模型建議自動執行。
3. 人工接手時要尊重哪些安全限制。
```

這也避免 `notify_only` 這個最後動作把所有事故都壓平成同一種文字，讓人
看不出是模型本來就建議通知，還是原本想 restart / rollback 但被 guard 擋下。

## 架構決策：信件新增人工處置步驟，而不是只放 reason

`reason` 是判斷理由，不等於處置 SOP。新版通知信新增 `_human_action_steps()`，
依 alertname 給出人工接手方向。

目前特殊處理：

```text
KubeJobFailed:
  - 指出這是 Kubernetes Job failed，不是 Deployment 故障。
  - 優先查 Job / CronJob / failed Pod / Events。
  - 判斷 BackoffLimitExceeded、ImagePullBackOff、RBAC、資源不足、
    DeadlineExceeded，或舊 failed Job 殘留。
  - kube-prometheus-stack / kube-state-metrics 類告警優先查 monitoring
    namespace 與 Helm/GitOps 設定。

其他告警:
  - 先確認告警是否仍在 firing。
  - 比對 logs/events 是否指向同一問題。
  - 依 AI 原始建議與 Runbook 判斷 restart / rollback / 設定修正 / 平台容量流程。
  - 處置後回事故頁補紀錄，讓後續相似事故可回饋 RAG。
```

信件也會補上 read-only 查詢提示，例如：

```text
kubectl -n monitoring describe job <job>
kubectl -n monitoring get pods -l job-name=<job>
```

這些指令只讀，不會修改叢集。正式修復動作仍需由 owner 依權限與流程執行。

## 架構決策：KubeJobFailed 走 Job 證據收集路徑

舊資料流：

```text
Alertmanager labels
  -> resolve_deployment(service)
  -> fetch_logs(deployment)
       -> read_namespaced_deployment()
       -> list pods by Deployment selector
       -> read pod log
  -> fetch_events(deployment)
       -> read_namespaced_deployment()
       -> list pods by Deployment selector
       -> filter namespace events
```

這對 Deployment / Pod / Service 類告警合理，但對 Job 類告警錯誤。

新版資料流：

```text
alertname == KubeJobFailed
  -> namespace = labels.namespace or TARGET_NAMESPACE
  -> job = labels.job_name or labels.job or resolved service
  -> batch_v1.read_namespaced_job(job, namespace)
  -> core_v1.list_namespaced_pod(namespace, label_selector="job-name=<job>")
  -> read up to 3 pod logs
  -> list namespace events
  -> filter events by Job name / Pod name

其他 alertname
  -> 維持原本 Deployment 證據收集流程
```

這樣 `kps-kube-state-metrics` 這類 monitoring namespace Job 告警，不會再被
錯誤當成 default namespace Deployment 去查。

## 架構決策：只加 read-only RBAC

為了讓 default namespace 的 `ai-agent` 可以讀 monitoring namespace 的 Job
證據，GitOps 新增：

```text
Role:
  namespace: monitoring
  resources:
    pods
    pods/log
    events
    jobs
  verbs:
    get
    list

RoleBinding:
  subject:
    ServiceAccount ai-agent
    namespace default
```

沒有新增任何寫入 verb。這符合 W3 目前的安全邊界：AI Agent 可以收集證據與
提出建議，但不因為要改善通知信而取得跨 namespace 修改權限。

## 架構決策：CloudFront 網址由 ENGOPS_UI_URL 注入

platform-ui 的正式入口是 CloudFront，URL 可能是：

```text
https://<distribution>.cloudfront.net
```

也可能未來換成自訂網域。agent 不應該知道 Terraform state 或 GitHub Actions
變數細節，只讀一個部署環境提供的 URL：

```text
ENGOPS_UI_URL=https://<CloudFront or custom domain>
```

通知信組事故頁：

```text
事故頁面 : ${ENGOPS_UI_URL}/incidents/${incident_id}
```

如果尚未設定：

```text
事故頁面 : 尚未設定 ENGOPS_UI_URL,無法產生網站網址
```

這個失敗模式是刻意設計的：寧可明確告訴操作者設定缺失，也不要寄出假的、
寫死的或無法連線的網址。

## 影響範圍與風險

```text
影響範圍：
  - 新發出的 SNS email 內容。
  - KubeJobFailed 類告警的 evidence collection。
  - ai-agent 對 monitoring namespace 的只讀可見性。
  - 信件中的事故頁 link。

不影響：
  - 已寄出的舊 email。
  - UI build / CloudFront invalidation。
  - backend API schema。
  - 自動修復 guard 政策。
  - Kubernetes 寫入權限。
```

剩餘風險：

```text
1. ENGOPS_UI_URL 若仍是空字串，信件仍不會有可點的事故頁 URL。
2. 真實 KubeJobFailed 的 labels 若沒有 namespace / job_name / job，agent 只能
   fallback 到 service 名稱，仍可能找不到正確 Job。
3. SNS email 是純文字，不適合做 HTML 卡片或表格。這次選擇可掃描的純文字
   區塊，而不是嘗試做無法保證顯示效果的 rich email。
4. 本機測試 mock SNS publish 與 Kubernetes API；真實 end-to-end 還需要下一次
   Alertmanager 告警或手動 webhook 觸發確認。
```

## 新信件預期形態

```text
系統判讀完成但未自動執行修復,原因如下,請確認並決定後續動作。

-- 建議處置 ----------------------------------------
本次沒有自動修復,請 owner 依下方證據與 Runbook 判斷是否要人工處置。
AI 原始建議: notify_only
系統最後動作: notify_only
AI 原始理由: Kubernetes Job failed with BackoffLimitExceeded
系統改判理由: 服務分級 tier-0,政策上不自動修復
系統保護判斷: 此服務的分級政策不允許自動修復,已改為僅通知。

人工處置步驟:
1. 先確認失敗的是 Kubernetes Job `kps-kube-state-metrics`，namespace 是 `monitoring`。
2. 查看 Job 的 Events 與 failed Pod，判斷是 BackoffLimitExceeded、ImagePullBackOff、
   RBAC 權限、資源不足、DeadlineExceeded，還是一次性 Job 的歷史失敗狀態。
3. 如果 Job 仍在反覆失敗，請修正 Job/CronJob template、映像、權限或資源設定後再重跑；
   如果只是舊的 failed Job 殘留，請由 owner 決定是否清理失敗 Job 或等待監控指標消退。
4. 若這是 kube-prometheus-stack/kube-state-metrics 相關 Job，優先檢查 Helm/GitOps
   設定與 monitoring namespace 的 Job/CronJob，不要只查 default namespace 的 Deployment。
注意:本次系統保護機制阻止自動執行；人工處置前請確認這個限制是否仍適用。
讀取型查詢可先用下面兩個方向確認現況:
kubectl -n monitoring describe job kps-kube-state-metrics
kubectl -n monitoring get pods -l job-name=kps-kube-state-metrics

-- 告警標籤 ----------------------------------------
alertname: KubeJobFailed
namespace: monitoring
job_name: kps-kube-state-metrics
service: kps-kube-state-metrics

-- 原始證據(已脫敏摘錄) ------------------------------
原始 logs:
== pod/<job-pod-name> ==
...

Kubernetes Events:
[timestamp] Warning/BackoffLimitExceeded: ...

-- 相關連結 ----------------------------------------
事故頁面 : https://<CloudFront 網址>/incidents/<incident_id>
Runbook  : <service_catalog.runbook_url>
完整日誌 : <service_catalog.log_query_url_template 組出的 URL>
```
