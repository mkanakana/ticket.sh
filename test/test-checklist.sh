#!/usr/bin/env bash

# Tests for the ticket/note checklist check (issues #3 and the follow-up that
# brought the ticket body in).
#
# Both files a ticket owns can carry checkboxes - the ticket's `## Tasks` list
# and whatever the note template holds - and nothing used to look at whether
# they were filled in. `check` now reports them per file, `check --require
# "<group>"` judges one group across both, and `close` refuses while any are
# unchecked (opt-in via require_checklist).
#
# The parser cases matter as much as the plumbing: these files are full of
# pasted output and quoted templates, so a checkbox inside a code block must not
# count, while a checkbox merely indented under another one must.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo "=== checklist Test Suite ==="
echo

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="${REPO_ROOT}/tmp/test-checklist-$(date +%s)"
mkdir -p "${REPO_ROOT}/tmp"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"

# Always rebuild so the harness runs against current sources.
(cd "$REPO_ROOT" && ./build.sh >/dev/null 2>&1)

PASSED=0
FAILED=0
# Use ✓/✗ marks so run-all.sh's grep-based counter picks them up.
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
pass() { echo -e "  ${GREEN}✓${NC} $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; [[ -n "${2:-}" ]] && echo "    $2"; FAILED=$((FAILED + 1)); }

# checklist_scan strips the ticket's frontmatter through this.
source "${REPO_ROOT}/lib/yaml-frontmatter.sh"
source "${REPO_ROOT}/lib/checklist.sh"

# Build a fresh repo with the ticket system initialized. No remote, so pushing
# is turned off.
# Usage: make_repo <dir-name>  (echoes the absolute path)
make_repo() {
    local name="$1"
    local dir="${TEST_DIR}/${name}"
    rm -rf "$dir"
    mkdir -p "$dir"
    cd "$dir" || return 1

    git init -q -b main
    git config user.name "Test"
    git config user.email "test@test.com"
    echo "# Test" > README.md
    git add README.md
    git commit -q -m "Initial"

    cp "${REPO_ROOT}/ticket.sh" .
    chmod +x ticket.sh
    timeout 10 ./ticket.sh init >/dev/null 2>&1
    sed_i 's/^auto_push: true/auto_push: false/' .ticket-config.yaml
    git add . && git commit -q -m "Init ticket system"

    echo "$dir"
}

# Replace BOTH templates in the config with small known ones, so counts in the
# assertions below do not depend on the stock templates, and optionally turn the
# close gate on. Section 8 covers the stock ticket template separately.
# Usage: set_templates <repo-dir> <gate:true|false>
set_templates() {
    local dir="$1" gate="$2"
    cd "$dir" || return 1
    awk -v gate="$gate" '
        /^note_content: \|/ {
            note = 1
            print "note_content: |"
            print "  # Work Notes for $$TICKET_NAME$$"
            print ""
            print "  ## Implementation log"
            print ""
            print "  - [ ] full test suite passed"
            print "  - [ ] live API call verified"
            print ""
            print "  ## Review"
            print ""
            print "  - [ ] findings resolved"
            print ""
            next
        }
        note && /^# Ticket template/ { note = 0 }
        note { next }
        /^default_content: \|/ {
            body = 1
            print "default_content: |"
            print "  # Ticket Overview"
            print ""
            print "  ## Tasks"
            print ""
            print "  - [ ] write the thing"
            print ""
            print "  ## Review"
            print ""
            print "  - [ ] ticket-side review"
            next
        }
        body { next }
        /^require_checklist:/ { print "require_checklist: " gate; next }
        { print }
    ' .ticket-config.yaml > .ticket-config.yaml.new
    mv .ticket-config.yaml.new .ticket-config.yaml
    git add -A && git commit -q -m "Templates with checklists"
}

# new -> commit -> start -> make a work commit. Echoes the ticket name.
# Usage: begin_ticket <repo-dir> <slug>
begin_ticket() {
    local dir="$1" slug="$2"
    cd "$dir" || return 1
    timeout 5 ./ticket.sh new "$slug" >/dev/null 2>&1
    local ticket
    ticket=$(safe_get_ticket_name "*${slug}*")
    git add tickets && git commit -q -m "Add ticket"
    timeout 10 ./ticket.sh start "$ticket" >/dev/null 2>&1
    echo "work" >> README.md
    git add README.md && git commit -q -m "Do the work"
    echo "$ticket"
}

# Settle one item in a file and commit. The labels used here are free of regex
# metacharacters.
# Usage: mark_item <file> <label> <mark> [suffix]
#   mark   x for done, - for skipped
#   suffix appended after the label (the skip reason)
mark_item() {
    local file="$1" label="$2" mark="$3" suffix="${4:-}"
    if ! grep -q -- "^- \[ \] ${label}$" "$file"; then
        fail "test setup: '${label}' not found unchecked in ${file}"
        return 1
    fi
    sed_i "s|^- \\[ \\] ${label}\$|- [${mark}] ${label}${suffix}|" "$file"
    git add -A && git commit -q -m "Update file"
}

# ---------------------------------------------------------------------------
echo "1. Parsing: what counts as a checkbox and what does not"
# ---------------------------------------------------------------------------
cd "$TEST_DIR"
cat > n1.md <<'EOF'
- [ ] before any heading

# Work Notes: sample

## Ticket contract check
- [x] Why connects to the brief
- [X] AC observable

## Implementation log
- [ ] commits are logically scoped
- [x] full test suite passed - a1b2c3d
- [-] live API call verified - skip: this ticket calls no external API
- [-] no reason was given here
- [~] not part of the vocabulary

Quoting the template:

```markdown
- [ ] fenced-should-not-count
```

~~~
- [ ] tilde-fenced-should-not-count
~~~

## Nested
- [ ] parent
    - [ ] child indented four columns
    - [x] child done
- [ ] list item with its own fence
    ```
    - [ ] fence-inside-list-should-not-count
    ```

## Indented code

    - [ ] indented-code-should-not-count

## Closing sequence ##
- [ ] under a heading with a closing sequence
EOF

SCAN=$(checklist_scan n1.md "note.md")

if echo "$SCAN" | grep -q "fenced-should-not-count"; then
    fail "a checkbox inside a backtick fence was counted"
else
    pass "checkboxes inside a backtick fence are ignored"
fi

if echo "$SCAN" | grep -q "tilde-fenced-should-not-count"; then
    fail "a checkbox inside a tilde fence was counted"
else
    pass "checkboxes inside a tilde fence are ignored"
fi

if echo "$SCAN" | grep -q "fence-inside-list-should-not-count"; then
    fail "a fence indented inside a list item did not open"
else
    pass "a fence indented inside a list item still hides its contents"
fi

if echo "$SCAN" | grep -q "indented-code-should-not-count"; then
    fail "a four-column indented code block was counted"
else
    pass "checkboxes in an indented code block are ignored"
fi

if echo "$SCAN" | grep -q "child indented four columns"; then
    pass "a checkbox nested under another one is still counted"
else
    fail "indenting a checkbox under its parent must not hide it" "$SCAN"
fi

if echo "$SCAN" | grep -q "^skip.*live API call verified"; then
    pass "[-] with a reason counts as skipped"
else
    fail "expected [-] ... skip: <reason> to be skipped" "$SCAN"
fi

if echo "$SCAN" | grep -q "^todo.*no reason was given here"; then
    pass "[-] without a reason counts as unchecked"
else
    fail "a [-] with no reason must not pass" "$SCAN"
fi

if echo "$SCAN" | grep -q "not part of the vocabulary"; then
    fail "an unrecognised marker was counted"
else
    pass "markers outside the vocabulary are left alone"
fi

if echo "$SCAN" | grep -q "^done	note.md	Ticket contract check	AC observable"; then
    pass "an uppercase X counts as done, tagged with its file"
else
    fail "expected [X] to count as done" "$SCAN"
fi

if echo "$SCAN" | grep -q "^todo	note.md	(ungrouped)	before any heading"; then
    pass "a checkbox before any heading lands in (ungrouped)"
else
    fail "expected the (ungrouped) fallback" "$SCAN"
fi

if echo "$SCAN" | grep -q "^todo	note.md	Closing sequence	under a heading"; then
    pass "a heading's closing ## sequence is not part of the group name"
else
    fail "expected the group name without its closing sequence" "$SCAN"
fi

if echo "$SCAN" | grep -q "^todo	note.md	Implementation log	commits are logically scoped"; then
    pass "a checkbox is grouped under the nearest preceding heading"
else
    fail "expected grouping by nearest heading" "$SCAN"
fi

# ---------------------------------------------------------------------------
echo
echo "2. The ticket body: frontmatter is skipped"
# ---------------------------------------------------------------------------
cd "$TEST_DIR"
cat > t1.md <<'EOF'
---
priority: 2
description: |
  a multi-line description
  - [ ] frontmatter-should-not-count
created_at: "2026-08-27T00:00:00Z"
started_at: null  # Do not modify manually
---

# Ticket Overview

## Tasks

- [ ] write the thing
- [x] already done
EOF

SCAN=$(checklist_scan t1.md "ticket.md" true)

if echo "$SCAN" | grep -q "frontmatter-should-not-count"; then
    fail "a checkbox inside the YAML frontmatter was counted"
else
    pass "the ticket's frontmatter is skipped"
fi

if echo "$SCAN" | grep -q "^todo	ticket.md	Tasks	write the thing"; then
    pass "the ticket body's Tasks list is scanned and tagged ticket.md"
else
    fail "expected the ticket body to be scanned" "$SCAN"
fi

# extract_markdown_body used to increment its line counter with ((line_num++)),
# which evaluates to the OLD value - so the very first increment from 0 returned
# 1 and, under `set -e`, killed the subshell before a single line was emitted.
# Command substitution survived it, which is why close never noticed; a process
# substitution (what checklist_scan uses) came back empty instead.
BODY=$(bash -c "set -euo pipefail
    source '${REPO_ROOT}/lib/yaml-frontmatter.sh'
    while IFS= read -r l; do echo \"\$l\"; done < <(extract_markdown_body '${TEST_DIR}/t1.md')")
if echo "$BODY" | grep -q "write the thing"; then
    pass "extract_markdown_body survives set -e in a subshell"
else
    fail "extract_markdown_body died before emitting anything" "$BODY"
fi

# A file with no frontmatter still comes through whole.
cat > t2.md <<'EOF'
## Tasks

- [ ] no frontmatter here
EOF
if checklist_scan t2.md "ticket.md" true | grep -q "no frontmatter here"; then
    pass "a ticket file without frontmatter is scanned whole"
else
    fail "expected the whole file when there is no frontmatter"
fi

# ---------------------------------------------------------------------------
echo
echo "3. Counting and reporting across both files"
# ---------------------------------------------------------------------------
cd "$TEST_DIR"
cat > t3.md <<'EOF'
---
description: "x"
---

## Tasks
- [x] one
- [ ] two

## Review
- [ ] ticket-side review
EOF
cat > n3.md <<'EOF'
## Implementation log
- [x] three
- [-] four - skip: not applicable
- [ ] five

## Review
- [ ] note-side review
EOF

REPORT=$(checklist_report t3.md n3.md)

if echo "$REPORT" | grep -q "Checklist: 3 / 7"; then
    pass "the total spans both files, counting skipped as done"
else
    fail "expected 'Checklist: 3 / 7'" "$REPORT"
fi

if echo "$REPORT" | grep -q "^  ticket.md$" && echo "$REPORT" | grep -q "^  note.md$"; then
    pass "the report is split by file"
else
    fail "expected a per-file split" "$REPORT"
fi

if [[ "$(echo "$REPORT" | grep -c "Review")" -eq 2 ]]; then
    pass "the same heading in both files stays two groups"
else
    fail "expected Review to appear once per file" "$REPORT"
fi

if echo "$REPORT" | grep -q "Implementation log.*2 / 3"; then
    pass "per-group counts are reported"
else
    fail "expected a per-group count" "$REPORT"
fi

if echo "$REPORT" | grep -q -- "- two" && echo "$REPORT" | grep -q -- "- five"; then
    pass "the report names every unchecked item"
else
    fail "expected the unchecked items to be listed" "$REPORT"
fi

checklist_report t3.md n3.md >/dev/null
if [[ $? -eq 0 ]]; then
    pass "the report never fails, however much is unchecked"
else
    fail "the report must not fail"
fi

# --require spans both files by heading name alone.
OUT=$(checklist_require t3.md n3.md "Review" 2>&1)
RC=$?
if [[ $RC -eq 1 ]] && echo "$OUT" | grep -q "Review: 0 / 2"; then
    pass "--require matches the same heading in both files"
else
    fail "expected Review to be judged across both files" "$OUT"
fi
if echo "$OUT" | grep -q "ticket-side review" && echo "$OUT" | grep -q "note-side review"; then
    pass "--require lists the unchecked items from both files"
else
    fail "expected items from both files" "$OUT"
fi

cat > empty.md <<'EOF'
# Notes

Nothing to check here.
EOF
if [[ -z "$(checklist_report empty.md empty.md)" ]]; then
    pass "files with no checkboxes report nothing at all"
else
    fail "expected no output without checkboxes"
fi

if checklist_gate empty.md empty.md >/dev/null 2>&1; then
    pass "files with no checkboxes pass the gate"
else
    fail "no checkboxes must not block close"
fi

if checklist_gate "${TEST_DIR}/nope-a.md" "${TEST_DIR}/nope-b.md" >/dev/null 2>&1; then
    pass "missing files pass the gate"
else
    fail "a ticket with neither file must not block close"
fi

# ---------------------------------------------------------------------------
echo
echo "4. check reports, and never fails on its own"
# ---------------------------------------------------------------------------
REPO=$(make_repo repo4)
set_templates "$REPO" false
TICKET=$(begin_ticket "$REPO" demo)

OUT=$(timeout 10 ./ticket.sh check 2>&1)
RC=$?

if [[ $RC -eq 0 ]]; then
    pass "check exits 0 with every checklist still empty"
else
    fail "check must not fail on an unfinished checklist" "$OUT"
fi

if echo "$OUT" | grep -q "Checklist: 0 / 5"; then
    pass "check counts both the ticket body and the note"
else
    fail "expected both files in the count" "$OUT"
fi

if echo "$OUT" | grep -q "write the thing" && echo "$OUT" | grep -q "findings resolved"; then
    pass "check lists unchecked items from both files"
else
    fail "expected items from both files" "$OUT"
fi

if echo "$OUT" | grep -q "Current ticket is active"; then
    pass "check keeps its existing output"
else
    fail "check's original output went missing" "$OUT"
fi

# ---------------------------------------------------------------------------
echo
echo "5. check --require judges one group"
# ---------------------------------------------------------------------------
OUT=$(timeout 10 ./ticket.sh check --require "Implementation log" 2>&1)
RC=$?

if [[ $RC -eq 1 ]]; then
    pass "check --require fails while its group has unchecked items"
else
    fail "expected exit 1 from an unfinished --require group" "$OUT"
fi

if echo "$OUT" | grep -q "full test suite passed"; then
    pass "check --require names the unchecked items"
else
    fail "expected the unchecked items to be listed" "$OUT"
fi

if echo "$OUT" | grep -q "write the thing"; then
    fail "check --require reported a group it was not asked about" "$OUT"
else
    pass "check --require ignores the groups it was not asked about"
fi

mark_item "tickets/${TICKET}/note.md" "full test suite passed" x " - a1b2c3d"
mark_item "tickets/${TICKET}/note.md" "live API call verified" - " - skip: no external API here"

OUT=$(timeout 10 ./ticket.sh check --require "Implementation log" 2>&1)
RC=$?

if [[ $RC -eq 0 ]]; then
    pass "check --require passes once the group is checked or skipped"
else
    fail "expected exit 0 for a finished group" "$OUT"
fi

if echo "$OUT" | grep -q "1 skipped"; then
    pass "check --require says how many were skipped"
else
    fail "expected the skipped count" "$OUT"
fi

# "Review" exists in both templates: the ticket's and the note's.
OUT=$(timeout 10 ./ticket.sh check --require "Review" 2>&1)
if [[ $? -eq 1 ]] && echo "$OUT" | grep -q "Review: 0 / 2"; then
    pass "check --require spans a heading present in both files"
else
    fail "expected Review to be judged across both files" "$OUT"
fi

OUT=$(timeout 10 ./ticket.sh check --require "Implementaion log" 2>&1)
RC=$?

if [[ $RC -eq 1 ]]; then
    pass "a group name that matches nothing fails instead of passing"
else
    fail "a typo in --require must not become a check that always passes" "$OUT"
fi

if echo "$OUT" | grep -q "Implementation log" && echo "$OUT" | grep -q "Tasks"; then
    pass "the failure lists the group names that do exist, per file"
else
    fail "expected the available groups to be listed" "$OUT"
fi

OUT=$(timeout 10 ./ticket.sh check --require 2>&1)
if [[ $? -eq 1 ]] && echo "$OUT" | grep -q "needs a group name"; then
    pass "--require without a group name is an error"
else
    fail "expected --require to require an argument" "$OUT"
fi

OUT=$(timeout 10 ./ticket.sh check --nonsense 2>&1)
if [[ $? -eq 1 ]] && echo "$OUT" | grep -q "Unknown option"; then
    pass "check rejects options it does not know"
else
    fail "expected an unknown-option error" "$OUT"
fi

# ---------------------------------------------------------------------------
echo
echo "6. check --require with no active ticket"
# ---------------------------------------------------------------------------
REPO=$(make_repo repo6)
cd "$REPO"

OUT=$(timeout 10 ./ticket.sh check --require "Anything" 2>&1)
if [[ $? -eq 1 ]]; then
    pass "check --require fails when no ticket is active"
else
    fail "--require has nothing to judge without a ticket" "$OUT"
fi

OUT=$(timeout 10 ./ticket.sh check 2>&1)
if [[ $? -eq 0 ]]; then
    pass "plain check still succeeds with no ticket active"
else
    fail "check must keep working without an active ticket" "$OUT"
fi

# ---------------------------------------------------------------------------
echo
echo "7. close refuses while items are unchecked"
# ---------------------------------------------------------------------------
REPO=$(make_repo repo7)
set_templates "$REPO" true
TICKET=$(begin_ticket "$REPO" gated)

OUT=$(timeout 20 ./ticket.sh close 2>&1)
RC=$?

if [[ $RC -eq 1 ]]; then
    pass "close fails while anything is unchecked"
else
    fail "expected close to refuse" "$OUT"
fi

if echo "$OUT" | grep -q "5 unchecked items remain"; then
    pass "close counts both files"
else
    fail "expected the unchecked count across both files" "$OUT"
fi

if echo "$OUT" | grep -q "^  ticket.md$" && echo "$OUT" | grep -q "^  note.md$"; then
    pass "close names which file each group lives in"
else
    fail "expected a per-file split in close's output" "$OUT"
fi

if echo "$OUT" | grep -q "Nothing was closed."; then
    pass "close says plainly that nothing happened"
else
    fail "expected 'Nothing was closed.'" "$OUT"
fi

if echo "$OUT" | grep -q "skip: <reason>"; then
    pass "close points at both ways out"
else
    fail "expected the hint about marking items as skipped" "$OUT"
fi

if [[ "$(git rev-parse --abbrev-ref HEAD)" == "feature/${TICKET}" ]]; then
    pass "a refused close leaves the branch alone"
else
    fail "close must not switch branches when it refuses"
fi

if git show "main:tickets/${TICKET}/ticket.md" >/dev/null 2>&1; then
    pass "a refused close leaves the ticket where it was"
else
    fail "the ticket moved despite the refusal"
fi

OUT=$(timeout 20 ./ticket.sh close --force 2>&1)
if [[ $? -eq 1 ]] && echo "$OUT" | grep -q "unchecked"; then
    pass "--force does not get past the checklist"
else
    fail "--force is about the Git tree, not the checklist" "$OUT"
fi

OUT=$(timeout 20 ./ticket.sh close --dry-run 2>&1)
if [[ $? -eq 1 ]] && echo "$OUT" | grep -q "unchecked"; then
    pass "--dry-run catches the checklist too"
else
    fail "--dry-run should surface this before the real close" "$OUT"
fi

# Settling the note alone is not enough: the ticket body still blocks.
mark_item "tickets/${TICKET}/note.md" "full test suite passed" x
mark_item "tickets/${TICKET}/note.md" "live API call verified" - " - skip: no external API here"
mark_item "tickets/${TICKET}/note.md" "findings resolved" x

OUT=$(timeout 20 ./ticket.sh close 2>&1)
if [[ $? -eq 1 ]] && echo "$OUT" | grep -q "write the thing"; then
    pass "a settled note is not enough while the ticket body has items"
else
    fail "the ticket body must block on its own" "$OUT"
fi

# ---------------------------------------------------------------------------
echo
echo "8. close proceeds once both files are settled"
# ---------------------------------------------------------------------------
mark_item "tickets/${TICKET}/ticket.md" "write the thing" x

OUT=$(timeout 20 ./ticket.sh close 2>&1)
if [[ $? -eq 1 ]] && echo "$OUT" | grep -q "1 unchecked item remains"; then
    pass "one remaining item is still enough to refuse"
else
    fail "expected the singular form and a refusal" "$OUT"
fi

mark_item "tickets/${TICKET}/ticket.md" "ticket-side review" x

OUT=$(timeout 20 ./ticket.sh close 2>&1)
if [[ $? -eq 0 ]]; then
    pass "close succeeds once every item is checked or skipped"
else
    fail "expected the close to go through" "$OUT"
fi

if git show "main:tickets/done/${TICKET}/ticket.md" >/dev/null 2>&1; then
    pass "the ticket reached done/"
else
    fail "the ticket should have moved to done/"
fi

# ---------------------------------------------------------------------------
echo
echo "9. The stock templates, and the gate being off by default"
# ---------------------------------------------------------------------------
REPO=$(make_repo repo9)
cd "$REPO"
if grep -q "^require_checklist: false" .ticket-config.yaml; then
    pass "init writes require_checklist: false into the config"
else
    fail "expected the new key in a freshly generated config"
fi

if grep -q "^require_note_checklist:" .ticket-config.yaml; then
    fail "the old key name is still being generated"
else
    pass "the old key name is gone from generated configs"
fi

TICKET=$(begin_ticket "$REPO" stock)
OUT=$(timeout 10 ./ticket.sh check 2>&1)

if echo "$OUT" | grep -q "Get developer approval before closing"; then
    pass "the stock ticket template's Tasks list is reported"
else
    fail "expected the stock Tasks list in check's output" "$OUT"
fi

if echo "$OUT" | grep -q "Update README"; then
    pass "items nested two columns under another are counted"
else
    fail "expected the nested doc items" "$OUT"
fi

OUT=$(timeout 20 ./ticket.sh close 2>&1)
if [[ $? -eq 0 ]]; then
    pass "with require_checklist false, close ignores the checklist"
else
    fail "the gate must be opt-in" "$OUT"
fi

# ---------------------------------------------------------------------------
echo
echo "10. The renamed config key"
# ---------------------------------------------------------------------------
REPO=$(make_repo repo10)
set_templates "$REPO" false
sed_i 's/^require_checklist: false/require_note_checklist: true/' .ticket-config.yaml
git add -A && git commit -q -m "Old key name, enabled"
TICKET=$(begin_ticket "$REPO" oldkey)

OUT=$(timeout 20 ./ticket.sh close 2>&1)
RC=$?

if [[ $RC -eq 1 ]] && echo "$OUT" | grep -q "has been renamed"; then
    pass "an enabled old key is an error, not a silent no-op"
else
    fail "close must not silently ignore require_note_checklist: true" "$OUT"
fi

if git show "main:tickets/${TICKET}/ticket.md" >/dev/null 2>&1; then
    pass "nothing was closed while the old key was in place"
else
    fail "the ticket should not have moved"
fi

sed_i 's/^require_note_checklist: true/require_note_checklist: false/' .ticket-config.yaml
git add -A && git commit -q -m "Old key name, disabled"

OUT=$(timeout 10 ./ticket.sh check 2>&1)
RC=$?
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "no longer read"; then
    pass "a disabled old key only warns"
else
    fail "expected a warning, not a failure" "$OUT"
fi

OUT=$(timeout 20 ./ticket.sh close 2>&1)
if [[ $? -eq 0 ]]; then
    pass "a disabled old key does not block close"
else
    fail "a stale disabled key must not stop anything" "$OUT"
fi

# ---------------------------------------------------------------------------
echo
echo "11. Legacy flat layout"
# ---------------------------------------------------------------------------
REPO=$(make_repo repo11)
cd "$REPO"
sed_i 's/^require_checklist: false/require_checklist: true/' .ticket-config.yaml
git add -A && git commit -q -m "Turn the gate on"

LEGACY="260827-000000-legacy-checklist"
cat > "tickets/${LEGACY}.md" <<'EOF'
---
priority: 2
description: "legacy flat layout"
created_at: "2026-08-27T00:00:00Z"
started_at: null  # Do not modify manually
closed_at: null   # Do not modify manually
canceled_at: null # Do not modify manually
---

# Legacy Overview

## Tasks

- [ ] legacy ticket item
EOF
cat > "tickets/${LEGACY}-note.md" <<'EOF'
# Notes

## Review

- [ ] legacy note item
EOF
git add tickets && git commit -q -m "Add legacy ticket"

timeout 10 ./ticket.sh start "$LEGACY" >/dev/null 2>&1
echo "work" >> README.md
git add README.md && git commit -q -m "Do the work"

OUT=$(timeout 20 ./ticket.sh close 2>&1)
if [[ $? -eq 1 ]] && echo "$OUT" | grep -q "legacy ticket item" && echo "$OUT" | grep -q "legacy note item"; then
    pass "both legacy flat files are found and judged"
else
    fail "expected both legacy files to be checked" "$OUT"
fi

OUT=$(timeout 10 ./ticket.sh check 2>&1)
if echo "$OUT" | grep -q "legacy note item"; then
    pass "check reports a legacy ticket's checklists"
else
    fail "expected the legacy checklist in check's output" "$OUT"
fi

mark_item "tickets/${LEGACY}.md" "legacy ticket item" x
mark_item "tickets/${LEGACY}-note.md" "legacy note item" x

OUT=$(timeout 20 ./ticket.sh close 2>&1)
if [[ $? -eq 0 ]]; then
    pass "a legacy ticket closes once both files are settled"
else
    fail "expected the legacy close to go through" "$OUT"
fi

# ---------------------------------------------------------------------------
echo
echo "12. A ticket with no note file at all"
# ---------------------------------------------------------------------------
REPO=$(make_repo repo12)
set_templates "$REPO" true
TICKET=$(begin_ticket "$REPO" nonote)
rm -f "tickets/${TICKET}/note.md"
mark_item "tickets/${TICKET}/ticket.md" "write the thing" x
mark_item "tickets/${TICKET}/ticket.md" "ticket-side review" x

OUT=$(timeout 20 ./ticket.sh close 2>&1)
if [[ $? -eq 0 ]]; then
    pass "a ticket with no note file closes on its ticket body alone"
else
    fail "a missing note means nothing to judge there" "$OUT"
fi

# ---------------------------------------------------------------------------
echo
echo "=== checklist Test Results ==="
echo "  Passed: $PASSED, Failed: $FAILED"
echo

cd "$REPO_ROOT"
git worktree prune 2>/dev/null || true
rm -rf "$TEST_DIR"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
