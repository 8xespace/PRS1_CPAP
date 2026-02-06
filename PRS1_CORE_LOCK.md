# PRS1 Core Lock（架構上鎖）

這份專案的 PRS1 讀取核心與統計引擎（Reader/Parser/Aggregator/Stats/Waveform index）
已進入「穩定期」。為避免未來不小心重構導致解析壞掉，本專案加入 **Core Lock 機制**：

## 什麼被上鎖？
`lib/features/prs1/` 下的核心模組（含 binary/decode/aggregate/stats/waveform index）
都會被 guard 工具檢查 SHA256 指紋。

## 什麼時候會擋下來？
- 你/別人改動了核心檔案（哪怕只是格式化）
- 但忘了更新 manifest
- 在 CI 或 pre-commit 會直接失敗，避免「不小心就推上去」造成回歸

## 怎麼檢查？
```bash
dart run tool/prs1_core_guard.dart
```

## 真的需要改核心怎麼辦？
1) **先加測試**（建議把你那張 SD 樣本抽出 1~2 個 night 當 golden）
2) 修改核心檔案
3) 更新 manifest：
```bash
dart run tool/prs1_core_guard.dart --update
```
4) 提交（commit）並在 PR 說明「為何必須動核心」

## 建議的 Git 保護（強烈建議）
- 在 GitHub 開啟 branch protection（main 不允許直接 push）
- PR 必須通過 CI（包含 `prs1_core_guard`）
- `lib/features/prs1/**` 設 CODEOWNERS（必須 reviewer）
