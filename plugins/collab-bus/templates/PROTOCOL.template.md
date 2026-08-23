# {{PROJECT}} ⇄ {{PEER}} 協作協定 (collab-bus PROTOCOL)

兩個 AI CLI（Claude Code + {{PEER}}）共享這個 repo。**訊息內容 + 審計軌跡**走檔案
（`collab/inbox/`）；**傳輸與「對方跑完沒」**走 **herdr**（Claude 用 `agent prompt
--wait` 提交並等對方那一輪結束，靠語義狀態,不輪詢、不 send-keys）。
這份檔是雙方唯一的共同約定，衝突時以此為準。

## 角色分工

- **Claude Code = orchestrator**：規劃、拆任務、實作、開 branch；把要 review / 第二意見的東西寫成訊息丟給 {{PEER}}。
- **{{PEER}} = reviewer / 糾錯 / 獨立第二意見**：讀訊息與 diff，review、抓 bug、挑架構；**不直接改預設分支**，修改建議寫成訊息回丟。

> 分工可由人類隨時翻轉；翻轉時更新本節。

## 目錄結構

```
collab/
├── PROTOCOL.md              # 本檔（唯一事實來源）
├── inbox/
│   ├── to/{{PEER}}/         # 給 {{PEER}} 的訊息（Claude 寫 → {{PEER}} 讀）
│   ├── to/claude/           # 給 Claude 的訊息（{{PEER}} 寫 → Claude 讀）
│   └── archive/             # 處理完的訊息搬來這（保留歷史）
├── reviews/                 # review 記錄與成果 md（長期存檔）
└── tasks/                   # 進行中任務追蹤（一任務一檔）
```

## 訊息格式

一則訊息 = `inbox/to/<recipient>/` 下一個 markdown 檔。
**檔名**：`NNNN-<tab>-<slug>.md`，例：`0034-w3t3-review-auth.md`。

> **編號必須用 `${CLAUDE_PLUGIN_ROOT}/scripts/next-id.sh` 原子性配號。**
>
> 「下一個 id = 現有最大 NNNN + 1」是 read-then-write，**兩個 session 同時算就會撞號**
> （實際發生過：同一個收件匣出現兩則 `0033`）。
>
> ```bash
> DEST=$("${CLAUDE_PLUGIN_ROOT}/scripts/next-id.sh" {{PEER}} review-my-topic w3:t3)
> # 然後把內容寫進 $DEST
> ```
>
> 它用 `mkdir` 當互斥鎖（POSIX 原子操作），在鎖內算號並以 **exclusive create** 佔位再放鎖。
> 鎖內記錄 owner token（`host:pid:rand`），**只有持鎖者本人能釋放**；逾時等待者絕不碰別人的鎖。
>
> **v0.3.2 起沒有自動 stale 接管**：鎖卡住會明確報錯並列出持有者（含該 PID 是否還活著），
> 由人判斷後手動清除。原因是 portable shell 對固定路徑做不到 compare-and-rename，
> 任何「檢查後再 rename」都有換代競態，可能移走別人正持有的鎖；
> `mkdir` 成功到寫入 token 之間也有一段無主視窗。要自動恢復必須改用 process 死亡即釋放的
> OS 鎖（flock/fcntl），或不重用同一路徑的 ticket 設計。
>
> **防覆寫的責任分工**：同機競態由 exclusive create（`noclobber`）擋；
> 檔名帶 tab **只增加可追溯性**，不是第二把鎖。
>
> ⚠️ **保證範圍：同一台機器、同一個本地目錄 view 的並行 process。**
> `mkdir` 的原子性只存在於單一 filesystem namespace。放在 Dropbox／iCloud／Drive 這類
> **同步資料夾時，兩台機器各自都能在自己的本地 view 建立 `.idlock`、讀到相同 MAX、
> 配出相同編號**——同步層之後只會產生 conflicted copy，不會幫你解決競爭。
> 需要跨機器單調編號請改用中央 allocator；不需要單調序號則改用 UUID/ULID。
> 編號到 `9999` 會明確失敗，不會靜默重用。

```markdown
---
id: 0001
pair: w3:t3             # 必填：發訊方的 herdr tab_id（多組並存時用來路由，見下）
from: claude            # claude | {{PEER}}
to: {{PEER}}            # {{PEER}} | claude
type: review-request    # review-request | review-result | task | reply | question | ack
subject: <一句話標題>
refs:                   # 可選：branch / commit / 檔案 / reply_to: <前一則 id>
status: open            # open | done
---

<正文：要對方做什麼、脈絡、驗收條件。一則只講一件事。>
```

## 收發流程（一輪）

1. **寫**：發訊方在 `inbox/to/<對方>/` 建 `NNNN-*.md`，`status: open`。
2. **敲門（送+等，原子）**：發訊方跑 plugin 的 `knock.sh <對方> "<一句話>"`
   → herdr `agent prompt --wait` 提交 nudge 並阻塞到對方那一輪 settle，回傳 `agent_status`。
3. **讀 + 做**：對方 settle 後（idle/done）讀最新 `open` 訊息、執行；`blocked` 就喊人類。
4. **回覆**：收訊方在 `inbox/to/<發訊方>/` 建新 `NNNN-*.md`（`reply_to` 指回原 id），
   把**原訊息**搬到 `inbox/archive/`，換手敲門回去。

## 硬規則（避免互相踩）

- **不同時改同一檔程式碼**。慣例：Claude 寫 code（開 branch），{{PEER}} 只讀 diff + 寫意見。
- **git branch 是第二層匯流排**：Claude commit 到 feature branch，{{PEER}} `git diff` review。
- **不碰預設分支**：實作走 branch，人類決定何時 merge。
- 一則訊息只講一件事；大任務拆多則。
- 訊息處理完一定要搬 `archive/`，`inbox/to/*` 只留 `open` 的，避免重複執行。
- 專案自己的 `CLAUDE.md` / `AGENTS.md` 等規範仍然適用，且優先於本協定的一般性建議。

## 多組 Claude+{{PEER}} 並存時（重要）

工作區可能同時開著好幾組（一個 tab 一組）。這帶來兩個獨立問題：

**問題一：編號會撞。** 解法見上面的 `next-id.sh` 原子配號。

**問題二：收件匣是共用的，訊息沒有真正的收件人。**
`inbox/to/{{PEER}}/` 只說「給 {{PEER}}」，沒說給**哪一個**。兩組的 peer 都會讀到同一個目錄。

> ⚠️ **`pair` 是「防誤處理」，不是存取控制。** 共用工作區裡任何 agent 都能讀寫所有 inbox，
> 所以它擋不住惡意或有 bug 的一方，只能避免兩組互相誤觸。要真正隔離需要改成
> `inbox/pairs/<pair-id>/to/<agent>/` 的目錄結構。

→ 每則訊息的 frontmatter 必須帶 `pair`（發訊方的 `tab_id`）；
   收訊方**只處理 `pair` 等於自己 tab_id 的訊息**，其餘不動也不歸檔（那是別組的）。
   敲門的 nudge 要明講檔名，不要只說「看收件匣」。
   `inbox/to/*` 可能同時留著別組的 `open` 訊息，這是正常的。

## herdr 座標（動態解析，不可寫死）

> **不要把 pane_id 寫死在這份檔案裡。** 工作區一旦出現第二組 Claude+{{PEER}}，
> 靜態座標就會敲到別人那一組——這確實發生過，打斷了另一組正在跑的工作。
> 每次敲門前重新解析。

**規則：peer = 與自己同一個 `tab_id` 的對方 agent**（不是 pane 編號、也不是名稱）。

```bash
# 1. 我是誰：agent_session.value == 自己的 session id
#    （Claude Code 的 session id = scratchpad 路徑的最後一層目錄名）
herdr agent list | jq -r --arg me "<my-session-id>" '.result.agents[]
  | select(.agent=="claude" and .agent_session.value==$me)
  | "ME   pane=\(.pane_id) tab=\(.tab_id)"'

# 2. 我的 peer：tab_id 與上面相同、agent 為對方的那一筆
herdr agent list | jq -r --arg tab "<上一步的 tab>" '.result.agents[]
  | select(.agent=="{{PEER}}" and .tab_id==$tab)
  | "PEER pane=\(.pane_id) status=\(.agent_status)"'
```

> 不要用 `focused==true` 找自己——終端焦點在別處時會直接失效。

**{{PEER}}（Codex 等）那一側怎麼識別自己**：herdr 會把 caller context 放進環境變數，
優先用它，不要猜 pane、不要用 focus：

```bash
test "${HERDR_ENV:-}" = 1 || exit 1
herdr agent get "$HERDR_PANE_ID"      # 驗證 pane_id / tab_id / agent 相符
```

沒有 herdr caller 變數時的 fallback：用 CLI 自己的 session id
（Codex 是 `CODEX_SESSION_ID`，實測等於 herdr 的 `agent_session.value`）
在 `herdr agent list` 找**恰好一筆**相符的紀錄；0 筆或多筆就停下來問人。

**敲門前一定要把「我是誰 → 要敲誰」印出來讓人類可核對。**
同 tab 找不到對方時**停下來問人**，不要退回去用任何寫死的 pane_id。

- Claude 敲門：`knock.sh <peer_pane_id> "..."`（用解析出的 pane_id；
  `knock.sh {{PEER}}` 這種名稱解析在有兩個以上同類 agent 時會拒絕，那是警訊不是故障）
- {{PEER}} 敲門回 Claude：`herdr agent prompt <claude_pane_id> "..." --wait`（同樣同 tab 解析）
- 查狀態：`herdr agent get <pane_id>`／讀輸出：`herdr agent read <pane_id>`
- **一律用 `prompt` 不用 `send-keys`**（send-keys 繞過狀態追蹤）。

**誤敲別組時**：立刻停止該輪、不要重試，並告知人類敲到了哪個 pane——
對方那組可能正在跑別的任務。
