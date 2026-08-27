#!/usr/bin/env bash

# note-checklist.sh - find unchecked checklist items in a ticket's note file.
#
# The note template that ticket.sh hands out can carry checkboxes, but nothing
# ever looked at whether they got filled in. These functions do that: they scan
# a note, group the checkboxes by the heading each one sits under, and report
# (or refuse) based on what is still empty.
#
# Three states are recognised:
#   - [x] ...                       done
#   - [ ] ...                       unchecked  -> blocks
#   - [-] ... - skip: <reason>      not applicable to this ticket -> passes
#
# A `[-]` without a reason counts as unchecked. Deleting the line is NOT a way
# to pass, in the sense that a deleted line simply stops being checked - see
# the ticket for why reconciling against the config template was left out.
#
# This is a deliberately small Markdown scanner, not a CommonMark parser. It
# understands what a work note actually contains: ATX headings, list items,
# fenced code blocks and indented code blocks. Setext headings (underlined with
# === or ---) are not treated as headings, because a note's horizontal rules
# would then be indistinguishable from them.
#
# Everything here is pure parameter expansion - no subprocess per line. A note
# is read once per command, and `list` already showed what per-line process
# spawning costs.

# Emit one record per checkbox found, in file order:
#
#   <state><TAB><group><TAB><label>
#
# state is one of: done | skip | todo
# group is the text of the nearest preceding heading, or (ungrouped).
#
# Usage: note_checklist_scan <note-file>
# Prints nothing (and succeeds) when the file is missing or has no checkboxes.
note_checklist_scan() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    local group="(ungrouped)"
    local fence_char="" fence_len=0
    local in_indented_code=0
    local prev_blank=1
    local in_list=0
    local line stripped indent blank
    local backtick='`'

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        # A tab counts as four columns in Markdown's indentation rules, and
        # this also keeps tabs out of the TAB-separated records below.
        line="${line//$'\t'/    }"

        stripped="${line#"${line%%[![:space:]]*}"}"
        indent=$(( ${#line} - ${#stripped} ))
        blank=0
        [[ -z "$stripped" ]] && blank=1

        # --- inside a fenced code block: nothing counts until it closes ---
        if [[ -n "$fence_char" ]]; then
            if [[ $blank -eq 1 ]]; then
                prev_blank=1
                continue
            fi
            prev_blank=0
            if [[ "${stripped:0:1}" == "$fence_char" ]]; then
                local run=0
                while [[ "${stripped:$run:1}" == "$fence_char" ]]; do run=$((run + 1)); done
                if (( run >= fence_len )); then
                    local tail="${stripped:$run}"
                    tail="${tail#"${tail%%[![:space:]]*}"}"
                    [[ -z "$tail" ]] && fence_char=""
                fi
            fi
            continue
        fi

        # --- inside an indented code block: ends at the first non-blank
        # --- line that is indented less than four columns
        if [[ $in_indented_code -eq 1 ]]; then
            if [[ $blank -eq 1 ]]; then
                prev_blank=1
                continue
            fi
            if (( indent >= 4 )); then
                prev_blank=0
                continue
            fi
            in_indented_code=0
            # fall through and process this line normally
        fi

        if [[ $blank -eq 1 ]]; then
            prev_blank=1
            continue
        fi

        # --- start of an indented code block ---
        # Only outside a list. Inside a list, four columns of indentation is
        # the item's own continuation, not code: treating it as code would
        # make nested checkboxes silently vanish from the count, which would
        # hand back exactly the "indent it and it stops blocking" loophole
        # this check exists to close.
        if (( indent >= 4 )) && [[ $in_list -eq 0 && $prev_blank -eq 1 ]]; then
            in_indented_code=1
            prev_blank=0
            continue
        fi

        prev_blank=0

        # --- opening fence ---
        # Allowed at any indentation while inside a list, where the fence is
        # indented to the list item's content column.
        if (( indent <= 3 )) || [[ $in_list -eq 1 ]]; then
            if [[ "${stripped:0:3}" == "${backtick}${backtick}${backtick}" || "${stripped:0:3}" == '~~~' ]]; then
                fence_char="${stripped:0:1}"
                fence_len=0
                while [[ "${stripped:$fence_len:1}" == "$fence_char" ]]; do fence_len=$((fence_len + 1)); done
                continue
            fi
        fi

        # --- ATX heading: starts a new group ---
        if (( indent <= 3 )) && [[ "${stripped:0:1}" == "#" ]]; then
            local level=0
            while [[ "${stripped:$level:1}" == "#" ]]; do level=$((level + 1)); done
            if (( level <= 6 )) && [[ -z "${stripped:$level:1}" || "${stripped:$level:1}" == " " ]]; then
                local title="${stripped:$level}"
                title="${title#"${title%%[![:space:]]*}"}"
                title="${title%"${title##*[![:space:]]}"}"
                # Optional closing sequence ("## Title ##"), which requires a
                # space before it - a heading may legitimately end in '#'.
                if [[ "$title" =~ ^(.*[[:space:]])#+$ ]]; then
                    title="${BASH_REMATCH[1]}"
                    title="${title%"${title##*[![:space:]]}"}"
                fi
                group="${title:-(ungrouped)}"
                in_list=0
                continue
            fi
        fi

        # --- list item, possibly a checkbox ---
        if [[ "$stripped" =~ ^([-*+]|[0-9]+[.\)])[[:space:]]+(.*)$ ]]; then
            in_list=1
            local rest="${BASH_REMATCH[2]}"
            if [[ "${rest:0:1}" == "[" && "${rest:2:1}" == "]" ]]; then
                local mark="${rest:1:1}"
                local label="${rest:3}"
                label="${label#"${label%%[![:space:]]*}"}"
                label="${label%"${label##*[![:space:]]}"}"
                case "$mark" in
                    x|X)
                        printf 'done\t%s\t%s\n' "$group" "$label"
                        ;;
                    ' ')
                        printf 'todo\t%s\t%s\n' "$group" "$label"
                        ;;
                    '-')
                        # A reason is what makes "not applicable" reviewable.
                        # Without one it is indistinguishable from skipping the
                        # work, so it counts as unchecked.
                        if [[ "$label" =~ [Ss][Kk][Ii][Pp]:[[:space:]]*[^[:space:]] ]]; then
                            printf 'skip\t%s\t%s\n' "$group" "$label"
                        else
                            printf 'todo\t%s\t%s\n' "$group" "$label"
                        fi
                        ;;
                    *)
                        # Not part of the vocabulary ([~], [/], ...). Saying
                        # nothing beats guessing what the author meant.
                        ;;
                esac
            fi
            continue
        fi

        # --- ordinary text: a line at column 0 ends the list ---
        if (( indent == 0 )); then
            in_list=0
        fi
    done < "$file"

    return 0
}

# Aggregate a scan into per-group counters, in first-appearance order.
# Populates these globals (plain indexed arrays - Bash 3.2 has no associative
# arrays):
#
#   NCL_GROUPS[]   group name
#   NCL_TOTAL[]    checkboxes in the group
#   NCL_DONE[]     checked, including skipped
#   NCL_SKIP[]     skipped with a reason
#   NCL_TODO[]     newline-separated labels of the unchecked ones
#   NCL_SUM_TOTAL  NCL_SUM_DONE  NCL_SUM_TODO   whole-file totals
#
# Usage: note_checklist_aggregate <note-file>
note_checklist_aggregate() {
    local file="$1"

    NCL_GROUPS=()
    NCL_TOTAL=()
    NCL_DONE=()
    NCL_SKIP=()
    NCL_TODO=()
    NCL_SUM_TOTAL=0
    NCL_SUM_DONE=0
    NCL_SUM_TODO=0

    local state group label idx i found
    while IFS=$'\t' read -r state group label; do
        [[ -z "$state" ]] && continue

        idx=-1
        found=0
        i=0
        while (( i < ${#NCL_GROUPS[@]} )); do
            if [[ "${NCL_GROUPS[$i]}" == "$group" ]]; then
                idx=$i
                found=1
                break
            fi
            i=$((i + 1))
        done
        if [[ $found -eq 0 ]]; then
            idx=${#NCL_GROUPS[@]}
            NCL_GROUPS[$idx]="$group"
            NCL_TOTAL[$idx]=0
            NCL_DONE[$idx]=0
            NCL_SKIP[$idx]=0
            NCL_TODO[$idx]=""
        fi

        NCL_TOTAL[$idx]=$(( ${NCL_TOTAL[$idx]} + 1 ))
        NCL_SUM_TOTAL=$(( NCL_SUM_TOTAL + 1 ))
        case "$state" in
            done)
                NCL_DONE[$idx]=$(( ${NCL_DONE[$idx]} + 1 ))
                NCL_SUM_DONE=$(( NCL_SUM_DONE + 1 ))
                ;;
            skip)
                NCL_DONE[$idx]=$(( ${NCL_DONE[$idx]} + 1 ))
                NCL_SKIP[$idx]=$(( ${NCL_SKIP[$idx]} + 1 ))
                NCL_SUM_DONE=$(( NCL_SUM_DONE + 1 ))
                ;;
            todo)
                if [[ -n "${NCL_TODO[$idx]}" ]]; then
                    NCL_TODO[$idx]="${NCL_TODO[$idx]}"$'\n'"$label"
                else
                    NCL_TODO[$idx]="$label"
                fi
                NCL_SUM_TODO=$(( NCL_SUM_TODO + 1 ))
                ;;
        esac
    done < <(note_checklist_scan "$file")

    return 0
}

# The one line printed under every failure, so the reader always sees both ways
# out: do the thing, or record why it does not apply.
note_checklist_hint() {
    echo 'Check them, or mark the ones that do not apply as `- [-] ... — skip: <reason>`.'
}

# Report every group and what is still empty. Never fails: mid-ticket, the
# later groups being empty is the normal state, and a check that always failed
# on day one would just be turned off.
#
# Usage: note_checklist_report <note-file>
note_checklist_report() {
    local file="$1"
    note_checklist_aggregate "$file"
    [[ $NCL_SUM_TOTAL -eq 0 ]] && return 0

    local width=0 i name pad
    i=0
    while (( i < ${#NCL_GROUPS[@]} )); do
        name="${NCL_GROUPS[$i]}"
        (( ${#name} > width )) && width=${#name}
        i=$((i + 1))
    done
    width=$((width + 4))

    echo ""
    echo "Checklist: ${NCL_SUM_DONE} / ${NCL_SUM_TOTAL}"
    i=0
    while (( i < ${#NCL_GROUPS[@]} )); do
        name="${NCL_GROUPS[$i]}"
        pad=""
        while (( ${#name} + ${#pad} < width )); do pad="${pad} "; done
        local line="  ${name}${pad}${NCL_DONE[$i]} / ${NCL_TOTAL[$i]}"
        if [[ "${NCL_DONE[$i]}" == "${NCL_TOTAL[$i]}" ]]; then
            line="${line}  done"
            if (( ${NCL_SKIP[$i]} > 0 )); then
                line="${line} (${NCL_SKIP[$i]} skipped)"
            fi
        fi
        echo "$line"
        if [[ -n "${NCL_TODO[$i]}" ]]; then
            local label
            while IFS= read -r label; do
                echo "      - ${label}"
            done <<< "${NCL_TODO[$i]}"
        fi
        i=$((i + 1))
    done

    return 0
}

# Judge a single group, named by the caller. The caller is the one that knows
# which stage the work is at; ticket.sh only has to match a string.
#
# A name that matches no group in the note is a failure, not a pass. Letting it
# pass would turn a typo into a check that always succeeds - the caller would
# believe it is enforcing something while nothing is being looked at, which is
# the same hole this whole feature exists to close.
#
# Usage: note_checklist_require <note-file> <group-name>
note_checklist_require() {
    local file="$1"
    local want="$2"

    note_checklist_aggregate "$file"

    local i=0 idx=-1
    while (( i < ${#NCL_GROUPS[@]} )); do
        if [[ "${NCL_GROUPS[$i]}" == "$want" ]]; then
            idx=$i
            break
        fi
        i=$((i + 1))
    done

    if [[ $idx -lt 0 ]]; then
        echo "✗ No checklist group named \"${want}\" in the note" >&2
        echo "" >&2
        if [[ ${#NCL_GROUPS[@]} -eq 0 ]]; then
            echo "The note has no checkboxes at all: ${file}" >&2
        else
            echo "Groups in ${file}:" >&2
            i=0
            while (( i < ${#NCL_GROUPS[@]} )); do
                echo "  - ${NCL_GROUPS[$i]}" >&2
                i=$((i + 1))
            done
        fi
        return 1
    fi

    if [[ -z "${NCL_TODO[$idx]}" ]]; then
        local msg="✓ ${want}: ${NCL_DONE[$idx]} / ${NCL_TOTAL[$idx]}"
        if (( ${NCL_SKIP[$idx]} > 0 )); then
            msg="${msg}  (${NCL_SKIP[$idx]} skipped)"
        fi
        echo "$msg"
        return 0
    fi

    echo "✗ ${want}: ${NCL_DONE[$idx]} / ${NCL_TOTAL[$idx]}"
    echo ""
    echo "  Unchecked"
    local label
    while IFS= read -r label; do
        echo "    - ${label}"
    done <<< "${NCL_TODO[$idx]}"
    echo ""
    note_checklist_hint
    return 1
}

# Judge every group. Used by close's preflight.
# Succeeds when the note has no checkboxes at all, so projects that never put
# any in their note template are unaffected.
#
# Usage: note_checklist_gate <note-file>
note_checklist_gate() {
    local file="$1"
    note_checklist_aggregate "$file"
    [[ $NCL_SUM_TODO -eq 0 ]] && return 0

    local width=0 i name pad
    i=0
    while (( i < ${#NCL_GROUPS[@]} )); do
        if [[ -n "${NCL_TODO[$i]}" ]]; then
            name="${NCL_GROUPS[$i]}"
            (( ${#name} > width )) && width=${#name}
        fi
        i=$((i + 1))
    done
    width=$((width + 3))

    local noun="items remain"
    [[ $NCL_SUM_TODO -eq 1 ]] && noun="item remains"
    echo "✗ ${NCL_SUM_TODO} unchecked ${noun} in the note" >&2
    echo "" >&2
    i=0
    while (( i < ${#NCL_GROUPS[@]} )); do
        if [[ -n "${NCL_TODO[$i]}" ]]; then
            name="${NCL_GROUPS[$i]}"
            pad=""
            while (( ${#name} + ${#pad} < width )); do pad="${pad} "; done
            local count=0 label
            while IFS= read -r label; do count=$((count + 1)); done <<< "${NCL_TODO[$i]}"
            echo "  ${name}${pad}${count}" >&2
            while IFS= read -r label; do
                echo "      - ${label}" >&2
            done <<< "${NCL_TODO[$i]}"
        fi
        i=$((i + 1))
    done
    echo "" >&2
    note_checklist_hint >&2
    return 1
}
