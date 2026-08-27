#!/usr/bin/env bash

# Tests for the note checklist check (issue #3).
#
# The note template ticket.sh hands out can carry checkboxes, and nothing used
# to look at whether they were filled in. `check` now reports their state,
# `check --require "<group>"` judges one group, and `close` refuses while any
# are unchecked (opt-in via require_note_checklist).
#
# The parser cases matter as much as the plumbing: a work note is full of
# pasted output and quoted templates, so a checkbox inside a code block must
# not count, while a checkbox merely indented under another one must.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-helpers.sh"

echo "=== note checklist Test Suite ==="
echo

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="${REPO_ROOT}/tmp/test-note-checklist-$(date +%s)"
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

source "${REPO_ROOT}/lib/note-checklist.sh"

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

# Replace the note template in the config with one carrying a checklist, and
# optionally turn the close gate on.
# Usage: set_note_template <repo-dir> <gate:true|false>
set_note_template() {
    local dir="$1" gate="$2"
    cd "$dir" || return 1
    awk -v gate="$gate" '
        /^note_content: \|/ {
            inblk = 1
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
        inblk && /^# Ticket template/ { inblk = 0 }
        inblk { next }
        /^require_note_checklist:/ { print "require_note_checklist: " gate; next }
        { print }
    ' .ticket-config.yaml > .ticket-config.yaml.new
    mv .ticket-config.yaml.new .ticket-config.yaml
    git add -A && git commit -q -m "Note template with a checklist"
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

# Settle one item in a note file and commit. Labels used here are free of
# regex metacharacters.
# Usage: mark_item <note-file> <label> <mark> [suffix]
#   mark   x for done, - for skipped
#   suffix appended after the label (the skip reason)
mark_item() {
    local file="$1" label="$2" mark="$3" suffix="${4:-}"
    if ! grep -q -- "^- \[ \] ${label}$" "$file"; then
        fail "test setup: '${label}' not found unchecked in ${file}"
        return 1
    fi
    sed_i "s|^- \\[ \\] ${label}\$|- [${mark}] ${label}${suffix}|" "$file"
    git add -A && git commit -q -m "Update note"
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

SCAN=$(note_checklist_scan n1.md)

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

if echo "$SCAN" | grep -q "^done	Ticket contract check	AC observable"; then
    pass "an uppercase X counts as done"
else
    fail "expected [X] to count as done" "$SCAN"
fi

if echo "$SCAN" | grep -q "^todo	(ungrouped)	before any heading"; then
    pass "a checkbox before any heading lands in (ungrouped)"
else
    fail "expected the (ungrouped) fallback" "$SCAN"
fi

if echo "$SCAN" | grep -q "^todo	Closing sequence	under a heading"; then
    pass "a heading's closing ## sequence is not part of the group name"
else
    fail "expected the group name without its closing sequence" "$SCAN"
fi

if echo "$SCAN" | grep -q "^todo	Implementation log	commits are logically scoped"; then
    pass "a checkbox is grouped under the nearest preceding heading"
else
    fail "expected grouping by nearest heading" "$SCAN"
fi

# ---------------------------------------------------------------------------
echo
echo "2. Counting and reporting"
# ---------------------------------------------------------------------------
cd "$TEST_DIR"
cat > n2.md <<'EOF'
## Implementation log
- [x] one
- [-] two - skip: not applicable
- [ ] three

## Review
- [ ] four
EOF

REPORT=$(note_checklist_report n2.md)

if echo "$REPORT" | grep -q "Checklist: 2 / 4"; then
    pass "skipped items count towards done in the total"
else
    fail "expected 'Checklist: 2 / 4'" "$REPORT"
fi

if echo "$REPORT" | grep -q "Implementation log.*2 / 3"; then
    pass "per-group counts are reported"
else
    fail "expected a per-group count" "$REPORT"
fi

if echo "$REPORT" | grep -q -- "- three" && echo "$REPORT" | grep -q -- "- four"; then
    pass "the report names every unchecked item"
else
    fail "expected the unchecked items to be listed" "$REPORT"
fi

note_checklist_report n2.md >/dev/null
if [[ $? -eq 0 ]]; then
    pass "the report never fails, however much is unchecked"
else
    fail "the report must not fail"
fi

cat > n3.md <<'EOF'
# Notes

Nothing to check here.
EOF
if [[ -z "$(note_checklist_report n3.md)" ]]; then
    pass "a note with no checkboxes reports nothing at all"
else
    fail "expected no output for a note without checkboxes"
fi

if note_checklist_gate n3.md >/dev/null 2>&1; then
    pass "a note with no checkboxes passes the gate"
else
    fail "a note without checkboxes must not block close"
fi

if note_checklist_gate "${TEST_DIR}/does-not-exist.md" >/dev/null 2>&1; then
    pass "a missing note file passes the gate"
else
    fail "a ticket with no note file must not block close"
fi

# ---------------------------------------------------------------------------
echo
echo "3. check reports, and never fails on its own"
# ---------------------------------------------------------------------------
REPO=$(make_repo repo3)
set_note_template "$REPO" false
TICKET=$(begin_ticket "$REPO" demo)

OUT=$(timeout 10 ./ticket.sh check 2>&1)
RC=$?

if [[ $RC -eq 0 ]]; then
    pass "check exits 0 with the whole checklist still empty"
else
    fail "check must not fail on an unfinished checklist" "$OUT"
fi

if echo "$OUT" | grep -q "Checklist: 0 / 3"; then
    pass "check reports the checklist of the active ticket's note"
else
    fail "expected the checklist report in check's output" "$OUT"
fi

if echo "$OUT" | grep -q "Current ticket is active"; then
    pass "check keeps its existing output"
else
    fail "check's original output went missing" "$OUT"
fi

# ---------------------------------------------------------------------------
echo
echo "4. check --require judges one group"
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

if echo "$OUT" | grep -q "Review"; then
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

OUT=$(timeout 10 ./ticket.sh check --require "Implementaion log" 2>&1)
RC=$?

if [[ $RC -eq 1 ]]; then
    pass "a group name that matches nothing fails instead of passing"
else
    fail "a typo in --require must not become a check that always passes" "$OUT"
fi

if echo "$OUT" | grep -q "Implementation log" && echo "$OUT" | grep -q "Review"; then
    pass "the failure lists the group names that do exist"
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
echo "5. check --require with no active ticket"
# ---------------------------------------------------------------------------
REPO=$(make_repo repo5)
cd "$REPO"

OUT=$(timeout 10 ./ticket.sh check --require "Anything" 2>&1)
RC=$?

if [[ $RC -eq 1 ]]; then
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
echo "6. close refuses while items are unchecked"
# ---------------------------------------------------------------------------
REPO=$(make_repo repo6)
set_note_template "$REPO" true
TICKET=$(begin_ticket "$REPO" gated)

OUT=$(timeout 20 ./ticket.sh close 2>&1)
RC=$?

if [[ $RC -eq 1 ]]; then
    pass "close fails while the note has unchecked items"
else
    fail "expected close to refuse" "$OUT"
fi

if echo "$OUT" | grep -q "3 unchecked items remain in the note"; then
    pass "close says how many items are unchecked"
else
    fail "expected the unchecked count" "$OUT"
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

# ---------------------------------------------------------------------------
echo
echo "7. close proceeds once the checklist is settled"
# ---------------------------------------------------------------------------
mark_item "tickets/${TICKET}/note.md" "full test suite passed" x
mark_item "tickets/${TICKET}/note.md" "live API call verified" - " - skip: no external API here"

OUT=$(timeout 20 ./ticket.sh close 2>&1)
if [[ $? -eq 1 ]] && echo "$OUT" | grep -q "1 unchecked item remains"; then
    pass "one remaining item is still enough to refuse"
else
    fail "expected the singular form and a refusal" "$OUT"
fi

mark_item "tickets/${TICKET}/note.md" "findings resolved" x

OUT=$(timeout 20 ./ticket.sh close 2>&1)
RC=$?

if [[ $RC -eq 0 ]]; then
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
echo "8. The gate is off unless the config turns it on"
# ---------------------------------------------------------------------------
REPO=$(make_repo repo8)
set_note_template "$REPO" false
TICKET=$(begin_ticket "$REPO" ungated)

OUT=$(timeout 20 ./ticket.sh close 2>&1)
RC=$?

if [[ $RC -eq 0 ]]; then
    pass "with require_note_checklist false, close ignores the checklist"
else
    fail "the gate must be opt-in" "$OUT"
fi

REPO=$(make_repo repo8b)
cd "$REPO"
if grep -q "^require_note_checklist: false" .ticket-config.yaml; then
    pass "init writes require_note_checklist: false into the config"
else
    fail "expected the new key in a freshly generated config"
fi

TICKET=$(begin_ticket "$REPO" stock)
OUT=$(timeout 10 ./ticket.sh check 2>&1)
if echo "$OUT" | grep -q "Checklist:"; then
    fail "the stock note template has no checkboxes to report" "$OUT"
else
    pass "the stock note template produces no checklist output"
fi

# ---------------------------------------------------------------------------
echo
echo "9. Legacy flat layout"
# ---------------------------------------------------------------------------
REPO=$(make_repo repo9)
cd "$REPO"
sed_i 's/^require_note_checklist: false/require_note_checklist: true/' .ticket-config.yaml
git add -A && git commit -q -m "Turn the gate on"

LEGACY="260826-000000-legacy-checklist"
cat > "tickets/${LEGACY}.md" <<'EOF'
---
priority: 2
description: "legacy flat layout"
created_at: "2026-08-26T00:00:00Z"
started_at: null  # Do not modify manually
closed_at: null   # Do not modify manually
canceled_at: null # Do not modify manually
---

# Legacy Overview

legacy body text
EOF
cat > "tickets/${LEGACY}-note.md" <<'EOF'
# Notes

## Review

- [ ] legacy item never checked
EOF
git add tickets && git commit -q -m "Add legacy ticket"

timeout 10 ./ticket.sh start "$LEGACY" >/dev/null 2>&1
echo "work" >> README.md
git add README.md && git commit -q -m "Do the work"

OUT=$(timeout 20 ./ticket.sh close 2>&1)
if [[ $? -eq 1 ]] && echo "$OUT" | grep -q "legacy item never checked"; then
    pass "the flat <name>-note.md is found and judged"
else
    fail "expected the legacy note to be checked too" "$OUT"
fi

OUT=$(timeout 10 ./ticket.sh check 2>&1)
if echo "$OUT" | grep -q "legacy item never checked"; then
    pass "check reports a legacy ticket's checklist"
else
    fail "expected the legacy checklist in check's output" "$OUT"
fi

mark_item "tickets/${LEGACY}-note.md" "legacy item never checked" x

OUT=$(timeout 20 ./ticket.sh close 2>&1)
if [[ $? -eq 0 ]]; then
    pass "a legacy ticket closes once its note is settled"
else
    fail "expected the legacy close to go through" "$OUT"
fi

# ---------------------------------------------------------------------------
echo
echo "10. A ticket with no note file at all"
# ---------------------------------------------------------------------------
REPO=$(make_repo repo10)
cd "$REPO"
sed_i 's/^require_note_checklist: false/require_note_checklist: true/' .ticket-config.yaml
git add -A && git commit -q -m "Turn the gate on"
TICKET=$(begin_ticket "$REPO" nonote)
rm -f "tickets/${TICKET}/note.md"
git add -A && git commit -q -m "Drop the note"

OUT=$(timeout 20 ./ticket.sh close 2>&1)
if [[ $? -eq 0 ]]; then
    pass "a ticket with no note file closes with the gate on"
else
    fail "no note means nothing to judge" "$OUT"
fi

# ---------------------------------------------------------------------------
echo
echo "=== note checklist Test Results ==="
echo "  Passed: $PASSED, Failed: $FAILED"
echo

cd "$REPO_ROOT"
git worktree prune 2>/dev/null || true
rm -rf "$TEST_DIR"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
