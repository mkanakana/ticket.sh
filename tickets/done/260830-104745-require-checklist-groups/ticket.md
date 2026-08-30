---
priority: 2
base_branch: default  # Override base branch for start/close (default: use default_branch from config)
description: "require_checklist_groups: 存在しなければならない見出しを close で強制する (gh #5)"
created_at: "2026-08-30T10:47:45Z"
started_at: 2026-08-30T10:48:31Z # Do not modify manually
closed_at: 2026-08-30T14:41:29Z # Do not modify manually
canceled_at: null # Do not modify manually
---

# Ticket Overview

GitHub issue #5 の対応。

`require_checklist: true` は**未了の checkbox を数える**実装なので、**節が丸ごと無い**（あるいは見出しは残っていて中身の checkbox が全部消えている）と数える対象がゼロになり、「全部片付いた」と区別がつかず close が通る。同じ状況を `check --require "<見出し>"` は落とす。**同じ穴に対して片方は落ち、片方は通る。**

根拠（コード）:

- `lib/checklist.sh` の `checklist_gate` は冒頭が `[[ $CL_SUM_TODO -eq 0 ]] && return 0`
- `checklist_aggregate` は checkbox を見つけた時点で初めてグループを登録するので、checkbox が 0 個の見出しはそもそもグループとして存在しない
- 対して `checklist_require` は `matched=0` を明示的に失敗にしている（「typo が常に成功する検査になるのを防ぐ」とコメント済み）

主に救うのは「破ろうとした人」ではなく、**テンプレより前に作られた ticket / 手書き ticket / 別テンプレから移行した ticket**。利用者は `require_checklist: true` で守られているつもりなのに、その ticket に対しては何も検査しておらず、**検査していないことが出力に一切現れない**。

## #4 (not planned) との関係

#4「削除の検出」は却下済みだが、本件は別物として扱う。

|                              | #4（却下済み）                     | 本件                                  |
| ---------------------------- | ---------------------------------- | ------------------------------------- |
| 期待の出どころ               | note テンプレートから**自動導出**  | config に**明示宣言**                 |
| 粒度                         | 項目行                             | 見出し                                |
| #4却下理由1「テンプレは時間変化する」 | 直撃する                  | **効かない**（明示宣言・見出しは滅多に変わらない） |
| #4却下理由2「行は書き換えられる前提」 | 直撃する                  | **効かない**（行本文を照合しない）    |

#4 の決め手だった「削除もでたらめな skip も、同じ *通すための書き換え* だ」も本件には部分的にしか刺さらない。本件が主に救うのは書き換えですらないケースである。

## 設計判断（決定済み）

1. **`require_checklist: false` でも宣言グループは効く。** キー自体が opt-in なので bool 側に従属させない。
2. **宣言グループは「存在」だけでなく「完了」まで見る。** 既存 `checklist_require` の意味（存在 AND 未了ゼロ）に揃える。
3. **plain `check` は落とさない。** 宣言グループの欠落は表示するが exit 0 のまま。落とすのは `close` だけ（`check` が mid-ticket で落ちると機能ごと切られる、という #3 の判断を維持）。`check --require` は従来どおり落ちる。
4. **`start` 時の警告は入れない。** 今回のスコープ外。

## 実装メモ

- config キー名: `require_checklist_groups`（既存 `require_checklist` と並ぶ名前）
- yaml-sh はリストに対応済み（`yaml_list_size <prefix>` + `yaml_get <prefix>.<N>`）
- ⚠ **リスト要素のクォートが除去されない。** 実測:
  - `- "Required Probes"` → `"Required Probes"`（クォート込み）
  - `- Required Probes` → `Required Probes`
  - `- 'Single quoted'` → `'Single quoted'`
  見出し文字列と完全一致比較するので、**前後の対になるクォートを実装側で剥がす**こと。剥がさないと issue 本文の書き方（クォート付き）がそのまま動かない。
- 判定は既存 `checklist_require` を流用できるが、close の preflight は他のゲートと同じく **stderr** に出す必要がある
- close 側の差し込み位置: `src/ticket.sh` の `require_checklist` ブロックの隣（`checklist_gate` 呼び出しの後ろ）
- `--dry-run` は preflight を通るので自動的に効く。`--force` では抜けない（既存 `require_checklist` と同じ方針）
- `cancel` はゲートしない（従来どおり）

## What / Acceptance Criteria

- [x] `require_checklist_groups` に宣言した見出しが ticket.md / note.md のどちらにも無ければ `close` が拒否する
- [x] 見出しはあるが checkbox が 0 個の場合も同様に拒否する
- [x] 宣言グループに未了 checkbox が残っている場合も拒否する（`require_checklist: false` でも）
- [x] キー未定義／空リストのときは現行と完全に同一の挙動（後方互換）
- [x] YAML のクォート付き・無し（`"..."` / `'...'` / 素）いずれの記法でも同じ見出しにマッチする
- [x] 同じ見出しが ticket.md と note.md の両方にある場合は両方を合算して判定する（`checklist_require` と同じ）
- [x] `--force` で迂回できない
- [x] `--dry-run` で拒否が見える
- [x] plain `./ticket.sh check` は宣言グループの欠落を表示するが exit 0 のまま
- [x] 拒否メッセージは「どの見出しが無いか」と「どのグループが実在するか」を出す（`check --require` と同じ体裁）

## Tasks

- [x] `lib/checklist.sh` に宣言グループ判定を追加（`checklist_require` 流用 + stderr 出力）
- [x] `src/ticket.sh` の close preflight に組み込む
- [x] config リスト読み取りヘルパー（クォート剥がし込み）
- [x] `src/ticket.sh` の config テンプレートにキーとコメントを追加
- [x] plain `check` に宣言グループの状態表示を追加
- [x] `test/test-checklist.sh` にケース追加（AC の各項目に対応）
- [x] Run tests before closing and pass all tests (No exceptions)
- [x] Run `bash build.sh` to build the project
- [x] Update documentation if necessary
  - [x] Update README.*.md
  - [x] Update spec.*.md
  - [x] Update DEV.md
- [x] Get developer approval before closing
