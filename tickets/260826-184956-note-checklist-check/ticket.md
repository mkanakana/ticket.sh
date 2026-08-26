---
priority: 2
base_branch: default  # Override base branch for start/close (default: use default_branch from config)
description: "note のチェックリスト未記入を check / close で検出する（グループは直近の heading、3状態、既定 opt-out）"
created_at: "2026-08-26T18:49:56Z"
started_at: 2026-08-26T18:50:47Z # Do not modify manually
closed_at: null   # Do not modify manually
canceled_at: null # Do not modify manually
---

# Ticket Overview

GitHub issue [#3](https://github.com/masuidrive/ticket.sh/issues/3) への対応。

`ticket.sh` が配った note テンプレートのチェックボックスについて、未記入が残っているかを
判定し、`close` を止められるようにする。

## なぜ

note テンプレートにチェックリストを置いても、埋まったかを誰も見ていない。報告元プロジェクトの
実測（作業記録 264 件、うちチェックリストを持つ 231 件）:

| | 件数 |
|---|---|
| 全部チェック済み | 59 |
| 一部だけ | 54 |
| **1 つもチェックなし** | **118** |
| 項目単位 | 記入 1289 / 全 2844 = **45%** |

手順を守っていないのではなく、チェックリストを開いていない。雛形を配っているのは `ticket.sh`
なので、埋まったかを見られるのは `ticket.sh` だけ。

## 仕様

### グループは「直近の heading」

チェックボックスは、その行より前にある最も近い heading（レベル不問）に属する。グループ名は
heading の文字列そのもの。`ticket.sh` はグループの意味を知らなくてよい。

### チェックボックスは 3 状態

| 記法 | 意味 | 判定 |
|---|---|---|
| `- [x] …` | 済み | 通す |
| `- [ ] …` | 未記入 | 止める |
| `- [-] … — skip: <理由>` | 該当しない | 理由があれば通す。無ければ未記入扱い |

集計では skip は分子に数える（`4 / 4  done (1 skipped)`）。

### 3 つの入口

| 呼び方 | 何を見る | exit |
|---|---|---|
| `ticket.sh check` | 全グループの状態を報告 | 0 |
| `ticket.sh check --require "<グループ名>"` | そのグループだけ判定 | 未記入なら 1 |
| `ticket.sh close` の preflight | 全グループ | 未記入なら 1（close しない） |

`check` を落とさないのは、作業の途中では後段のグループが空なのが正常だから。`--require` は
呼ぶ側が「いまどの段階か」を知っている場合に使う。グループ名を文字列で渡すだけなので、
`ticket.sh` 側に段階の概念は要らない。

### 設定で opt-in

```yaml
require_note_checklist: false  # 既定。true にすると close の preflight で判定する
```

既定を false にする。既存プロジェクトの note には未記入が大量に残っているため。

### 出力

ツール自身が出す語は英語。グループ名だけは note の heading の文字列なのでそのまま出る。
出力書式は issue #3 の例に従う。

## 着手前に確定させた判断（issue #3 のスレッドで合意済み）

1. **既定の note テンプレートに checkbox は追加しない。** 現在の既定 `note_content` に
   `- [` は 0 件で、この機能は `note_content` を自前で書いたプロジェクト専用になる。
   `require_note_checklist` の既定が false であることと整合させる。

2. **テンプレート照合による「行削除」の検出はやらない。別 issue に切り出す。** 理由:
   - config の `note_content` は *今の* テンプレート。先に start した ticket は *古い*
     テンプレートで note を作っている。テンプレに1行足すと進行中の全 ticket が「消した」判定になる。
   - 照合は文字列一致にならざるを得ないが、項目行は書き換えられる前提。issue #3 の例自体が
     `- [x] full test suite passed — a1b2c3d` と証跡を足している。`— skip: <理由>` を
     付けた時点でも行は変わる。
   - 「削除」は `git diff` に残る能動的な行為、「未チェック」は何もしなくても起きる受動的な穴。
     実測 118 件が該当するのは後者だけ。
   - issue #3 の出力例が要求している情報は note のスキャンだけで全部出る。

3. **コードフェンス内のチェックボックスは無視する。** 報告元の進行中 note で実測: 28 行中
   4 行がフェンス内（note 中でテンプレートを引用した箇所）。除外しないとその ticket は
   初日から close できない。
   - ``` と `~~~` の両方を対象にする。
   - **4 スペース字下げは、リスト文脈にいないときだけ**コードとみなす。CommonMark では
     リスト内の 4 スペース字下げはコードブロックではなくリスト項目の継続であり、一律に
     コード扱いするとネストしたチェックボックスが静かに検査対象から消える。「消せば通る」を
     塞ぐ機能で字下げすれば消せるのは本末転倒。

4. **`--require "X"` の X が note に無いときは落とす。** 通すと、タイポした `--require` が
   「常に成功する no-op」になり、呼ぶ側は守っているつもりで何も検査していない状態になる。

5. **`--force` はチェックリストを迂回させない。** 迂回路は `- [-] … — skip: <理由>` の側で、
   そちらは理由が note に残る。`--force` は git の状態の話なので意味を混ぜない。

6. 細部:
   - `— skip:` の em-dash は必須にしない。`[-]` の行に非空の `skip:` があれば通す。
   - heading より前にあるチェックボックスのグループ名は `(ungrouped)`。
   - `note_content` 未定義で note ファイルが無い ticket は素通り（no-op で pass）。

## `ticket.sh` が知らなくてよいこと（意図的に外す）

- どの段階でどのグループを要求するか — `--require` に文字列で渡してもらう
- チェックが古くなったかの判定（テストは通ったがその後コードを直した、等）
- チェック項目の意味

## 互換性

- 旧形式（1 つの heading の下に全項目）でも動く。全部が 1 グループになるだけ
- `require_note_checklist` の既定が false なので既存プロジェクトの挙動は変わらない
- `[-]` を使っていない既存 note は `[x]` と `[ ]` だけで従来どおり判定される
- レガシー flat レイアウト（`tickets/<NAME>-note.md`）でも動くこと

## 想定する実装箇所

`cmd_check`（src/ticket.sh:2125）と `cmd_close` の preflight（〜:2695、`--dry-run` が
走らせている部分）に足す。`cmd_check` は現状引数を一切取らないので `--require` の parse は新規。


## Tasks

- [ ] note のチェックリストを解析する関数を書く（heading グループ化、3 状態、コードフェンス除外）
- [ ] コードフェンス除外: ``` / `~~~` / リスト文脈でない 4 スペース字下げ
- [ ] `(ungrouped)` フォールバック
- [ ] `require_note_checklist` を config に追加（既定 false、`init` が生成する config にも）
- [ ] `cmd_check` に報告出力を追加（exit 0 のまま）
- [ ] `cmd_check --require "<group>"` の引数 parse と判定（グループ不在なら 1）
- [ ] `cmd_close` の preflight に判定を追加（`--dry-run` でも走る、`--force` で迂回させない）
- [ ] note ファイルの解決（新レイアウト / レガシー flat / note 無しは no-op pass）
- [ ] テストを書く（`test/test-note-checklist.sh`）
- [ ] 旧実装に戻すとテストが落ちることを確認する（negative control）
- [ ] Run tests before closing and pass all tests (No exceptions)
- [ ] Run `bash build.sh` to build the project
- [ ] Update documentation if necessary
  - [ ] Update README.*.md
  - [ ] Update spec.*.md
  - [ ] Update DEV.md
  - [ ] help text（`check` と `close` の項）
- [ ] 「テンプレート照合による行削除の検出」を新規 issue として切り出す
- [ ] issue #3 に 4 スペース字下げの判断を返信する
- [ ] Get developer approval before closing
