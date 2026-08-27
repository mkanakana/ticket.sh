# Work Notes for 260826-184956-note-checklist-check

## 経緯

issue #3 は自分で立てたもの。実装側と突き合わせて 6 点の穴を洗い出し、issue のスレッドで
全部合意を取ってから着手した。合意内容は ticket.md の「着手前に確定させた判断」に転記済み。

スレッドで報告元から追加された実質的な情報は 2 つ:

1. **コードフェンス除外の実測**。要望元プロジェクトの進行中 note で、チェックボックス行
   28 のうち 4 行がフェンス内（note の中でテンプレートを引用した箇所）。除外しないと
   その ticket は初日から close できない。
2. **グループ名のフォールバックは `(ungrouped)`**。note の H1 は
   `Work Notes: <ticket名>` のような題で、グループ名としての意味を持たないため流用しない。

## 4 スペース字下げの扱い（自分から追加で指摘した点）

報告元は「フェンスは ``` と ~~~ の両方、および 4 スペース字下げのコードブロックが対象」
と書いてきたが、これを一律に適用すると壊れる。

CommonMark では、リストの中の 4 スペース字下げは**コードブロックではなくリスト項目の継続**。

```
- [ ] parent
    - [ ] child        ← コードではなくネストしたチェックボックス
```

字下げを一律コード扱いすると、ネストしたチェックボックスが検査対象から静かに消える。
「消せば通る」を塞ぐための機能で、字下げするだけで消せるのは本末転倒だし、消えたことに
気づく手段が無い。

実装した規則: **4 スペース字下げは、リスト文脈にいないときだけコードとみなす**。
リスト文脈は「リスト項目を見てから、インデント 0 の非リスト行に当たるまで」で追う。
フェンス（``` / ~~~）はリスト文脈にいるときインデント不問で開けるようにした。
リスト項目の content column に合わせて字下げされたフェンスが普通にあるため。

## 実装

新規 `lib/note-checklist.sh`。build.sh に inline 対象として追加し、src/ticket.sh の
source ブロック両系統（ローカル / production パス）に足した。

| 関数 | 役割 |
|---|---|
| `note_checklist_scan` | 1 行 1 レコードで `state<TAB>group<TAB>label` を吐く |
| `note_checklist_aggregate` | グループ単位に集計（Bash 3.2 なので連想配列は使わず並列の添字配列） |
| `note_checklist_report` | `check` 用。落ちない |
| `note_checklist_require` | `check --require` 用 |
| `note_checklist_gate` | `close` の preflight 用 |

パーサは全部パラメータ展開で、1 行あたりのプロセス起動はゼロ。
`260807-145646-speed-up-yaml-parse` で yaml_parse が 1 行 4 プロセス起動していて list が
100 チケットで 7 秒かかった件があるので、最初からそう書いた。

呼び出し側:

- `cmd_check` — 引数を取らない関数だったので `--require` の parse を新規追加し、
  dispatch も `cmd_check` → `shift; cmd_check "$@"` に変更。ticket が実際に link されて
  いる成功パス 3 箇所で `checklist_ticket` を立て、関数末尾でまとめて判定する形にした。
- `cmd_close` — `require_note_checklist` を他の config 値と一緒に読み、`--dry-run` の
  脱出より前に gate を置いた。これで `--dry-run` でも検出される。

note ファイルの解決は `ticket_file` から直接導出（`.../ticket.md` → 同階層の `note.md`、
レガシーは `<name>.md` → `<name>-note.md`）。`get_note_file` は ticket 名と tickets_dir を
要求するが cmd_close はどちらも持っていないため。`cmd_check` の側は `get_note_file` を使用。

## 挙動の確認（自分のリポジトリではなく scratch repo で）

- `check` はチェックリストが空でも exit 0、報告のみ
- `check --require "<存在するグループ>"` は未記入で exit 1、全部済み/skip で exit 0
- `check --require "<タイポ>"` は exit 1 + 実在するグループ名を列挙
- `close` は未記入で exit 1、`Nothing was closed.`、ブランチも ticket も動かない
- `close --force` / `close --dry-run` でも止まる
- `require_note_checklist` が false / キー自体が無い場合は素通り
- note ファイルが無い ticket、チェックボックスが 0 個の note も素通り
- レガシー flat レイアウト（`tickets/<name>-note.md`）も判定される

## テスト

`test/test-note-checklist.sh`（51 assertion）。前半はパーサ単体、後半は scratch repo を
作っての結合。

**Docker で 21 失敗** → 原因はテストヘルパーで `python3` を使っていたこと。
コンテナ（Ubuntu 22.04 / Alpine 両方）に python3 が無い。config 書き換えを awk、
note の 1 行書き換えを `sed_i` に置き換えて解消。他のスイートは最初から 0 fail だった。

**negative control**: `src/ticket.sh` と `build.sh` を HEAD に戻して rebuild し、
テストを再実行 → **51 中 27 失敗**。落ちたのは結合セクション（3〜9）全部。
`lib/note-checklist.sh` は新規追加ファイルなので残っており、パーサ単体（1〜2）は通る。
セクション 10（note ファイルが無い ticket は close できる）は旧コードでも通るが、
これは回帰よけとして意図的に残した。

その後 backup から復元して再実行、51/51。

| スイート | 結果 |
|---|---|
| `test/test-note-checklist.sh` | 51 / 51 |
| `test/run-all.sh` | 347 / 347、exit 0 |
| `test/run-all-on-docker.sh` (Ubuntu 22.04) | 328 / 328 |
| `test/run-all-on-docker.sh` (Alpine) | 328 / 328、exit 0 |

## ドキュメント

- help text — `check` と `close` の項
- `spec.md` / `spec.ja.md` — config キー、Default Settings、Command List、
  新規 `### check [--require ...]` セクション（3 状態・グループ化・コード除外・exit の
  規則・「意図的にやらないこと」）、`close` に preflight の項
- `README.md` / `README.ja.md` — config キーと使用例
- `DEV.md` — Project Structure に lib を追加、Key Design Decisions に 9/10/11 を追加
  （テンプレート照合をやらない理由、リスト内字下げをコード扱いしない理由、
  `--force` で迂回させない理由）、Recent Enhancements に 1 行
- **agent 向け指示文を 2 箇所**（`init` が出す指示と `ticket.sh prompt`）に
  「最後にまとめてではなく、やった時点で埋める」旨を追加。issue #3 の実測が示していた
  のは「手順を守っていない」ではなく「チェックリストを開いていない」なので、
  道具側の検出と対で指示文にも入れておく必要がある。

## 意図的にやらなかったこと

- **既定の note テンプレートへの checkbox 追加**。現在の既定 `note_content` に `- [` は
  0 件で、この機能は `note_content` を自前で書いたプロジェクト専用。
  `require_note_checklist` の既定が false であることと整合させた。
- **テンプレート照合による行削除の検出**。別 issue に切り出す（合意済み）。
- **Setext heading の対応**。`---` の下線と note の水平線が区別できない。
- **`[~]` / `[/]` など語彙外マーカーの解釈**。意味を推測せず無視する。

## issue 対応

- **#4 を作成** — 「note のチェックリストから項目が削除されたことを検出する」。
  v1 から外した理由（テンプレートの時間変化／項目行が書き換えられる前提／削除は
  git diff に残る能動的な行為で優先度が違う）と、解くべき問題として3つの方向
  （start 時点のテンプレートを ticket 側に記録する／安定 ID で照合する／git 履歴と
  突き合わせる）を書いた。どれも #3 本体より重いので着手前に方向を決める。
  https://github.com/masuidrive/ticket.sh/issues/4
- **#3 に返信** — 実装完了の報告と、4 スペース字下げの規則を変えた件。
  https://github.com/masuidrive/ticket.sh/issues/3#issuecomment-5432868782
  #3 は open のまま（実装は入ったが、報告者の確認を待つ）。
