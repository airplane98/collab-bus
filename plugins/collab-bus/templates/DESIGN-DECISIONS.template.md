# collab-bus 設計判斷記錄 — 為什麼是這個形狀、為什麼不要改回去（{{VERSION}}）

> **本檔屬於 collab-bus，不要手改。**
>
> **本檔與每一輪的協作無關。** 只有**要修改協定或腳本時**才讀。運作規則在 `PROTOCOL.md`，
> 稀用模式在 `PROTOCOL-modes.md`，專案規則在 `PROJECT.md`。
>
> 目的只有一個：**防止之後有人「出於好意」把設計改回去。** 這裡列的不是抽象的設計論，而是
> **collab-bus 開發與實際使用中真的發生過的事故**，以及為了不再發生才變成現在這樣的經過。
> 覺得「這是不是多餘」時，先讀那一項的事故。
>
> 本檔不含規範；與 `PROTOCOL.md` 不一致時以 `PROTOCOL.md` 為準。

---

## §A 配號與 publish

### 手算 id —— 真的撞號過

**絕不要自己手算 id**，尤其不要「現有最大 + 1」——那是 read-then-write 競態，兩個 session
同時算就撞號。**v0.4 之前實際發生過：同一收件匣出現兩則 `0033`。**

### 為什麼是 ULID（v0.5 起）

id 是 ULID（48-bit 毫秒時間戳 + 80 隨機位元，Crockford base32，26 字元）。**不是共享計數器，
所以不需要鎖。** ULID 不需要任何協調就唯一：兩個 agent——甚至同步資料夾後的兩台機器——
各自獨立產生，撞號機率可忽略，因為**沒有共享可變狀態可爭**。

v0.2–v0.4.1 為了共享計數器建的 **mkdir 互斥鎖、owner token、鬼鎖復原、`/tmp` 鎖路徑導出
全部已刪除**。覺得「沒有鎖很危險」而把它加回來，會把已經消滅的鬼鎖問題帶回來。時間戳是
高位前綴，所以檔名仍照時間排序；tab 與 slug 仍在後面，人類照樣讀得懂。

### 為什麼用 `link`，不用 `ln` 也不用 rename

`publish.sh` 用 **exact two-path 的 `link` utility 做原子 no-replace hard link**。

- **不是 `ln`**——`ln SOURCE DIR` 會把檔案連進**目錄裡**，吞掉訊息、丟失草稿。
- **不是 rename**——沒有可攜的 no-replace rename。

目的地已存在（檔案／目錄／symlink，含 dangling）時，`link()` 以 EEXIST **原子失敗**，
所以既有訊息在結構上不可能被覆寫。

### 為什麼要經過草稿

`next-id.sh` 回傳的是**草稿**（`.<ULID>-…md.part`，點開頭、`.part` 結尾，收件匣掃描看不到）。
**最終 `.md` 只透過 `publish.sh` 的 link 出現。**

沒有這一步，收訊方會讀到「已佔號但還沒填內容」的空訊息——**collab-bus 的實際使用中真的踩過
空回覆檔。** `publish.sh` 會拒絕空草稿，別在寫內容前就 publish。

### 兩層防覆寫

`next-id.sh` 用 exclusive create（`noclobber`）保護**草稿**，`publish.sh` 用上面的
no-replace `link` 保護**最終檔名**。ULID 撞號機率是天文級小，但這兩層都零成本，也順手擋掉
同步資料夾帶來的同名檔。

### ⚠️ 跨機器不是嚴格單調

ULID 保證唯一，但兩台機器時鐘不完全同步時，時間排序只精確到毫秒級。若某流程需要跨機器
**嚴格單調**的序號，ULID（和舊計數器一樣）都不提供，得用中央 allocator。日常協作用不到。

---

## §D 為什麼協定分成四份、依擁有者區分

### 事故：舊專案永遠拿不到協定的修正

v0.9 之前，`PROTOCOL.md` 一份檔裡**混著兩種東西**：collab-bus 的通用規則，和專案自己加的
規則。bootstrap 為了不吃掉專案的修改，**重跑時從不覆寫 `PROTOCOL.md`**——結果通用規則也
一起凍結在建立當時的版本。實際發生過：某個專案修好了「回覆後沒敲門，發訊方要等人類開口才
發現回覆」「每開一個新 session 都要手動 bind」這些問題，但其他專案重跑 bootstrap 也拿不到。

### 決定

依**擁有者**分檔：

- `PROTOCOL.md`、`PROTOCOL-modes.md`、`DESIGN-DECISIONS.md` 屬於 collab-bus，
  **重跑 bootstrap 時更新為新版**（和 `collab/bin/` 一樣）。
- `PROJECT.md` 屬於專案，**永不覆寫**。專案規則一律寫這裡。

另外依**讀者與時機**把通用部分再分三份：每一輪讀的本文、遇到該情況才讀的稀用模式、
只有改協定的人才讀的設計理由。每一輪要讀的量因此變少。

### 為什麼偵測到手改就保留，而不是覆寫或整個拒絕

bootstrap 在 `collab/.protocol-vendored` 記錄上次放進去的各檔 SHA-256。重跑時：

- 與記錄相同（沒被手改）→ 更新為新版
- 與記錄不同（被手改過）→ **保留並警告**，那一份就凍結在舊版
- `collab/bin/` 照常更新

**不整個拒絕**，是因為那樣連 `bin/` 的修正也拿不到，而且違反 bootstrap 一直以來
「重跑一定成功、不動非 bin 的檔案」的承諾。**不直接覆寫**，是因為那會默默吃掉專案寫進去的
規則——正是 v0.9 之前刻意避免的事。所以選「逐檔判斷、保留手改、講清楚」。

### 為什麼舊專案要明確 `--adopt`

沒有 `.protocol-vendored` 的 bus（v0.9 之前建立的）無從判斷 `PROTOCOL.md` 哪裡是專案加的。
這時 bootstrap **維持舊行為（不碰）**，只印出採用新結構的步驟。人類把專案規則搬進
`PROJECT.md` 後，用 `bootstrap.sh <peer> --adopt` 明確採用：既有的協定檔先備份成
`*.pre-<version>`，再放入新版並記錄 hash。**不會在沒人要求的情況下改動舊專案。**

---

## §E `pair` 不是存取控制

⚠️ **`pair` 是「防誤處理」，不是存取控制。** 共用工作區裡任何 agent 都能讀寫所有 inbox，
所以它擋不住惡意或有 bug 的一方，只能避免兩組互相誤觸。

**真的要隔離**，得把目錄結構改成 `inbox/pairs/<pair-id>/to/<agent>/`。現在並不是這樣，
所以不要以為「有 `pair` 就安全」。

另外，多組並存時的另一個問題——配號撞號——已經被 v0.5 的 ULID **在結構上消滅**（→ §A）。
剩下的只有「收件匣共用」。

---

## §F frontmatter 的 YAML —— 永遠修不掉的訊息

最常見的陷阱是 plain 值裡出現 `": "`：

```yaml
refs: branch x; reply_to: 01M0…      # ← 不是合法 YAML
```

**在 envelope gate 出現之前，collab-bus 的實際使用中已經 publish 了 13 則這種訊息，而且永遠
修不掉**——訊息一旦 publish 就不可變（no-replace link，→ §A）。

因為這個事故，`publish.sh` 才會自動呼叫 `check-envelope.sh`。**覺得「太慢」而拿掉這個自動
呼叫，同樣的事會再發生，而且一樣修不掉。**

規則：human 欄位（`subject`/`refs`，將來的 `note`/`alias`）用單引號、內部單引號寫兩次
（`'it''s'`）、**不可換行**。machine 欄位（`id`/`from`/`to`/`type`/`status`/`pair`/
`reply_to`）**不加引號**（加了 validator 會判為格式錯誤）。
`"$BIN/fm-quote.sh" <文字>` 會產生合規的值。
