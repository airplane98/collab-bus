# {{PROJECT}} 協作協定 — 稀用模式（collab-bus {{VERSION}}）

> **本檔屬於 collab-bus，不要手改**（專案規則寫在 `PROJECT.md`）。
>
> **是協定的一部分，遇到該情況時必讀、有拘束力。** 是 `PROTOCOL.md` 委派出來的操作程序，
> 一般的同步協作用不到，所以分開放。
>
> | 節 | 什麼情況下必讀 |
> |---|---|
> | §B | 對方目前這一輪**可能正在等你 settle** 時要送東西過去（一對一的同步請求也會發生，不限網狀） |
> | §C | `herdr pane current` 失敗（例如不在 herdr pane 裡執行） |
>
> 最小規則（被等時不用同步 knock、回覆一律 `--submit-only` 等）也寫在 `PROTOCOL.md` 本文，
> 本檔是細節程序。**本檔與 `PROTOCOL.md` 不一致時，以 `PROTOCOL.md` 為準。**
> 設計理由與歷史在 `DESIGN-DECISIONS.md`（不含規範）。

---

## §B 非同步敲門（對稱／網狀用）

預設 knock 是同步 RPC（送+等對方 settle），適合「我問、我等、我讀回覆」。但它有一條
硬限制：**不能用來回覆一個正在同步等你的對方**——A 同步等 B 時，B 若用預設模式回敲 A，
兩邊互等成死鎖（wait-cycle）。解法是把「送」和「收」都非同步化。

### 送（不等）

```bash
"$BIN/knock.sh" --submit-only <對方_pane_id> "<nudge>"
```

跳過 pre-settle、不帶 `--wait`，herdr **接受** submission 就返回（stderr 印
`submitted, not settled`），不等對方開始／完成／回覆。對 working peer 的 no-wait submit
會被接受並排在它當前 turn 之後（不丟、不打斷）；blocked peer 仍會被 herdr 拒
（`agent_blocked`，原樣透傳）。

### 收（每輪開場先對帳自己的收件匣）

> 開場對帳**不限於 wait-cycle，是每一輪的義務**，以 `PROTOCOL.md` 收發流程 0. 為準。
> 以下是它的背景與細節。

nudge 只是 best-effort 喚醒，而且 herdr 的 turn 邊界模糊（無法靠「等對方再次 working」
偵測排隊訊息），所以**durable 訊息檔才是事實來源**。每次**開始一輪協作前**，先
`participant.sh ensure` 再 `"$BIN/route.sh" list --agent <自己的 participant id>`，
處理列出來的訊息，再做新任務。`route.sh explain <檔>` 會說明某一則為什麼有／沒有列進來。

這是 **turn-start 對帳，不是背景輪詢**：遺失或延遲的 nudge 靠檔案補回。被判為
**unrouted**（沒有 `to_agent` 也沒有 `pair`）或**讀不動**的檔會列在 stderr 並原地保留：
不會被默默認領，也不會被默默丟掉。

### at-least-once、冪等

一則訊息可能被處理多次。最關鍵的原因是 crash window（不只是「nudge + 對帳」兩條發現路徑）：
若你做完副作用、但在**歸檔前**中斷，下一輪會再看到同一個 `open` id 而重做。所以副作用要用
`id`／`reply_to` 去重，**歸檔放在副作用之後**（已歸檔的 id 不重複處理）。
collab-bus 沒有 daemon，對方若永遠不再被喚醒就不會處理——沒有 eventual-processing 保證。

回覆的順序是「上架回覆 → 歸檔原訊息 → `--submit-only` 敲門」。歸檔後、敲門前中斷時，
回覆已存在、原請求已關閉，不會重複處理；漏掉的通知由對方的開場對帳撿回。

### 預設維持同步（僅限發新請求）

**發新請求**時，非 wait-cycle／非網狀場景一律用預設（阻塞）knock，完成保證較安全；
放棄它要**顯式** `--submit-only`。

**回覆的敲門不在此列，一律 `--submit-only`**（`PROTOCOL.md` 收發流程 4.）：回覆方無法排除
發訊方正在等自己的可能，被等時同步回敲會 wait-cycle 死鎖。

> **wait-cycle 規則**：對方當前 turn 可能正在等**你** settle 時，**絕不要用同步 knock
> 回敲**（會死鎖）——publish 你的回覆後，用 `--submit-only` 喚醒。
> **只 publish 不敲**僅限 `--submit-only` 被拒、送不出、或結果不明時（對方 `blocked`、
> 通知目標消失、herdr 連線失敗等）；不改用同步、不無條件重送，保留已 publish 的回覆，
> 交給對方的開場對帳並告知人類（`PROTOCOL.md` 收發流程 4.）。

---

## §C herdr 座標：`pane current` 失敗時的 fallback

例如不在 herdr pane 裡執行時。用自己的 session id 對 `agent_session.value` 在
`herdr agent list` 找**恰好一筆**：

```bash
# Claude Code 的 session id = scratchpad 路徑的最後一層目錄名；
# {{PEER}} 若提供自己的 session id 環境變數（例如 Codex 的 CODEX_SESSION_ID，實測等於
# herdr 的 agent_session.value），用它
herdr agent list | jq -r --arg me "<my-session-id>" '.result.agents[]
  | select(.agent_session.value==$me)
  | "ME   pane=\(.pane_id) tab=\(.tab_id)"'
```

**0 筆或多筆就停下來問人。**

次級 fallback：`HERDR_ENV=1` 時 `herdr agent get "$HERDR_PANE_ID"` 也能驗自己，但同樣是
**啟動時快照**（pane 搬 tab 後過期）。已綁定後，`"$BIN/participant.sh" whoami` 直接回傳
自己的 participant id。

舊版 herdr 若不認 `--current` 旗標，去掉它即可——但省略目標時 herdr 可能改用
**UI 聚焦的那個 pane**（可能是別人的），要多核對一次。
