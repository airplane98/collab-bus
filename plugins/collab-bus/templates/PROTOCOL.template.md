# {{PROJECT}} ⇄ {{PEER}} 協作協定 (collab-bus PROTOCOL)

> 由 collab-bus **{{VERSION}}** 的範本產生。`collab/bin/` 的腳本也是同一版 vendored 過來的。
>
> **本檔屬於 collab-bus，不要手改。** 協定依「誰讀、何時讀、誰擁有」分成四份：
>
> | 檔 | 誰讀、何時讀 | 擁有者 | 重跑 bootstrap 時 |
> |---|---|---|---|
> | **`PROTOCOL.md`（本檔）** | 協作中的 agent，**每一輪** | collab-bus | 更新為新版 |
> | **`PROJECT.md`** | 協作中的 agent，**每一輪**（與本檔一起讀） | **本專案** | **永不覆寫** |
> | `PROTOCOL-modes.md` | 協作中的 agent，**遇到該情況時必讀**（有拘束力） | collab-bus | 更新為新版 |
> | `DESIGN-DECISIONS.md` | **只有要修改協定或腳本的人**（背景，不含規範） | collab-bus | 更新為新版 |
>
> **專案專屬的規則一律寫在 `PROJECT.md`**：review 閘門、不可碰的路徑、專案自訂的 `type`、
> 機密與匿名化規範、「本專案不適用範本的哪些假設」。直接改本檔的話，bootstrap 升級時偵測到
> 手改會**保留舊檔並警告**，本檔就此凍結在舊版，拿不到之後的修正。
>
> **優先順序**：`PROJECT.md` 與專案的 `CLAUDE.md`／`AGENTS.md` > 本檔 > `PROTOCOL-modes.md`。
> 例外：**Trust anchor 與 participant 的安全規則不可被放寬**——`PROJECT.md` 只能加嚴。
> 修改協定時四份都要讀。

兩個 AI CLI（Claude Code + {{PEER}}）共享這個 repo。**訊息內容 + 審計軌跡**走檔案
（`collab/inbox/`）；**傳輸與「對方跑完沒」**走 **herdr**——**雙方敲門都用
trusted preflight 回傳的 `$BIN/knock.sh`**（先 `agent wait` 把對方進行中的一輪等完，
再 `agent prompt --wait` 提交並等 settle；靠語義狀態，不輪詢、不 send-keys）。
這份檔（連同 `PROJECT.md`）是雙方唯一的共同約定，衝突時以此為準。

**角色對稱**：`from`/`to` 是欄位、敲門雙向、雙方呼叫同一份 `collab/bin/`。任一方都可以
發起，{{PEER}} 也可以請 Claude review 它的東西。人類也可隨時指定分工。

## Trust anchor（每一輪、任何 project code 之前）

`collab/bin/` 是待驗目標，不能用它自己的程式判斷自己是否可信：若其中一個 executable
是 symlink，等它自己說「拒絕 symlink」時 target 早已執行。每一方都要從**專案外、由該
provider 本來就信任的安裝／clone**提供 preflight：

- Claude Code：provider-local 值是
  `COLLAB_BUS_TRUSTED_SCRIPTS="${CLAUDE_PLUGIN_ROOT}/scripts"`。
- {{PEER}}：在它自己的 shell／agent 設定裡，將 `COLLAB_BUS_TRUSTED_SCRIPTS` 設成其
  **own clone/install** 的絕對路徑。這個值不可從本 repo、`collab/` 或本 PROTOCOL
  讀入；未設定就停下來請人類提供，不可猜。

從 project root 開始每一輪：

```bash
: "${COLLAB_BUS_TRUSTED_SCRIPTS:?set it in provider-local config to a trusted collab-bus clone/install}"
PROJECT_ROOT="$(pwd -P)"
BIN=$("$COLLAB_BUS_TRUSTED_SCRIPTS/preflight.sh" --dir "$PROJECT_ROOT") || exit 1
```

`--dir` 一定是 `$(pwd -P)`。**不要把固定路徑寫進 provider-local 設定**——那份設定每個專案
都會讀，寫死的話從下一個專案起就會默默去驗證別的專案的 bin。

preflight 通過後，本輪所有 runtime 都只從它回傳的 `$BIN` 呼叫；通過前不執行任何
`collab/bin/` 程式。

## Participants（定址與綁定）

訊息定址給**穩定的 participant id**，不靠 tab：pane 換了、agent 重啟了，位址不變。
bootstrap 預設建立 **`claude-primary`** 與 **`{{PEER}}-primary`**。

| 檔 | 意義 |
|---|---|
| `collab/participants/<id>.json` | 不可變的身分 |
| `collab/bindings/<id>.json` | 目前持有該身分的 live process；**只有持有者能從自己的 pane 建立**。這是機器固有的執行時狀態，**不要放進版本控制** |

```bash
"$BIN/participant.sh" ensure <自己的 id>   # 綁定的確認、更新（冪等，每輪開場執行，見收發流程 0.）
"$BIN/participant.sh" whoami               # 我是哪個 participant
"$BIN/participant.sh" snapshot <對方 id>   # 一次讀出：schema  liveness  pane_id  tab_id  session
"$BIN/route.sh" list --agent <自己的 id>   # 定址給我的訊息（舊→新）
"$BIN/route.sh" explain <檔>               # 某一則為什麼有／沒有列進來
```

- 對方的 liveness 與 pane **用 `snapshot` 一次讀出**，不要分兩次查——兩次之間狀態可能改變。
- `ensure` 不接受 `--takeover`，**不會搶走活著的 session 的綁定**。要從活著（或無法判定）
  的 session 手上接過身分，只能由人類判斷後 `bind <id> --takeover`。

## 使用方針：bus 是記錄系，herdr 直接 prompt 是會話系

| 往來的種類 | 手段 |
|---|---|
| 成果物 review 請求、review 結果、承認判定、交接、需要日後重啟的工作 | **collab-bus**（inbox + frontmatter + publish + knock）。`thread`／`reply_to`／`status` 留下審計軌跡 |
| 簡短商量、進度確認、臨時調整、徵詢意見、「幫我跑這個測試、只要結果」 | **herdr 直接 prompt**（`herdr agent prompt <pane> "<text>" --wait` → `herdr pane read <pane>`）。**不留記錄** |

- 直接 prompt 開頭明講「不需記錄，不走 collab-bus，直接在這個 pane 回答」。之後需要引用時，
  把要點轉記到 bus 的下一則訊息或專案的日誌。
- 協定變更（本檔或 `PROJECT.md`）要走 bus，讓對方同意後才實施。

## 角色分工

**這是常見分工，不是機制限制——任一方都可以發起。**

- **Claude Code = orchestrator**（常見情形）：規劃、拆任務、實作、開 branch；把要 review /
  第二意見的東西寫成訊息丟給 {{PEER}}。
- **{{PEER}} = reviewer / 糾錯 / 獨立第二意見**（常見情形）：讀訊息與 diff，review、抓 bug、
  挑架構；**不直接改預設分支**，修改建議寫成訊息回丟。

專案可在 `PROJECT.md` 改寫分工（例如固定採用 finder-fixes）。

## 兩種 review 模式:author-fixes / finder-fixes

一次 review 走兩種模式之一。**author-fixes 在既有專案授權下是預設;啟用 finder-fixes
才需要雙方明確同意。**

- **author-fixes(預設)**:reviewer 只報告,作者套用每個修正,reviewer 不改 target
  ——就是「一次一個 writer」的預設慣例。
- **finder-fixes**:誰發現 bug 誰可以修,修完把 target 交回**驗證**。筆跟著發現走,
  用來平衡雙方的寫入負擔。

finder-fixes 是 opt-in,且**下列全部成立才允許**:

- **git target**:被 review 的碼在 git repo 裡(`git -C <target> rev-parse
  --show-toplevel`),且 bus runtime 是另一棵樹。非 git 的 target(如 Dropbox 交付根目錄)
  只能 author-fixes。
- **專案 owner-rule 優先**:專案 `CLAUDE.md`／`AGENTS.md`／`PROJECT.md` 若禁止 reviewer 寫,
  壓過本節,不得啟用 finder。
- **雙方同意**:initiator 在訊息 body 提 `fix-policy: finder`,對方**明確接受**才開始
  finder-fixes;author-fixes 是預設,不需這道手續。finder 啟用後,某則 mode 缺失/矛盾或
  context 遺失 → **停下重談**,不各自默默退回 author(那會偷改誰在寫);每則
  action/handoff/verify reply 都重述 mode、引用同一份約定,只在 handoff 邊界切換。
- **一次一個 writer**:交手出去的 checkout,在對方手上時不要動它;停掉它上面的背景寫入程序。
  **筆怎麼移動**——兩件事要分開看:
  - **checkout 的筆**只在**明確的 handoff**(`type: fix-applied`)publish 時移交給對方。
    handoff **不關閉原 request**:對方驗證時發現新缺陷,可以依 finder-fixes 接著修再交回。
  - `question`／`ack`／進度 `reply`、nudge timeout、對方 idle **都不移交筆**。
  - **原 request 的結束**(由它的 recipient 在所有 findings 都有結論後送出終局回覆)與
    **checkout 所有權的移交**是兩件事——不要為了驗證一個已修好的項目而提早結束原 request。
- **每次交手前、離開前都先 commit**:handoff 用 `type: fix-applied`、commit 放 `refs`,
  講明要驗什麼;接收方動手前先確認在對的 branch/commit 且 tree 乾淨。**不符就停下回報**
  ——絕不覆蓋 checkout 狀態、不把別人的 edit 併進來、不 `reset --hard` / `clean` /
  force-push 去製造乾淨。

**這是 best-effort,不是滴水不漏。** 兩個 writer 若無視「一次一個」,可能丟掉**未 commit**
的編輯;commit 是復原檢查點,**只在所需 objects 還在時有效**——reflog 會過期,commit 不是備份。
checkout 的擁有權是**合作約定,bus 不強制**。驗證方回「乾淨」、或帶證據交回「修錯了/新缺陷」、
或老實說「現在無法驗證」(不准假造 verdict、不准為了驗證改 source);原 request 由**它的
recipient** 在所有 findings 都有結論後收尾——一個 fix 通過不等於關掉整案。

## 目錄結構

```
collab/
├── PROTOCOL.md              # 本檔（collab-bus 擁有，每一輪讀）
├── PROJECT.md               # 專案專屬規則（專案擁有，每一輪讀，永不覆寫）
├── PROTOCOL-modes.md        # 稀用模式（wait-cycle、fallback；該情況時必讀）
├── DESIGN-DECISIONS.md      # 設計理由（只有修改協定的人讀）
├── inbox/
│   ├── to/{{PEER}}/            # 給 {{PEER}} 的訊息（Claude 寫 → {{PEER}} 讀）
│   ├── to/claude/           # 給 Claude 的訊息（{{PEER}} 寫 → Claude 讀）
│   └── archive/             # 處理完的訊息搬來這（保留歷史）
├── participants/            # 身分登記（不可變）
├── bindings/                # 目前持有身分的 process（機器固有，不進版本控制）
├── reviews/                 # review 記錄與成果 md（長期存檔）
└── tasks/                   # 進行中任務追蹤（一任務一檔）
```

## 訊息格式

一則訊息 = `inbox/to/<recipient>/` 下一個 markdown 檔。**檔名**：`<ULID>-<tab>-<slug>.md`。

**三步，不要自己算 id、不要自己搬檔名**（理由 → `DESIGN-DECISIONS.md` §A）：

```bash
# 同一輪先跑 trust-anchor block，取得已驗證的 $BIN
DRAFT=$("$BIN/next-id.sh" <recipient> <slug> <自己的 tab_id>)  # 回傳 .md.part 草稿
#   …把完整內容（含 frontmatter）寫進 $DRAFT…
DEST=$("$BIN/publish.sh" "$DRAFT")                            # 原子上架成最終 .md
```

`publish.sh` 會自動跑 `check-envelope.sh`：**frontmatter 不合規的草稿上不了架**。
不確定格式時先跑 `"$BIN/check-envelope.sh" <檔>`，不要靠記憶。

```markdown
---
schema: 2
id: 01M0WG3WJF6AX39B2RGCPVN2CM
thread: 01M0WG3WJF6AX39B2RGCPVN2CM
from: claude
to: {{PEER}}
from_agent: claude-primary
to_agent: {{PEER}}-primary
intent: action
type: review-request
subject: '一句話標題'
refs: 'branch / commit / 檔案'
status: open
pair: w3:t3
---

<正文：要對方做什麼、脈絡、驗收條件。一則只講一件事。>
```

欄位說明（**不要把這些註解抄進真正的訊息**——validator 會把 `# ...` 當成值的一部分）：

| 欄位 | 值 |
|---|---|
| `schema` | `2`。舊訊息沒有這一行，讀取時視為 `1` |
| `id` | `next-id.sh` 產生的 ULID，**必須與檔名前綴相同** |
| `thread` | 這串對話的 id；開新話題時填自己的 `id` |
| `from` / `to` | kind：`claude` \| `{{PEER}}`（也決定 `inbox/to/` 目錄） |
| `from_agent` / `to_agent` | **穩定 participant id**（如 `claude-primary`），路由比對這個 |
| `intent` | `action` \| `fyi`——你要對方做什麼，不是生命週期 |
| `type` | `review-request` \| `review-result` \| `task` \| `reply` \| `question` \| `ack` \| `fix-applied`（finder-fixes 的交手）。專案自訂的 type 寫在 `PROJECT.md` |
| `subject` / `refs` | **你自己寫的文字 → 單引號** |
| `reply_to` | 可選，**只在回覆時出現**：填**對方那則**的 id（不是自己的）。開新話題時整行省略 |
| `outcome` | 可選，**只出現在收訊方的終局回覆**：`done` \| `rejected` \| `failed` \| `canceled`。問題與進度回報不帶，才不會被誤讀成「做完了」 |
| `status` | `open` \| `done` \| `closed`（legacy，仍照寫） |
| `pair` | 發訊方的 herdr tab_id（legacy，仍照寫） |

> ⚠️ **human 欄位用單引號，machine 欄位不要加引號。**
> `subject`、`refs` → **一律單引號**，內部單引號寫兩次（`'it''s'`），**不可換行**。
> `id`/`from`/`to`/`type`/`status`/`pair`/`reply_to` → **不可加引號**。
> `"$BIN/fm-quote.sh" <文字>` 直接產生合規的值。最常見的陷阱是 plain 值裡出現 `": "`
> （→ `DESIGN-DECISIONS.md` §F）。

> **定址靠 participant，不靠 tab。** `pair` 是**位置**，同 tab 有兩個同 kind 的
> participant 時會同時符合兩邊。`to_agent`/`from_agent` 是**穩定 id**，路由精確比對它。
> 但 `pair` 與 `status: open` **仍然照寫**（舊 reader 靠它們對帳）。什麼時候可以不寫，由
> `"$BIN/route.sh" capability` 回答（現在的答案是：不行）。

## 收發流程（一輪）

0. **開場對帳（每一輪必做，先於任何新工作）**：
   ```bash
   "$BIN/participant.sh" ensure <自己的 participant id> || exit 1   # 綁定的確認、更新（冪等）
   "$BIN/route.sh" list --agent <自己的 participant id>             # 列出定址給自己的訊息
   ```
   **`ensure` 每一輪無條件執行即可。** 已綁定時什麼都不做（`binding already current`，
   exit 0）；新 session 而舊綁定的 session **已確認結束**（liveness `absent`）時，改綁到自己。
   開新 session 不需要人類手動 `bind`。

   **`ensure` 失敗時，不論原因都停下來告知人類。** 典型是舊 session 還活著（`live`），或
   herdr 沒回應無法判定（`unknown`），但 pane 解析失敗、執行環境錯誤也會失敗。都不要往下走，
   也**不要自行 `bind --takeover`**——舊 session 是否真的結束由人類判斷。

   接著 `route.sh list` 列出的訊息，**先於新工作處理**。nudge 只是 best-effort 的喚醒，
   可能延遲或遺失——**durable 的訊息檔才是事實來源**，這個對帳是撿回它們的唯一途徑。
   **unrouted**（沒有 `to_agent` 也沒有 `pair`）或讀不動的檔會列在 stderr：**不要擅自認領，
   也不要刪除**，原地保留並告知人類。
1. **寫 + 上架**：上面「訊息格式」那三步。內容要含 `status: open`。
2. **敲門**：先依「herdr 座標」**動態解析對方的 pane_id**，再
   `"$BIN/knock.sh" <對方_pane_id> "<一句話，並指名檔案路徑>"`（雙方共用這一個入口）。
   knock 先 `agent wait` 把對方進行中的那一輪等完再提交——否則 `prompt --wait` 可能
   吃到**上一輪**的結束，你會去讀一個還不存在的回覆檔。
   發新請求時，若對方**可能正在等你**，改用 `--submit-only`（→ 本檔末「wait-cycle」）。
3. **讀 + 做**：對方 settle 後**只讀 nudge 指名的那個檔**；未指名就跑
   `"$BIN/route.sh" list --agent <自己的 participant id>`（列出定址給你的，由舊到新），
   其餘不動也不歸檔。只認 `.md`，`.<…>.md.part` 是未上架草稿，不要碰。

   **要把一則訊息當成「自己在等的那個請求的回覆」，下列全部要成立**：
   - 在 `route.sh list --agent <自己的 participant id>` 中**以自己為收件人**列出
   - frontmatter 的 `reply_to` **等於自己送出的那則的 id**
   - `pair` **等於自己的 tab_id**

   只是等收件匣有新檔進來，會把**同一個 participant 收到的其他 thread 的回覆**誤認成自己
   請求的完成。不滿足上列條件的，就不當成自己請求的回覆。

   **settle 了卻找不到回覆檔**（等到的不是你那一輪）：裸跑 `agent wait` 沒有用，
   要等**下一輪**——
   ```bash
   herdr agent wait <peer_pane_id> --until working --timeout 15000
   herdr agent wait <peer_pane_id>
   ```
   再查收件匣。**working 那段等到 timeout 也一樣要再查一次**（那一輪可能在你開始等
   之前就跑完了）。查完**仍然**沒有才喊人類，**不要**直接重敲（會重複下指令）。

   `blocked`（或提交前就被拒的 `agent_blocked`）就喊人類；
   `herdr agent read <peer_pane_id>` 可看它卡在哪個確認畫面。
4. **回覆**：收訊方用同樣三步在 `inbox/to/<發訊方>/` 上架（`reply_to` 指回原 id），
   把**原訊息**搬到 `inbox/archive/`，**最後一定用 `--submit-only` 換手敲門回去**：
   ```bash
   "$BIN/knock.sh" --submit-only <發訊方_pane_id> "process <回覆檔路徑>"
   ```
   **回覆的敲門一律 `--submit-only`，不用同步 knock。** 回覆方**無法排除**發訊方正用同步
   knock 等自己 settle 的可能（預設流程就是如此；非同步請求、手動 nudge、等待逾時後則未必，
   但回覆方分辨不出來）。在被等的狀態下同步回敲會 wait-cycle 死鎖，所以一律 `--submit-only`。
   它只是排在對方目前這一輪後面，**不會造成 wait-cycle**——回覆方不必推測對方狀態。
   （`--submit-only` 成功只代表 submission 被受理，不保證對方讀了、處理完了。最終的回收路徑
   仍是 durable 的回覆檔與開場對帳。）

   **只 publish 不敲門，僅限 `--submit-only` 被拒、送不出、或結果不明時**（對方 `blocked` →
   `agent_blocked`、通知目標消失、herdr 連線失敗等）。這時也**不改用同步 knock、不無條件重送**：
   以「herdr 座標」的解析與停止規則為優先，保留已 publish 的回覆，交給對方的開場對帳（0.），
   並向人類回報。**不敲門就結束，發訊方要等到人類跟它說話才會發現回覆。**

> **at-least-once、冪等。** 一則訊息可能被處理多次（最關鍵是 crash window：做完副作用
> 但在**歸檔前**中斷）。副作用要用 `id`/`reply_to` 去重，**歸檔放在副作用之後**
> （→ `PROTOCOL-modes.md` §B）。

## 硬規則（避免互相踩）

- **一次一個 writer**：不同時改同一檔。finder-fixes 的交手規則見上。
- **git branch 是第二層匯流排**：實作走 branch，檢查方看 `git diff`。**審查請求盡量指定 diff
  範圍**（`git diff <base> <head>`），不要叫對方重讀整個檔案。
- **不碰預設分支**：實作走 branch，人類決定何時 merge。
- 一則訊息只講一件事；大任務拆多則。
- 訊息處理完一定要搬 `archive/`，`inbox/to/*` 只留 `open` 的，避免重複執行。
- 專案的 `CLAUDE.md`／`AGENTS.md`／`PROJECT.md` 仍然適用，且優先於本協定的一般性建議。

## 多組 Claude+{{PEER}} 並存時（重要）

工作區可能同時開著好幾組（一個 tab 一組）。**收件匣是共用的**：`inbox/to/{{PEER}}/` 只說
「給 {{PEER}}」，沒說給**哪一個**，兩組的 peer 都會讀到同一個目錄。

→ 每則訊息必須帶 `pair`（發訊方的 `tab_id`）；收訊方用 `route.sh list` 決定哪些是自己的：
有 `to_agent` 就精確比對它，沒有的（已上架、無法補寫的舊訊息）才回退到 `pair`。
**有 `to_agent` 卻不是你的，絕不因為 tab 相同而回退**。其餘不動也不歸檔。
敲門的 nudge 要明講檔名。`inbox/to/*` 可能同時留著別組的 `open` 訊息，這是正常的。

> ⚠️ `pair` 是「防誤處理」，不是存取控制——擋不住惡意或有 bug 的一方（→ `DESIGN-DECISIONS.md` §E）。

## herdr 座標（動態解析，不可寫死）

> **不要把 pane_id 寫死在這份檔案裡。** 工作區一旦出現第二組，靜態座標就會敲到別人
> 那一組——這確實發生過，打斷了另一組正在跑的工作。每次敲門前重新解析。

**規則：peer = 與自己同一個 `tab_id` 的對方 agent**（不是 pane 編號、也不是名稱）。

```bash
# 1. 我是誰：--current 明確指向「呼叫者」（省略時 herdr 可能改用 UI 聚焦的那個 pane）
herdr pane current --current | jq -r '.result.pane | "ME   pane=\(.pane_id) tab=\(.tab_id)"'

# 2. 我的 peer：tab_id 與上一步相同、agent 為對方的那一筆
herdr agent list | jq -r --arg tab "<上一步的 tab>" '.result.agents[]
  | select(.agent=="{{PEER}}" and .tab_id==$tab)
  | "PEER pane=\(.pane_id) status=\(.agent_status)"'
```

已綁定後，對方的 pane 也可用 `"$BIN/participant.sh" snapshot <對方 id>` 一次讀出。

不要用 `HERDR_TAB_ID`（process 啟動時的快照，pane 搬 tab 後過期），也不要用
`focused==true` 找自己（終端焦點在別處時失效）。`pane current` 失敗時 →
`PROTOCOL-modes.md` §C（該情況時必讀）。

**敲門前一定要把「我是誰 → 要敲誰」印出來讓人類可核對。**
同 tab 找不到對方時**停下來問人**，不要退回去用任何寫死的 pane_id。

- **雙方敲門都用 `"$BIN/knock.sh" <對方_pane_id> "..."`**（`knock.sh {{PEER}}` 這種名稱解析
  在有兩個以上同類 agent 時會拒絕，那是警訊不是故障）。**不要自己裸跑
  `herdr agent prompt ... --wait`**——那等於重新引入 knock.sh 專門擋掉的競態。
- 查狀態：`herdr agent get <pane_id>`／讀輸出：`herdr agent read <pane_id>`
- **一律走 `prompt`（經 knock.sh）不用 `send-keys`**。

**誤敲別組時**：立刻停止該輪、不要重試，並告知人類敲到了哪個 pane。

> ⚠️ **wait-cycle（一對一的同步請求與回覆也會發生，不限網狀）**：
> 對方目前這一輪**可能正在等你 settle** 時，**不要用同步 knock**（兩邊互等死鎖）。
>
> - **回覆**無法排除被等的可能，所以**依收發流程 4. 一律 `--submit-only`**。
> - **發新請求**時，對方沒在等你就照常同步 knock（完成保證較強）；可能在等就 `--submit-only`。
>
> 細節與 at-least-once 的處理 → **`PROTOCOL-modes.md` §B（該情況時必讀）**。
