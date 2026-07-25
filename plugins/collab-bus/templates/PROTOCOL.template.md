# {{PROJECT}} ⇄ {{PEER}} 協作協定 (collab-bus PROTOCOL)

兩個 AI CLI（Claude Code + {{PEER}}）共享這個 repo，用**檔案系統當訊息匯流排**、
**tmux `send-keys` 當敲門通知**。這份檔是雙方唯一的共同約定，衝突時以此為準。

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
**檔名**：`NNNN-<slug>.md`，`NNNN` 為全域遞增四位數（`0001`、`0002`…），不重用。

```markdown
---
id: 0001
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
2. **敲門**：發訊方跑 `notify.sh <對方> "<一句話>"`（plugin 提供，用 tmux 注入對方 prompt）。
3. **讀 + 做**：收訊方讀最新 `open` 訊息、執行。
4. **回覆**：收訊方在 `inbox/to/<發訊方>/` 建新 `NNNN-*.md`（`reply_to` 指回原 id），
   把**原訊息**搬到 `inbox/archive/`，換手敲門回去。

## 硬規則（避免互相踩）

- **不同時改同一檔程式碼**。慣例：Claude 寫 code（開 branch），{{PEER}} 只讀 diff + 寫意見。
- **git branch 是第二層匯流排**：Claude commit 到 feature branch，{{PEER}} `git diff` review。
- **不碰預設分支**：實作走 branch，人類決定何時 merge。
- 一則訊息只講一件事；大任務拆多則。
- 訊息處理完一定要搬 `archive/`，`inbox/to/*` 只留 `open` 的，避免重複執行。
- 專案自己的 `CLAUDE.md` / AGENTS.md 等規範仍然適用，且優先於本協定的一般性建議。

## tmux 座標

- socket：`{{SOCKET}}`（固定路徑，背景 agent 才連得到）
- session：`{{SESSION}}`
- {{PEER}} pane：`{{SESSION}}:{{PEER}}`
- Claude 敲門：`notify.sh {{PEER}} "..."`；{{PEER}} 敲門回：`notify.sh claude "..."`
