# Work Notes for 260827-013636-checklist-cover-ticket-file

## 経緯

`260826-184956-note-checklist-check`（issue #3）でチェックリスト検査を入れたが、note.md しか
見ていなかった。本命は ticket.md の `## Tasks` のほうで、しかも**既定のチケットテンプレートには
最初から 9 個のチェックボックスがある**（note の既定テンプレートには 0 個）。

判断は着手前にユーザ確認済み。ticket.md の「決定事項」に転記した。

## 実装

`lib/note-checklist.sh` → `lib/checklist.sh`、`note_checklist_*()` → `checklist_*()`、
`test/test-note-checklist.sh` → `test/test-checklist.sh` に改名。note 専用ではなくなったため。

レコード形式を `state<TAB>group<TAB>label` から **`state<TAB>file<TAB>group<TAB>label`** に変更。
グループの同一性は **(ファイル, 見出し)** の組で判定するので、両方に `## Review` があっても
別グループのまま残る。`--require` だけは見出し名のみで照合し、両方のファイルにまたがって判定する。

ticket.md は frontmatter を持つので `extract_markdown_body` を通してからスキャンする。
note.md はそのまま読む。note を stripper に通すと、1行目の水平線を frontmatter の開始と
誤認する危険があるため、`checklist_scan` の第3引数で明示的に切り替える形にした。

config キーは `require_note_checklist` → `require_checklist` に改名し、旧キーは削除。

## `extract_markdown_body` の潜在バグ（今回の主要な発見）

**Docker で 19 failure。ticket.md 側だけが一切スキャンされない。** ローカル（macOS bash 3.2）
では 0 failure。

原因は `lib/yaml-frontmatter.sh` の `((line_num++))`。**post-increment は「古い値」を返す**ので、
0 からの最初のインクリメントで算術コマンドの終了ステータスが **1** になる。`set -e` 下では
そこでシェルが死ぬ。

コンテナ内で切り分けた結果:

| ケース | 結果 |
|---|---|
| A. `set -e` なし + process substitution | 動く |
| B. `set -e` あり + process substitution | **空** |
| C. `set -e` あり + `printf` の process substitution | 動く（procsub 自体は無罪） |
| D. `set -e` あり + 明示的なサブシェル `( ... )` | **空** |

`close` は `local x=$(extract_markdown_body ...)` の command substitution 経由なので生き延びて
いて、今まで露見していなかった。**既存の潜在バグ**であり、今回の呼び出し方
（process substitution）で初めて表に出た。

`n=$((n + 1))` に置き換えて修正。`lib/yaml-frontmatter.sh` の 4 箇所と、同じクラスだった
`src/ticket.sh` の 3 箇所（`displayed++` / `line_num++`）も直した。

### 残っている同種の箇所（今回は触っていない）

`yaml-sh/yaml-sh` に `((list_index++))` / `((i++))` が 9 箇所ある。同じクラスだが、
yaml-sh は独自のテストスイート（27 件）を持つ別ライブラリで、実運用で問題が出ていない
（0 始まりでないか、`set -e` が効かない文脈にあるはず）。**スコープ外として報告のみ。**
別チケットで確認する価値はある。

## テスト

`test/test-checklist.sh`（69 assertion）。旧 51 から 18 追加。

追加したもの: ticket.md のスキャン、frontmatter の除外、`set -e` サブシェルでの
`extract_markdown_body` の回帰テスト、ファイル別レポート、両ファイルにまたがる `--require`、
「note だけ埋めても ticket.md が残っていれば止まる」、既定テンプレートの `## Tasks` が
拾われること、config キー改名（旧キー true はエラー / false は警告のみ）、
レガシー flat レイアウトの2ファイル。

**Docker のテストヘルパーに `python3` は使わない**（コンテナに入っていない）。config 書き換えは
awk、行の書き換えは `sed_i`。前回それで 21 failure を出したので今回は最初から避けた。

### negative control（2種類）

| 戻したもの | 結果 |
|---|---|
| `checklist_aggregate` から ticket.md のスキャンを外す | 69 中 **27 失敗** |
| `extract_markdown_body` の `((line_num++))` を戻す（macOS） | 69 中 **0 失敗** |
| 同上（Docker / Ubuntu 22.04） | 69 中 **15 失敗** |

2つ目が重要。**この修正はローカルの macOS bash 3.2 では検出できず、Linux / bash 5.x でしか
落ちない。** 追加した回帰テストが実際に効くことは Docker 上で確認した。
`run-all-on-docker.sh` を通す意味がそのまま出た事例。

### 最終結果

| スイート | 結果 |
|---|---|
| `test/test-checklist.sh` | 69 / 69 |
| `test/run-all.sh` | 365 / 365、exit 0 |
| Docker (Ubuntu 22.04) | 346 / 346 |
| Docker (Alpine) | 346 / 346、exit 0 |

## 旧 config キーを黙って無視しない

`require_note_checklist: true` を残したまま黙って無視すると、有効にしていた gate が
**無言で外れる**。「置いてあるが誰も見ない」を潰すための機能でそれをやるのは筋が悪いので、
**旧キーが `true` ならエラーで止め、改名を促す。`false` なら警告のみ**（何も無効化されて
いないので）。互換維持のためではない。

## ドキュメント

- help text — `check` と `close` の項
- `spec.md` / `spec.ja.md` — config キー名、Command List、`check` セクションを2ファイル
  対応に書き換え（対象ファイルの表、frontmatter を飛ばす理由、`--require` がファイルを
  またぐ理由、出力例）、`close` の preflight に旧キーの扱い
- `README.md` / `README.ja.md` — config キーと使用例
- `DEV.md` — Project Structure、Key Design Decisions 9 と 11 を更新、12（旧キーを黙って
  無視しない）を追加、Recent Enhancements
- agent 向け指示文2箇所 — 「ticket.md と note.md の両方」に更新

## 追加作業: `yaml-sh/yaml-sh` の削除と README 修正

作業中のユーザ指示で、別チケットにせずここに入れた（一度 `260827-021340-yaml-sh-duplicate-copy`
を作ったが、指示により取り下げてこちらに統合）。

### この2ファイルの関係（調査結果）

「片方がオリジナルで片方が修正版」ではない。**同じコミットで、同一内容として生まれている。**

| 時点 | 何が起きたか |
|---|---|
| 2025-06-29 `631d8d4` "wip" | `yaml-sh` と `yaml-sh.sh` が**同一内容**で追加される |
| 同日 `9e9b4f3` / `a9672e4` | dash 記法のリスト解析修正、process substitution 修正 → **`.sh` だけ** |
| 2025-07-16 `f06740d` | **最後に両方を触ったコミット。** この時点で既に 115 行差 |
| 2025-07-18 `c0ae61a` | inline list hang 修正 → `.sh` だけ |
| 2025-08-23 `0447cfd` | CRLF 対応 → `.sh` だけ |
| 2026-08-08 `ce2c796` | 性能修正 → `.sh` だけ |
| 2026-08-10 `ca1e10c` | zsh 対策（`local` のループ外移動）→ `.sh` だけ |

削除時点で 603 行 vs 573 行、差分 172 行。

### 古いコピーに欠けていたもの（実測）

| 項目 | `yaml-sh` | `yaml-sh.sh` |
|---|---|---|
| CRLF 除去 (`\r`) | 0 箇所 | 2 箇所 |
| 1行ごとのサブシェル起動 | **8 箇所残存** | 0 箇所 |
| `local` のループ外宣言 | 無い | ある |
| `((var++))` | **9 箇所** | 0 箇所 |

### 決め手: 動かなかった

`yaml-sh/test.sh` を、同じディレクトリで `yaml-sh.sh` の位置に置き換えながら両方に当てた。

| 対象 | 結果 |
|---|---|
| `yaml-sh.sh`（実体） | **27 / 27 パス** |
| `yaml-sh`（古いコピー） | **2 / 27 パス**。最初の "Parse YAML file" から失敗 |

実体側で 27/27 を確認しているので、ハーネス側の問題ではない。
「古いが動く版」ではなく壊れていた。よって削除で失うものは無い。

なお README の Compatibility Notes には既に
「Bash 5.1+: Fully compatible (fixed arithmetic operation issues with `set -euo pipefail`)」
と書かれていた。まさに `((var++))` のクラスで、`.sh` 側だけが受け取っていた修正である。

### README の修正内容

導入手順が現物と合っていなかった。

- curl URL が `raw.githubusercontent.com/**yourusername**/yaml-sh/main/yaml-sh` という
  **プレースホルダのまま**。実在しないので、この手順で導入できた人はそもそもいない。
  実リポジトリの `masuidrive/ticket.sh/main/yaml-sh/yaml-sh.sh` に差し替え（HTTP 200 を確認）
- `chmod +x` を案内していたが、source して使うライブラリなので実行属性は不要。削除
- `source yaml-sh` を 4 箇所 `source yaml-sh.sh` に
- `cd ticket-sh` / `ticket-sh/README.md` / `./test-final.sh` / `./test-additional.sh` が
  プロジェクト再編（`c3632c5`）前のパスのまま。現在の構成（リポジトリ直下が ticket.sh、
  `test/run-all.sh`）に修正
- 冒頭の「他言語版も更新すること」ヘッダが存在しない `README.ja.md` を指していたので削除

### 発見の経緯

このチケットの `((var++))` 調査で grep したとき両方に当たり、「yaml-sh に 9 箇所ある」と
誤って報告した。実体である `yaml-sh.sh` は 0 箇所。二重管理が続く限り同じ誤読が起きる、
という点自体が削除の動機の一つになった。
