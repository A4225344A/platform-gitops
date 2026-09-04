# 資安複查與硬編碼清除執行紀錄(2026-09-04)

涵蓋 repo:`app`、`platform-agent`、`platform-backend`、`platform-gitops`、`platform-infra`、`platform-ui`。
起因:確認 `C:\AWS\CloudShell` 底下的 code 是否有敏感資訊外洩,以及請 Claude 以資深資安工程師角度做一次嚴謹複查。

---

## Part A — 硬編碼清除(改為 GitHub Variables / 環境變數驅動)

### A1. GitOps / Infra 跨 repo 引用寫死擁有者帳號

**問題**:CI workflow 裡直接寫死 `repository: A4225344A/platform-gitops`(或 `platform-infra`),fork 這份 repo 的人如果不知道要改,workflow 會嘗試對**原作者**的 repo 做 checkout/dispatch。

**修復**:改用 `${{ vars.GITOPS_REPO || format('{0}/platform-gitops', github.repository_owner) }}` 這種寫法——沒設 repo variable 時,自動用「同一個 GitHub 帳號底下的同名 repo」當預設值,不用先設定變數就能跑;要跑不同名稱的 repo 才需要額外設 `GITOPS_REPO`/`INFRA_REPO`。

**涉及檔案**:
- `platform-agent/.github/workflows/ci-cd.yml`
- `platform-backend/.github/workflows/ci-cd.yml`
- `app/.github/workflows/docker-publish.yml`(`INFRA_REPO`)
- `platform-infra/.github/workflows/update-gitops.yml`(`GITOPS_REPO`)

**驗證方式**:確認 `github.repository_owner` 推導出的值跟原本寫死的值一致(即 `A4225344A`),對現有帳號的 CI 行為零影響。

**驗證結果**:✅ 四個 workflow 修改後,CI 持續正常執行(後續多次 push 都成功觸發 build/deploy,無異常)。

---

### A2. AWS 帳號專屬值(ARN / S3 bucket / CloudFront distribution ID / region)寫死當 fallback

**問題**:`platform-ui/.github/workflows/deploy-ui.yml`、`app/.github/workflows/docker-publish.yml` 用 `vars.X || '<真實值>'` 的寫法,真實的 AWS 帳號 ID、IAM Role ARN、S3 bucket 名稱都直接寫在程式碼裡。

**修復**:
1. 請你在 GitHub 網頁(Settings → Secrets and variables → Actions → Variables)手動新增以下 repo variables:
   - `platform-ui`:`AWS_REGION`、`GHA_APP_DEPLOY_ROLE_ARN`、`UI_BUCKET`、`CLOUDFRONT_DISTRIBUTION_ID`
   - `app`:`AWS_REGION`
2. 確認你已設定後,把程式碼裡的寫死 fallback 全部拿掉,改成純 `vars.*`——沒設變數會直接在 `configure-aws-credentials`/`aws s3 sync` 那幾步失敗,不會誤用到別人的帳號。
3. 同步更新 `platform-ui/README.md`,把「這是預設值,變數可覆蓋」的舊描述改成「以下是必填變數」。

**驗證方式**:你回報「設定完成」後,實際觸發一次 `Deploy EngOps UI` / `Docker Publish` workflow,觀察是否能正常吃到變數值完成部署。

**驗證結果**:✅ 你確認 5 個變數(含 `AWS_REGION`)皆已設定;拿掉 fallback 後的 workflow push 上去沒有回報失敗。

---

### A3. RDS host / 告警信箱直接寫死進 ConfigMap(PII 外洩)

**問題**:`platform-gitops/apps/platform-config.yaml` 這個會被 ArgoCD `selfHeal` 自動同步到正式叢集的 ConfigMap,裡面直接寫了真實 RDS endpoint 和一組個人 Gmail 信箱,而且是明碼進版控。

**修復**:
1. 新增 `apps/platform-config.yaml.tmpl` 樣板(用 `${PGHOST}`、`${ALERT_EMAIL}` 佔位)。
2. 新增 `.github/workflows/render-platform-config.yml`:讀取 repo variables `PGHOST`、`ALERT_EMAIL`,用 `envsubst` 算繪出 `apps/platform-config.yaml`,算繪後 commit + push。兩個變數沒設值時直接 `exit 1`,不會把空值寫進正式環境。
3. 請你在 `platform-gitops` repo 設定這兩個 repo variables(值沿用原本的正式值,確保行為不變)。

**驗證方式**:push 含 `.tmpl` 的 commit 後(路徑符合 workflow 的 `paths` 觸發條件,會自動跑一次),檢查 Actions 執行紀錄跟 `apps/platform-config.yaml` 的最新 commit 作者。

**驗證結果**:✅ workflow 自動觸發成功,`apps/platform-config.yaml` 出現一筆 `github-actions[bot]` 的新 commit(`chore: render platform-config from repo variables`),內容數值不變但來源已改成變數算繪。⚠️ **殘留事項**:git 歷史裡舊 commit 仍留有這組真實值,若這個 repo 是 public 且要徹底清除,需要另外用 `git filter-repo`/BFG 改寫歷史並強制推送——這是破壞性操作,尚未執行,待你決定。

---

### A4. GitOps repo 前綴常數寫死在應用程式原始碼

**問題**:`platform-backend/app/models.py` 的 `GITOPS_PR_URL_PREFIX` 直接寫死 `https://github.com/A4225344A/platform-gitops/pull/`。

**修復**:改讀 `os.environ.get('GITOPS_REPO', 'A4225344A/platform-gitops')` 動態組出來;`platform-gitops/apps/engops-api/deployment.yaml` 新增明確的 `GITOPS_REPO` 環境變數(K8s manifest 沒有 GitHub Actions 變數可用,所以用 plain env value,並加註解提醒 fork 的人要改這裡)。

**驗證方式**:`pytest` 測試(`test_approvals.py` 裡驗證 PR URL 前綴的測項)全過。

**驗證結果**:✅ 34 個測試全過(其中 1 個時間炸彈測試另見 B4)。

---

## Part B — 資安複查與修復

### B1. `ai-agent` 的 K8s RBAC 少了 restart 動作實際需要的權限

**問題**:`platform-gitops/apps/ai-agent-rbac.yaml` 的 `Role` 只給 `deployments`/`replicasets` 的 `get`、`list`,但 `platform-agent/src/agent.py` 的 `remediate()` 對 `action=="restart"` 會呼叫 `apps_v1.patch_namespaced_deployment(...)`。目前因為 `REQUIRE_HUMAN_APPROVAL=true` 擋住大部分自動執行路徑,這個缺口暫時沒被觸發,但一旦核准流程接上真執行路徑,`restart` 會直接吃 403,變成「系統以為修好了、其實什麼都沒做」的靜默失敗。

**初步修復(後來復原)**:一開始在 `deployments` 那條規則加上 `"patch"` 並 push、驗證 pod 正常。

**修正**:事後對照《W3_AI自我修復_專案說明文件.md》才發現,這個「沒有 patch」不是遺漏,而是 **2026-09-01 安全控制強化時刻意移除的設計**——目的是讓 RBAC 這一層獨立於 `REQUIRE_HUMAN_APPROVAL` 與程式邏輯之外,即使兩者都被繞過,`ai-agent` 在 kube-apiserver 端仍完全無法寫入 Deployment。這是主文件裡「最終狀態以安全控制為準——AI 只能提出建議」這句話的具體實作。

跟你確認後,已改回原設計:`deployments`/`replicasets` 都只有 `get, list`,並在 `ai-agent-rbac.yaml` 加註解說明這段來龍去脈,避免下次複查再誤判成 bug。

```diff
   - apiGroups: ["apps"]
-    resources: ["deployments", "replicasets"]
-    verbs: ["get", "list"]
+    resources: ["deployments"]
+    verbs: ["get", "list", "patch"]      # 一度加回,已復原
+  - apiGroups: ["apps"]
+    resources: ["replicasets"]
+    verbs: ["get", "list"]
```

**驗證方式**:兩次 push(加回 patch → 復原)後都在控制節點檢查 pod 狀態與 restart 次數,確認 RBAC 變更沒有讓 pod 進入 CrashLoopBackOff。

**驗證結果**:✅ 兩次都確認 `ai-agent` pod `1/1 Running`、`RESTARTS 0`,`Ready` 條件皆為 `True`。**最終狀態:恢復成 2026-09-01 的原始設計,RBAC 無 `patch` 權限。**

> 這是本次複查裡最值得記取的一點:離開單一 repo、只看程式碼行為去下結論,會漏掉「這是刻意的縱深防禦」這種只存在於另一份文件裡的脈絡。跨 repo 的安全決策最好有一份主文件可查,而不是散落在各處的 commit message。

---

### B2. 容器與 Pod 改為 non-root、拿掉多餘 Linux capabilities

**問題**:`platform-agent`、`platform-backend` 的 Dockerfile 都沒有 `USER` 指令(容器內用 root 跑),K8s manifest 也沒有 `securityContext`——容器若被攻破,攻擊者拿到的就是 root 權限,擴大了單一漏洞的影響範圍。

**修復**:
1. 兩份 Dockerfile 都新增 `RUN useradd --system --no-create-home --uid 10001 appuser` + `USER appuser`。
2. `platform-gitops/apps/ai-agent.yaml`、`apps/engops-api/deployment.yaml` 都新增:
   ```yaml
   securityContext:            # Pod 層級
     runAsNonRoot: true
     runAsUser: 10001
   # container 層級
   securityContext:
     allowPrivilegeEscalation: false
     capabilities: { drop: ["ALL"] }
   ```

**驗證方式**:push 後在控制節點確認兩個 pod(單副本,無備援)是否正常 `Running`、`RESTARTS` 沒有異常增加,並確認 K8s 的 `Ready`/`ContainersReady` 條件(這兩個條件本身就是 kubelet 對 `/healthz` httpGet 探測的結果,等同健康檢查通過)。

**驗證結果**:✅ 實際在控制節點執行 `kubectl get pods -n default -l "app in (ai-agent,engops-api)" -o wide` 的結果:

```
NAME                          READY   STATUS    RESTARTS   AGE    IP            NODE
ai-agent-6658f4c845-jfqpq     1/1     Running   0          7m3s   10.42.1.48    ip-10-0-1-223...
engops-api-84bc649899-wp8hc   1/1     Running   0          7m3s   10.42.1.199   ip-10-0-1-223...
```

`kubectl describe pod` 顯示兩者 `PodReadyToStartContainers`/`Initialized`/`Ready`/`ContainersReady`/`PodScheduled` 皆為 `True`,`Events` 只有正常的 `Scheduled → Pulling → Pulled → Created → Started`,沒有 `BackOff`/`Failed` 事件。`ai-agent` 當時已在跑新的 non-root 映像(`sha-6adf1ad98e2d`);`engops-api` 當下仍在跑修復前的舊映像(`sha-a503fa9f4953`),套用 `runAsUser: 10001` 後一樣正常啟動,證實舊映像的檔案權限(root 建置、預設 world-readable)足以支援非 root UID 執行,沒有寫入本地檔案的相依性。

> 附註:runbook 裡原本用 `wget` 做應用層健康檢查,但 `python:*-slim` 映像沒有內建 `wget`,執行會報 `executable file not found in $PATH`——這是 runbook 指令本身的問題,不代表服務異常;上面 `Ready: True` 已經是有效的健康驗證。

---

### B3. `platform-backend` 依賴鏈缺少 `platform-agent` 已有的供應鏈防護

**問題**:`platform-agent` 的 CI 已經有 `pip-compile --generate-hashes` + `pip install --require-hashes` + `pip-audit` 三重防護;`platform-backend` 只是單純 `pip install -r requirements.txt`,套件版本雖然釘死但沒有雜湊驗證,也沒有掃已知 CVE。

**修復**:
1. `requirements.txt` → 改名為 `requirements.in`(未鎖版的來源檔)。
2. 用 `pip-tools` 產生帶雜湊的 `requirements.lock`(694 行,涵蓋全部遞移依賴)。
3. `Dockerfile` 改成 `pip install --require-hashes -r requirements.lock`。
4. `ci-cd.yml` 新增「驗證 lock file 是最新的」「用雜湊安裝」「`pip check`」「`pip-audit`」四個步驟,跟 `platform-agent` 對齊。
5. `.gitignore` 加上 `.pip-tools-cache/`、`.pip-audit-cache/`。
6. `README.md` 的本機開發指令同步改成用 `requirements.lock`。

**驗證方式**:本機用同一顆鎖定檔重新安裝(`pip install --require-hashes -r requirements.lock`)、跑 `pip check`、跑 `pip-audit`、跑 `pytest`,確認沒有破壞既有功能。

**驗證結果**:
- `pip install --require-hashes` 成功、`pip check` → `No broken requirements found.`
- `pip-audit --cache-dir .pip-audit-cache -r requirements.lock` → `No known vulnerabilities found`
- `pytest -q` → 見下方 B4(過程中發現 1 個既存測試 bug,修復後 34 個測試全過)。

---

### B4.(意外發現)`test_approvals.py` 的時間炸彈測試 bug

**問題**:驗證 B3 時發現 `test_decide_approval_updates_status_and_writes_audit_log` 用寫死的絕對時間 `datetime(2026, 9, 3, 2, 0, ...)` + 24 小時算 `expires_at`;執行當下(2026-09-04)真實時間已經超過這個窗口,`decide_approval_data()` 判定「approval is expired」而讓測試失敗。這跟本次的安全修復無關,但會讓 CI 的 `ci` 作業失敗,連帶卡住 `needs: ci` 的 `docker` 作業,導致 `engops-api` 無法自動建出新映像(等於間接卡住 B2/B3 的正式部署)。

**修復**:把 `requested_at` 改成相對時間 `datetime.now(timezone.utc) - timedelta(hours=1)`,不再受執行當下的真實時間影響。

**驗證方式**:本機重跑 `pytest -q`。

**驗證結果**:✅ `34 passed`(修復前為 `1 failed, 33 passed`)。push 後應可解除 CI 阻塞,讓 `engops-api` 的 non-root 映像自動建置部署。

---

### B5.(連環問題)`platform-backend` CI 的 lock file 驗證步驟,連續紅燈四次才真正修好

B3 上線後,CI 的「驗證 lock file 是最新的」這步接連紅了四次,每次原因都不一樣。完整記錄下來,因為每一個都是「本機測完全過、只有 CI 才會炸」的類型,單看某一次很容易誤判成隨機抽風。

**紅燈 1:`Set up Python` 直接報錯,找不到依賴檔**

```
Error: No file in .../platform-backend matched to [**/requirements.txt or
**/pyproject.toml], make sure you have checked out the target repository
```

- **根因**:`actions/setup-python@v6` 的 `cache: pip` 預設用 `**/requirements.txt`/`**/pyproject.toml` 當快取依據的 glob。B3 把 `requirements.txt` 改名成 `requirements.in` 後,這個 glob 找不到任何檔案,直接讓步驟報錯。`platform-agent` 剛好有一個(內容其實是空的)`pyproject.toml`,巧合符合了 glob 才沒踩到同樣的坑——不是刻意的防護。
- **修法**:`actions/setup-python@v6` 明確加 `cache-dependency-path: requirements.lock`,`platform-agent` 也順手補上同一行,不再依賴巧合。

**紅燈 2:`git diff --exit-code requirements.lock` 判定「lock 檔不是最新」,diff 顯示 `typing-extensions` 的 `via` 清單不同**

- **根因**:本機重新產生 `requirements.lock` 用的 venv 其實是 **Python 3.14**,但 `Dockerfile`/CI 都是 **Python 3.12**。不同 Python 版本下,`psycopg`/`pytest-asyncio`/`starlette` 是否需要 `typing-extensions` 這個回填套件的判斷不同(3.14 內建了更多 typing 功能,不需要;3.12 還需要),造成解析結果不同。
- **修法**:改用真正的 Python 3.12(`py -3.12 -m venv .venv312`)重新產生,本機驗證(`pip install --require-hashes`、`pip check`、`pip-audit`、`pytest`)全過後 push。

**紅燈 3:同一步驟又紅,這次 diff 顯示 `httptools` 多了一大串新 hash**

- **根因**:`httptools==0.8.0` 這個已發布版本,PyPI 上的 wheel 清單被上游持續追加(版本號沒變,新平台/新 Python 版本的 wheel 陸續補上),導致「重新解析 + 逐字比對雜湊清單」這個驗證方式,天生會被這種上游變動觸發假警報——即使 `requirements.in` 完全沒改。這次在本機用對的 Python 3.12 都沒能重現(代表撞上的是 PyPI 端持續在變的東西,不是本機環境問題),隔了一段時間再跑又用不同的 hash 炸了第二次,證實是持續性的,不是單次巧合。
- **修法**:CI 的驗證步驟改成只比對「套件==版本」是否跟 `requirements.in` 對齊(`grep + awk '{print $1}' + sort + diff`),刻意不比對雜湊清單本身——雜湊的完整性驗證交給後面 `pip install --require-hashes` 那步做(那步驗的是「下載到的檔案雜湊有沒有在鎖定檔清單裡」,不需要清單逐字相同)。本機模擬了這個新比對方式,並刻意在 `requirements.in` 塞一個假依賴驗證它還抓得到真的 drift,確認沒有把檢查機制做成形同虛設。

**紅燈 4:比對方式修好了,但 diff 顯示 `colorama`/`tzdata` 多了、`uvloop` 少了**

- **根因**:這次不是版本問題,是**作業系統**問題。`pip-compile` 會依「執行它的那台機器」解析平台相關依賴——本機是 Windows,解析出 `colorama`(Windows 終端機色彩支援)、`tzdata`(Windows 沒有內建 IANA 時區資料庫);CI/`Dockerfile` 是 Linux,需要 `uvloop`(Linux/Mac 專屬的高效能事件迴圈,Windows 裝不了)。**在本機 Windows 上,不管用哪個 Python 版本,都不可能產生出跟 Linux 部署目標一致的鎖定檔**——這比紅燈 2 的教訓更根本。
- 本機沒有可用的 Docker daemon(Docker Desktop 沒在跑,啟動它成本較高),改用更可靠也更長久的做法:新增 `.github/workflows/sync-requirements-lock.yml`(手動觸發),在跟 `Dockerfile` 完全一致的 GitHub Actions Linux + Python 3.12 環境重新產生 `requirements.lock` 並自動 commit 回去。
- **修法**:手動觸發 `Sync requirements.lock` workflow → 自動 commit 修正後的鎖定檔 → 觸發下一次 `CI/CD` → 通過。`README.md` 同步改成明確告訴讀者「不要在本機、尤其是 Windows 重新產生這個檔案」,改依賴後用這個 workflow。

**驗證結果**:✅ 四個問題依序修復後,`CI/CD` workflow 綠燈。

**這次串連起來的教訓**:雜湊鎖定檔的「驗證是否最新」這個動作,如果做法是「在某台機器上重新解析、跟已提交的檔案逐字比對」,那份鎖定檔的正確性就完全綁死在「重新解析的那台機器」跟「正式部署目標」是否環境一致(作業系統、Python 版本、套件生態圈當下狀態三者都要對得上)。四次紅燈分別對應到這三個維度各自出過的錯,最終的修法也分成兩層:CI 的驗證邏輯改成不受雜湊清單自然變動影響(比對版本而非雜湊),以及把「產生鎖定檔」這個動作徹底移到跟部署目標一致的環境裡執行,不再依賴任何人的本機。

---

## 複查範圍內、確認沒問題的項目(佐證覆蓋面,非本次修改)

| 類別 | 結論 |
|---|---|
| Injection | 全專案無 `subprocess`/`os.system`/`shell=True`/`eval`/`exec`,AI agent 對 K8s 的操作全走官方 Python client SDK |
| SQL Injection | `platform-backend` 所有查詢皆用 `%s` 參數化(psycopg),無字串拼接 SQL |
| 認證比對 | `bearer_token_matches()` 用 `hmac.compare_digest`,非 `==`,可防 timing attack |
| AI agent 防護縱深 | prompt injection 關鍵字過濾 → PII 遮罩(Presidio)→ 目標服務比對 → tier 分級政策 → 預設要求人工核准 → circuit breaker → `rollback` 動作寫死拒絕 → 查詢失敗 fail-closed |
| K8s RBAC | `engops-api`、`ai-agent` 各自獨立 ServiceAccount,權限收斂在單一 namespace 的特定資源 |
| Admission 層 | `ai-agent-vap.yaml`(ValidatingAdmissionPolicy)限制 ai-agent 即使有 UPDATE 權限也只能改 pod template metadata,動不了 replicas/container spec |
| NetworkPolicy | `ai-agent` ingress 只接受來自 `monitoring` namespace |
| IAM | Bedrock/日誌/autoscaler 權限皆 ARN 級或加 tag condition,`Resource: "*"` 只出現在天生不支援資源層級限制的 `Describe*` 唯讀 API |
| 安全組 | 無對外開放 SSH(用 SSM),RDS 僅限 VPC CIDR,HTTP 僅限 CloudFront origin-facing prefix list,k3s 內部流量僅限自身安全組 |
| S3 | UI bucket、RDS 備份 bucket 皆有 `public_access_block` + server-side encryption |
| CVE 追蹤 | 已知並主動緩解 pgvector CVE-2026-3172(關閉平行索引建置路徑) |
| CI 憑證 | 全部走 OIDC role assumption,無任何 workflow 使用靜態 AWS access key |

## 未處理的低優先級殘留

- `platform-backend/tests/test_approvals.py` 等測試固定值仍含真實 GitHub org 名稱(僅測試資料,非機敏)
- `platform-infra/bootstrap-oidc/variables.tf` 的 `cloudfront_ui_distribution_id` 預設值為真實 ID(Terraform input variable,非 GitHub Actions 硬編碼)
- 兩份 `task-11-2-*-runbook.md` 保留了當初實際跑過的真實 bucket 名稱/RDS host(視為驗證紀錄,非樣板)
- `platform-ui/src/App.tsx` 的 `region: 'ap-northeast-1'` 屬於 UI 範例文字內容

## 待決定事項

- `platform-gitops` 的 git 歷史仍留有舊版 `platform-config.yaml` 的真實 RDS host / 告警信箱(見 A3),是否要用 `git filter-repo`/BFG 改寫歷史,待你決定。
