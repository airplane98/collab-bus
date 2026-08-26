# {{PROJECT}} ⇄ {{PEER}} 協作協定 (collab-bus PROTOCOL)

> 由 collab-bus **{{VERSION}}** 的範本產生。`collab/bin/` 的腳本也是同一版 vendored 過來的。
> 升級 collab-bus 後**重跑 bootstrap 只會更新 `collab/bin/`,不會覆寫本檔**——本檔請
> 就地修補(它可能帶有專案自訂內容),並更新這行版本。

兩個 AI CLI（Claude Code + {{PEER}}）共享這個 repo。**訊息內容 + 審計軌跡**走檔案
（`collab/inbox/`）；**傳輸與「對方跑完沒」**走 **herdr**——**雙方敲門都用
`collab/bin/knock.sh`**（先 `agent wait` 把對方進行中的一輪等完，再 `agent prompt
--wait` 提交並等 settle；靠語義狀態，不輪詢、不 send-keys）。
這份檔是雙方唯一的共同約定，衝突時以此為準。

## 角色分工

**這是常見分工,不是機制限制——任一方都可以發起。**

- **Claude Code = orchestrator**（常見情形）：規劃、拆任務、實作、開 branch；把要 review / 第二意見的東西寫成訊息丟給 {{PEER}}。
- **{{PEER}} = reviewer / 糾錯 / 獨立第二意見**（常見情形）：讀訊息與 diff，review、抓 bug、挑架構；**不直接改預設分支**，修改建議寫成訊息回丟。

> **角色可兌換。** 傳輸與訊息格式完全對稱:`from`/`to` 是欄位、敲門雙向、雙方呼叫
> 同一份 `collab/bin/`。所以 {{PEER}} 也可以當**發起方**,請 Claude review 它的東西:
>
> ```bash
> # {{PEER}} 發起（方向與上面的範例相反,流程一模一樣）
> DRAFT=$(collab/bin/next-id.sh claude my-proposal w3:t3)
> #   …寫入 frontmatter: from: {{PEER}} / to: claude / type: review-request / pair: w3:t3…
> DEST=$(collab/bin/publish.sh "$DRAFT")
> collab/bin/knock.sh <claude_pane_id> "process $DEST"
> ```
>
> ⚠️ 但**別在對方正同步等你 settle 時用同步 knock 回敲**——那會死鎖,見下面
> 「非同步敲門」節。人類也可隨時指定分工；固定翻轉時更新本節。

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
**檔名**：`<ULID>-<tab>-<slug>.md`，例：`01M0WG3WJF6AX39B2RGCPVN2CM-w3t3-review-auth.md`。

> **編號必須用 `collab/bin/next-id.sh` 產生**（雙方共用同一入口）。**絕不要自己
> 手算 id**，尤其不要「現有最大 + 1」——那是 read-then-write 競態，兩個 session
> 同時算就撞號（v0.4 之前實際發生過：同一收件匣出現兩則 `0033`）。
>
> ```bash
> # 雙方都用專案內的同一個入口（peer CLI 沒有 CLAUDE_PLUGIN_ROOT）
> DRAFT=$(collab/bin/next-id.sh {{PEER}} review-my-topic w3:t3)   # 回傳 .md.part 草稿
> # …把完整內容寫進 $DRAFT…
> DEST=$(collab/bin/publish.sh "$DRAFT")   # 原子 no-replace link 成最終 .md
> ```
>
> **v0.6：先寫草稿，再 publish（原子上架）。** `next-id.sh` 回傳的是**草稿**路徑
> （`.<ULID>-…md.part`，點開頭、`.part` 結尾，收件匣掃描看不到），不是最終訊息。
> 寫完內容後用 `publish.sh` 上架成 `<ULID>-…md`:它用 **exact two-path 的 `link`
> utility 做原子 no-replace hard link**(**不是** `ln`——`ln SOURCE DIR` 會把檔案連進
> 目錄裡;也不是 rename,因為沒有可攜的 no-replace rename),連成功後才 unlink 草稿。
> 目的地已存在(檔案／目錄／symlink,含 dangling)時 `link()` 以 EEXIST **原子失敗**,
> 所以既有訊息永遠不會被覆寫。**最終 .md 只透過這一步出現**,所以收訊方永遠不會讀到
> 「已佔號但還沒填內容」的空訊息（本專案實際
> 踩過空回覆檔）。`publish.sh` 會拒絕空草稿，別在寫內容前就 publish。
> **v0.5 起 id 是 ULID**（48-bit 毫秒時間戳 + 80 隨機位元，Crockford base32，
> 26 字元），**不再是共享計數器，因此沒有鎖**。ULID 不需要任何協調就唯一：兩個
> agent——甚至同步資料夾後的兩台機器——各自獨立產生，撞號機率可忽略（每毫秒 80
> 隨機位元），因為沒有共享可變狀態可爭。v0.2–v0.4.1 為了那個計數器建的整套
> mkdir 互斥鎖、owner token、鬼鎖復原、
> `/tmp` 鎖路徑導出全部**已刪除**。時間戳是高位前綴，所以檔名仍照時間排序；tab 與
> slug 仍在後面，人類照樣讀得懂。
>
> **兩層防覆寫**：`next-id.sh` 用 exclusive create（`noclobber`）建**草稿**;
> `publish.sh` 則用上面說的 no-replace `link` 保護**最終檔名**。ULID 撞號機率是天文級
> 小，但這兩層都零成本，也順手擋掉同步而來的同名檔。
>
> ⚠️ **跨機器仍非嚴格單調。** ULID 保證唯一，但兩台機器時鐘不完全同步時，時間
> 排序只精確到毫秒級；若某流程需要跨機器**嚴格單調**序號，ULID（和舊計數器一樣）
> 都不提供，得用中央 allocator。日常協作用不到這個。

```markdown
---
id: 01M0WG3WJF6AX39B2RGCPVN2CM   # next-id.sh 產生的 ULID（就是檔名前綴）
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

1. **寫 + 上架**：發訊方 `next-id.sh` 取草稿路徑 → 把完整內容（含 `status: open`）
   寫進草稿 → `publish.sh` 原子上架成最終 `.md`（見上「先寫草稿，再 publish」）。
2. **敲門（先等，再送+等）**：先依「herdr 座標」那節**動態解析出對方的 pane_id**，
   再跑 `collab/bin/knock.sh <對方_pane_id> "<一句話，並指名檔案路徑>"`（雙方共用
   這一個入口，方向相反也一樣）。
   knock 會先用 `herdr agent wait` **把對方進行中的那一輪等完**再提交——
   herdr 明文說 `prompt --wait` 不追蹤 turn：對方還在 `working` 時直接提交，
   等到的可能是**上一輪**的結束，你會去讀一個還不存在的回覆檔。
   之後才是 `agent prompt --wait` 提交 nudge 並阻塞到對方那一輪 settle，回傳 `agent_status`。
3. **讀 + 做**：對方 settle 後（idle/done）**只讀 nudge 指名的那個檔**；
   若未指名，只處理 `pair` 等於自己 tab_id 的 `open` 訊息，其餘不動也不歸檔。
   （只認 `.md`；`.<…>.md.part` 是還沒 publish 的草稿，掃描時本來就看不到、也不要碰。）
   settle 了卻**找不到回覆檔**：等到的不是你那一輪（例如別組在 pre-settle 與提交
   之間也敲了它），你的 nudge 還排在隊裡。此時裸跑一次 `agent wait` 沒有用——
   對方已經 settle，它會立刻 match 同一個 idle。要等**下一輪**：
   `herdr agent wait <peer_pane_id> --until working --timeout 15000`（排隊的 nudge
   開跑時會轉 working），接著 `herdr agent wait <peer_pane_id>` 等它 settle，再查
   收件匣——**working 那段等到 timeout 也一樣要再查一次**：那一輪可能在你開始等
   之前就跑完了，timeout 不等於 nudge 被吞。查完**仍然**沒有回覆檔才喊人類，
   **不要**直接重敲（會重複下指令）。
   `blocked`（或提交前就被拒的 `agent_blocked`）就喊人類；
   `herdr agent read <peer_pane_id>` 可看它卡在哪個確認畫面。
4. **回覆**：收訊方用 `next-id.sh` + `publish.sh` 在 `inbox/to/<發訊方>/` 上架新
   訊息（`reply_to` 指回原 id），把**原訊息**搬到 `inbox/archive/`，換手敲門回去。

## 硬規則（避免互相踩）

- **不同時改同一檔程式碼**。慣例：Claude 寫 code（開 branch），{{PEER}} 只讀 diff + 寫意見。
- **git branch 是第二層匯流排**：Claude commit 到 feature branch，{{PEER}} `git diff` review。
- **不碰預設分支**：實作走 branch，人類決定何時 merge。
- 一則訊息只講一件事；大任務拆多則。
- 訊息處理完一定要搬 `archive/`，`inbox/to/*` 只留 `open` 的，避免重複執行。
- 專案自己的 `CLAUDE.md` / `AGENTS.md` 等規範仍然適用，且優先於本協定的一般性建議。

## 多組 Claude+{{PEER}} 並存時（重要）

工作區可能同時開著好幾組（一個 tab 一組）。這帶來兩個獨立問題：

**問題一：編號會撞。** v0.5 起用 ULID（`next-id.sh` 產生），無需協調即唯一，
這個問題結構上消失——不再有共享計數器可爭。

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
# 1. 我是誰（herdr >= 0.8，雙方通用）：pane current 即時解析「呼叫者自己的 pane」，
#    一個指令拿到自己的 pane_id / tab_id / agent_session
herdr pane current | jq -r '.result.pane | "ME   pane=\(.pane_id) tab=\(.tab_id)"'

# 2. 我的 peer：tab_id 與上面相同、agent 為對方的那一筆
herdr agent list | jq -r --arg tab "<上一步的 tab>" '.result.agents[]
  | select(.agent=="{{PEER}}" and .tab_id==$tab)
  | "PEER pane=\(.pane_id) status=\(.agent_status)"'
```

> `tab_id` 以 `pane current` 的**即時**結果為準，不要用 `HERDR_TAB_ID` 環境變數——
> 那是 process 啟動時的快照，pane 被搬到別的 tab 後就過期了。
> 也不要用 `focused==true` 找自己——終端焦點在別處時會直接失效。

**`pane current` 失敗時的 fallback**（例如不在 herdr pane 裡執行）：
用自己的 session id 對 `agent_session.value` 在 `herdr agent list` 找**恰好一筆**：

```bash
# Claude Code 的 session id = scratchpad 路徑的最後一層目錄名；
# Codex 是 CODEX_SESSION_ID（實測等於 herdr 的 agent_session.value）
herdr agent list | jq -r --arg me "<my-session-id>" '.result.agents[]
  | select(.agent_session.value==$me)
  | "ME   pane=\(.pane_id) tab=\(.tab_id)"'
```

0 筆或多筆就停下來問人。（另一個次級 fallback：`HERDR_ENV=1` 時
`herdr agent get "$HERDR_PANE_ID"` 也能驗自己，但同樣是啟動時快照。）

**敲門前一定要把「我是誰 → 要敲誰」印出來讓人類可核對。**
同 tab 找不到對方時**停下來問人**，不要退回去用任何寫死的 pane_id。

- **雙方敲門都用 `collab/bin/knock.sh <對方_pane_id> "..."`**（用解析出的 pane_id；
  `knock.sh {{PEER}}` 這種名稱解析在有兩個以上同類 agent 時會拒絕，那是警訊不是故障）。
  它先 pre-settle 再提交；**敲門時不要自己裸跑 `herdr agent prompt ... --wait`**——
  對方還在 working 時那個 wait 可能吃到**上一輪**的結束（herdr 明載 prompt 不追蹤
  turn），等於重新引入 knock.sh 專門擋掉的競態。這對 {{PEER}} 敲回 Claude 的方向
  一樣成立。
- 查狀態：`herdr agent get <pane_id>`／讀輸出：`herdr agent read <pane_id>`
- **一律走 `prompt`（經 knock.sh）不用 `send-keys`**（send-keys 繞過狀態追蹤）。

**誤敲別組時**：立刻停止該輪、不要重試，並告知人類敲到了哪個 pane——
對方那組可能正在跑別的任務。

### 非同步敲門（v0.6.1，對稱／網狀用）

預設 knock 是同步 RPC（送+等對方 settle），適合「我問、我等、我讀回覆」。但它有一條
硬限制:**不能用來回覆一個正在同步等你的對方**——A 同步等 B 時,B 若用預設模式回敲 A,
兩邊互等成死鎖(wait-cycle)。角色對稱或網狀時一定會遇到。解法是把「送」和「收」都
非同步化:

- **送(不等)**:`collab/bin/knock.sh --submit-only <對方_pane_id> "<nudge>"`。跳過
  pre-settle、不帶 `--wait`,herdr **接受** submission 就返回(stderr 印 `submitted,
  not settled`),不等對方開始／完成／回覆。實測確認:對 working peer 的 no-wait submit
  會被接受並排在它當前 turn 之後(不丟、不打斷);blocked peer 仍會被 herdr 拒
  (`agent_blocked`,原樣透傳)。
- **收(每輪開場先對帳自己的收件匣)**:nudge 只是 best-effort 喚醒,而且 herdr 的 turn
  邊界模糊(無法靠「等對方再次 working」偵測排隊訊息),所以**durable 訊息檔才是事實
  來源**。每次你**開始一輪協作前**,先掃自己 `inbox/to/<自己>/` 裡 `pair` 符合、
  `status: open` 的訊息並處理,再做新任務。這是 turn-start 對帳,不是背景輪詢:遺失或
  延遲的 nudge 靠檔案補回。
- **at-least-once、冪等**:一則訊息可能被處理多次。最關鍵的原因是 crash window(不只是
  「nudge + 對帳」兩條發現路徑):若你做完副作用、但在**歸檔前**中斷,下一輪會再看到同一個
  `open` id 而重做。所以副作用要用 `id`／`reply_to` 去重,**歸檔放最後**(已歸檔的 id 不
  重複處理)。collab-bus 沒有 daemon,對方若永遠不再被喚醒就不會處理——沒有 eventual-
  processing 保證。
- **預設維持同步**:非 wait-cycle／非網狀場景一律用預設(阻塞)knock,完成保證較安全;
  放棄它要顯式 `--submit-only`。

**wait-cycle 規則**:若對方當前 turn 可能正在等**你** settle,**絕不要用同步 knock 回敲**
(會死鎖)——publish 你的回覆後,用 `--submit-only` 喚醒,或只 publish 讓對方下一輪
開場對帳時自己撿。
