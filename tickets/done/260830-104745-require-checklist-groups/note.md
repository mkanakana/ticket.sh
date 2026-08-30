# Work Notes for 260830-104745-require-checklist-groups

## Implementation Details

...

## Task 1

...

## Task N

...


## Reviewer note #N

...

## 調査: 何が起きていたか

`lib/checklist.sh` を読んで確認した。issue #5 の指摘は正確で、しかも**穴は報告より1つ広い**。

- `checklist_gate` の冒頭が `[[ $CL_SUM_TODO -eq 0 ]] && return 0` — 未了カウントがゼロなら通す
- `checklist_aggregate` は **checkbox を見つけた時点で初めてグループを登録する**

この2つの帰結として、close をすり抜けるのは「節を丸ごと消した」だけではない：

1. 節ごと無い → グループ未登録 → 未了 0 → 通る（issue の報告どおり）
2. **見出しは残っていて、その下の checkbox が全部消えている** → 同じくグループ未登録 → 通る

2 も同じ扱いにした。読む側から見れば「判定される中身が無い」という点で 1 と変わらない。

対する `checklist_require`（`check --require`）は `matched=0` を明示的に失敗にしている。
コメントに理由も書かれている（「typo が常に成功する検査になるのを防ぐ」）。
つまり **同じ思想が close 側だけ抜けていた**、というのが正体。

## 実装

### lib/checklist.sh

- `_checklist_group_eval <name>` を切り出した。`checklist_require` の中にあった
  「名前でグループを引いて合算する」ループそのもの。結果は `CLG_*` に置く。
- `_checklist_print_groups` も切り出した（「実在するグループ一覧」の出力）。
- `checklist_require` はこの2つを使う形に書き換えた。**出力は1文字も変えていない**
  （既存テストがそのまま通ることで確認）。
- `checklist_require_groups <ticket> <note> <name>...` を追加。close 用。
  成功時は何も出さず、失敗時のみ出す。stdout に書き、close 側で `>&2` する。
- `checklist_report_groups <ticket> <note> <name>...` を追加。`check` 用。常に 0。

### src/ticket.sh

- `_config_unquote` / `config_read_list <key>` を追加（結果は `CONFIG_LIST[]`）。
- close / check の両方で、**config を parse した直後**に `config_read_list` を呼ぶ。
  この位置は必須：どちらの関数も後段で ticket の frontmatter を同じ yaml-sh の
  グローバルに parse し直すので、後から読むと config が消えている。
- close の preflight は「宣言グループ → 全体 gate」の順。理由はコメントに書いた
  （節が無いことの方が基本的な答えで、先に未記入一覧を見せると二度手間になる）。
- `_close_note_file` の算出を `if require_checklist` の外に出した（両方が使うため）。

## 落とし穴 2つ

### 1. yaml-sh はリスト要素のクォートを剥がさない（dash 記法のみ）

実測:

```
- "Required Probes"   → ["Required Probes"]   ← クォート込みで返る
- Required Probes     → [Required Probes]
- 'Single quoted'     → ['Single quoted']
["A B", "C/D"]        → [A B] [C/D]           ← inline list は剥がれる
```

dash 記法と inline 記法で挙動が違う。剥がさないまま見出しと比較すると
**絶対に一致しない = 常に失敗する検査**になり、塞ごうとしている穴の裏返しになる。
`_config_unquote` で対になっているクォート1組だけ剥がす。yaml-sh 側は触っていない
（他の利用箇所への影響が読めないため。必要なら別チケット）。

### 2. bash 3.2 + `set -u` で空配列の展開がエラー

```
$ /bin/bash -c 'set -u; a=(); echo "${a[@]}"'
a[@]: unbound variable
```

`${#a[@]}` は 0 を返して問題ない。展開だけが落ちる。
呼び出し側は `${_required_groups[@]+"${_required_groups[@]}"}` で守る。
macOS の /bin/bash が 3.2.57 なので、これは実環境で踏む。

## 決めたこと（ticket 本文の「設計判断」どおり）

1. `require_checklist: false` でも宣言グループは効く → **効く**ようにした。テスト 13 は
   gate を off にしたまま全ケースを通している。
2. 宣言グループは存在だけでなく完了まで見る → **見る**。
3. plain `check` は落とさない → 落とさない。`missing  (close will refuse)` と表示のみ。
4. `start` 時の警告は入れない → 入れていない。

## テスト

`test/test-checklist.sh` に section 13〜15 を追加（19 ケース）。

- 13: 節ごと無い / 見出しだけあって中身が無い / 未記入が残っている / 片付いた、
  および `--force` で抜けないこと・`check` が exit 0 のままであること
- 14: YAML の書き方 5種（素・"…"・'…'・inline・スカラー）が全部同じ見出しに当たること、
  および ticket.md 側のグループも見つかること
- 15: 空リスト = 現行どおり、宣言なしなら `check` に "Required groups" が出ないこと、
  gate と併用したとき欠落が先に報告されること

結果:

```
test/run-all.sh           382 passed / 0 failed
test/run-all-on-docker.sh 363 passed / 0 failed
```

（checklist スイート単体は 86 passed / 0 failed。追加前は 67）

## ドキュメント

`src/ticket.sh` のヘルプ・config テンプレート、README.md / README.ja.md、
spec.md / spec.ja.md、DEV.md を更新。

## 残したもの

- yaml-sh の dash 記法 / inline 記法でクォート挙動が違う件は、本体を直さず
  呼び出し側で吸収した。直すなら別チケット。
- `start` 時の乖離警告は入れていない（設計判断 4）。
