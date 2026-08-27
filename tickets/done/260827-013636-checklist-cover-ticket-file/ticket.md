---
priority: 2
base_branch: default  # Override base branch for start/close (default: use default_branch from config)
description: "チェックリストの検査対象に ticket.md を加え、ファイル別に報告する。config キーを require_checklist に改名"
created_at: "2026-08-27T01:36:36Z"
started_at: 2026-08-27T01:37:03Z # Do not modify manually
closed_at: 2026-08-27T02:30:25Z # Do not modify manually
canceled_at: null # Do not modify manually
---

# Ticket Overview

`260826-184956-note-checklist-check`（issue #3）で入れたチェックリスト検査は note.md しか
見ていない。**本命である ticket.md の `## Tasks` が検査されていない。**

既定のチケットテンプレートには最初から 9 個のチェックボックスがある
（`- [ ] Task 1`、`Run tests before closing and pass all tests`、
`Get developer approval before closing` など）。note と違い、**既定の状態で既に
チェックリストが存在する**。埋まったかを見られていないのはこちらも同じ。

## 決定事項（ユーザ確認済み）

### 1. 検査対象に ticket.md を加える

ticket.md は YAML frontmatter を持つので、**frontmatter を落としてから**スキャンする。
落とさないと `description` の block scalar 内の `- [ ]` を拾う。

### 2. レポートはファイルごとに分ける

同じ見出し（例: どちらにも `## Tasks`）があっても**別グループとして扱う**。
どこを直せばよいかが出力から分かるため。

```
Checklist: 6 / 16
  ticket.md
    Tasks                 2 / 9
        - Task 1
        - Run tests before closing
  note.md
    Implementation log    4 / 4  done (1 skipped)
    Review                0 / 1
        - findings resolved
```

### 3. `--require` はファイル名なしの見出し名で、両方にまたがって判定

呼ぶ側にファイルの区別を持たせない。`--require "Tasks"` は、両方のファイルの
`## Tasks` を合わせて判定する。

### 4. config キーを `require_checklist` に改名し、`require_note_checklist` は削除

note 限定ではなくなるため。**互換エイリアスは残さない。**

ただし、古いキーを黙って無視すると `require_note_checklist: true` にしていた設定の
gate が静かに外れる。「置いてあるが誰も見ない」を潰すための機能でそれは筋が悪いので、
**config に `require_note_checklist` が残っていたらエラーで止め、改名を促す。**
互換維持のためではなく、無音の無効化を防ぐため。

### 5. 名前の整理

note 専用ではなくなるので、以下を改名する。#3 のリリースから日が浅く、外部利用者は
いない想定。

| 旧 | 新 |
|---|---|
| `lib/note-checklist.sh` | `lib/checklist.sh` |
| `note_checklist_*()` | `checklist_*()` |
| `test/test-note-checklist.sh` | `test/test-checklist.sh` |

## 影響

- `check` の出力が**全プロジェクトで変わる**（既定テンプレートにチェックボックスが
  あるため）。ただし報告のみで exit 0 なので実害は無い。
- `close` は `require_checklist` が true のときだけ止まる。既定は false のまま。

## 追加で入れたもの（作業中のユーザ指示）

`yaml-sh/yaml-sh` を削除し、`yaml-sh/README.md` を直す。別チケットにはしない。

調査の結果、この古いコピーは `yaml-sh/test.sh` を当てると **27 中 2 しか通らない**、
つまり壊れていた。「オリジナル」ではなく、`yaml-sh.sh` と同じコミット `631d8d4` で
同一内容として生まれ、直後から `.sh` だけが修正を受け続けた双子だった。

README の導入手順も現物と合っていなかった:

- curl URL が `raw.githubusercontent.com/**yourusername**/yaml-sh/main/yaml-sh`
  というプレースホルダのまま（実在しない）
- `chmod +x` を案内しているが、source して使うライブラリで実行属性は不要
- `source yaml-sh` が 4 箇所（正しくは `yaml-sh.sh`）
- `cd ticket-sh` / `ticket-sh/README.md` / `./test-final.sh` など、
  プロジェクト再編前のパスが残存

## 想定する実装箇所

- `lib/note-checklist.sh` → `lib/checklist.sh`（frontmatter スキップ、レコードに
  ファイル名を追加、集計をファイル別に）
- `build.sh` の inline 対象名
- `src/ticket.sh` の source ブロック、`cmd_check`、`cmd_close` の preflight、
  config テンプレート、help text


## Tasks

- [x] スキャンで YAML frontmatter を飛ばす（1行目が `---` のとき）
- [x] レコードにファイル名を持たせ、複数ファイルを走査できるようにする
- [x] 集計・レポートをファイル別の入れ子にする
- [x] `--require` は見出し名でファイルをまたいで判定する
- [x] gate の出力もファイル別にする
- [x] config キーを `require_checklist` に改名
- [x] 古い `require_note_checklist` が残っていたらエラーで止める
- [x] `lib/checklist.sh` / `checklist_*()` / `test/test-checklist.sh` に改名
- [x] テストを更新・追加（ticket.md 側、frontmatter、ファイル別出力、キー改名）
- [x] 旧実装に戻すとテストが落ちることを確認する（negative control）
- [x] Run tests before closing and pass all tests (No exceptions)
- [x] Run `bash build.sh` to build the project
- [x] Update documentation if necessary
  - [x] Update README.*.md
  - [x] Update spec.*.md
  - [x] Update DEV.md
  - [x] help text（`check` と `close` の項）
- [x] `yaml-sh/yaml-sh`（実体から取り残された壊れたコピー）を削除する
- [x] `yaml-sh/README.md` の導入手順・パス・テスト手順を現物に合わせる
- [x] Get developer approval before closing
