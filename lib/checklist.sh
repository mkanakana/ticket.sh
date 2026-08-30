#!/usr/bin/env bash

# checklist.sh - find unchecked checklist items in a ticket's files.
#
# Both files a ticket owns can carry checkboxes, and nothing used to look at
# whether they got filled in:
#
#   ticket.md   the "## Tasks" list - present in the stock template
#   note.md     whatever checklist a project puts in its note template
#
# These functions scan them, group the checkboxes by the heading each one sits
# under, and report (or refuse) based on what is still empty. The two files are
# kept apart throughout, so the output says which one to go and edit.
#
# Three states are recognised:
#   - [x] ...                       done
#   - [ ] ...                       unchecked  -> blocks
#   - [-] ... - skip: <reason>      not applicable to this ticket -> passes
#
# A `[-]` without a reason counts as unchecked. Deleting the line is NOT a way
# to pass, in the sense that a deleted line simply stops being checked - see
# https://github.com/masuidrive/ticket.sh/issues/4 for why reconciling against
# the config template was left out.
#
# This is a deliberately small Markdown scanner, not a CommonMark parser. It
# understands what these files actually contain: ATX headings, list items,
# fenced code blocks and indented code blocks. Setext headings (underlined with
# === or ---) are not treated as headings, because a horizontal rule would then
# be indistinguishable from one.
#
# The scanner is pure parameter expansion - no subprocess per line. These files
# are read once per command, and `list` already showed what per-line process
# spawning costs.

# Read Markdown from stdin and emit one record per checkbox, in file order:
#
#   <state><TAB><file><TAB><group><TAB><label>
#
# state is one of: done | skip | todo
# file is the label passed in (ticket.md / note.md)
# group is the text of the nearest preceding heading, or (ungrouped).
_checklist_scan_stream() {
    local label="$1"

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
                local label_text="${rest:3}"
                label_text="${label_text#"${label_text%%[![:space:]]*}"}"
                label_text="${label_text%"${label_text##*[![:space:]]}"}"
                case "$mark" in
                    x|X)
                        printf 'done\t%s\t%s\t%s\n' "$label" "$group" "$label_text"
                        ;;
                    ' ')
                        printf 'todo\t%s\t%s\t%s\n' "$label" "$group" "$label_text"
                        ;;
                    '-')
                        # A reason is what makes "not applicable" reviewable.
                        # Without one it is indistinguishable from skipping the
                        # work, so it counts as unchecked.
                        if [[ "$label_text" =~ [Ss][Kk][Ii][Pp]:[[:space:]]*[^[:space:]] ]]; then
                            printf 'skip\t%s\t%s\t%s\n' "$label" "$group" "$label_text"
                        else
                            printf 'todo\t%s\t%s\t%s\n' "$label" "$group" "$label_text"
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
    done

    return 0
}

# Scan one file.
#
# Usage: checklist_scan <file> <label> [strip_frontmatter]
#
# strip_frontmatter is "true" for the ticket body, which carries YAML
# frontmatter: without stripping it, a `- [ ]` inside a block scalar (a
# multi-line `description`, say) would be counted as a checkbox. The note file
# has no frontmatter, and is read as-is - running it through the stripper would
# risk mistaking a horizontal rule on its first line for a frontmatter fence.
#
# Prints nothing (and succeeds) when the file is missing.
checklist_scan() {
    local file="$1"
    local label="$2"
    local strip="${3:-false}"

    [[ -f "$file" ]] || return 0

    if [[ "$strip" == "true" ]]; then
        _checklist_scan_stream "$label" < <(extract_markdown_body "$file")
    else
        _checklist_scan_stream "$label" < "$file"
    fi
    return 0
}

# Aggregate the ticket body and the note into per-group counters, in
# first-appearance order (ticket first, then note). A group is identified by
# BOTH the file and the heading text: the same heading in both files stays two
# groups, so the output can say which file to go and edit.
#
# Populates these globals (plain indexed arrays - Bash 3.2 has no associative
# arrays); one entry per group:
#
#   CL_FILES[]     which file the group came from (ticket.md / note.md)
#   CL_GROUPS[]    heading text
#   CL_TOTAL[]     checkboxes in the group
#   CL_DONE[]      checked, including skipped
#   CL_SKIP[]      skipped with a reason
#   CL_TODO[]      newline-separated labels of the unchecked ones
#   CL_SUM_TOTAL   CL_SUM_DONE   CL_SUM_TODO    totals across both files
#
# Usage: checklist_aggregate <ticket-file> <note-file>
# Either path may be missing; a missing file simply contributes nothing.
checklist_aggregate() {
    local ticket_file="$1"
    local note_file="$2"

    CL_FILES=()
    CL_GROUPS=()
    CL_TOTAL=()
    CL_DONE=()
    CL_SKIP=()
    CL_TODO=()
    CL_SUM_TOTAL=0
    CL_SUM_DONE=0
    CL_SUM_TODO=0

    local state file group label idx i found
    while IFS=$'\t' read -r state file group label; do
        [[ -z "$state" ]] && continue

        idx=-1
        found=0
        i=0
        while (( i < ${#CL_GROUPS[@]} )); do
            if [[ "${CL_FILES[$i]}" == "$file" && "${CL_GROUPS[$i]}" == "$group" ]]; then
                idx=$i
                found=1
                break
            fi
            i=$((i + 1))
        done
        if [[ $found -eq 0 ]]; then
            idx=${#CL_GROUPS[@]}
            CL_FILES[$idx]="$file"
            CL_GROUPS[$idx]="$group"
            CL_TOTAL[$idx]=0
            CL_DONE[$idx]=0
            CL_SKIP[$idx]=0
            CL_TODO[$idx]=""
        fi

        CL_TOTAL[$idx]=$(( ${CL_TOTAL[$idx]} + 1 ))
        CL_SUM_TOTAL=$(( CL_SUM_TOTAL + 1 ))
        case "$state" in
            done)
                CL_DONE[$idx]=$(( ${CL_DONE[$idx]} + 1 ))
                CL_SUM_DONE=$(( CL_SUM_DONE + 1 ))
                ;;
            skip)
                CL_DONE[$idx]=$(( ${CL_DONE[$idx]} + 1 ))
                CL_SKIP[$idx]=$(( ${CL_SKIP[$idx]} + 1 ))
                CL_SUM_DONE=$(( CL_SUM_DONE + 1 ))
                ;;
            todo)
                if [[ -n "${CL_TODO[$idx]}" ]]; then
                    CL_TODO[$idx]="${CL_TODO[$idx]}"$'\n'"$label"
                else
                    CL_TODO[$idx]="$label"
                fi
                CL_SUM_TODO=$(( CL_SUM_TODO + 1 ))
                ;;
        esac
    done < <(
        checklist_scan "$ticket_file" "ticket.md" true
        checklist_scan "$note_file" "note.md"
    )

    return 0
}

# The one line printed under every failure, so the reader always sees both ways
# out: do the thing, or record why it does not apply.
checklist_hint() {
    echo 'Check them, or mark the ones that do not apply as `- [-] ... - skip: <reason>`.'
}

# Width of the group-name column, over the entries a caller selects.
# Usage: _checklist_width <extra> [todo_only]
_checklist_width() {
    local extra="$1"
    local todo_only="${2:-false}"
    local width=0 i name
    i=0
    while (( i < ${#CL_GROUPS[@]} )); do
        if [[ "$todo_only" != "true" || -n "${CL_TODO[$i]}" ]]; then
            name="${CL_GROUPS[$i]}"
            (( ${#name} > width )) && width=${#name}
        fi
        i=$((i + 1))
    done
    echo $((width + extra))
}

# Report every group and what is still empty, split by file. Never fails:
# mid-ticket, the later groups being empty is the normal state, and a check
# that always failed on day one would just be turned off.
#
# Usage: checklist_report <ticket-file> <note-file>
checklist_report() {
    checklist_aggregate "$1" "$2"
    [[ $CL_SUM_TOTAL -eq 0 ]] && return 0

    local width
    width=$(_checklist_width 4)

    echo ""
    echo "Checklist: ${CL_SUM_DONE} / ${CL_SUM_TOTAL}"

    local i=0 current="" name pad line label
    while (( i < ${#CL_GROUPS[@]} )); do
        if [[ "${CL_FILES[$i]}" != "$current" ]]; then
            current="${CL_FILES[$i]}"
            echo "  ${current}"
        fi
        name="${CL_GROUPS[$i]}"
        pad=""
        while (( ${#name} + ${#pad} < width )); do pad="${pad} "; done
        line="    ${name}${pad}${CL_DONE[$i]} / ${CL_TOTAL[$i]}"
        if [[ "${CL_DONE[$i]}" == "${CL_TOTAL[$i]}" ]]; then
            line="${line}  done"
            if (( ${CL_SKIP[$i]} > 0 )); then
                line="${line} (${CL_SKIP[$i]} skipped)"
            fi
        fi
        echo "$line"
        if [[ -n "${CL_TODO[$i]}" ]]; then
            while IFS= read -r label; do
                echo "        - ${label}"
            done <<< "${CL_TODO[$i]}"
        fi
        i=$((i + 1))
    done

    return 0
}

# Evaluate one group by name over the aggregate already in CL_*, and leave the
# answer in CLG_*:
#
#   CLG_MATCHED   1 when at least one group carries that heading
#   CLG_TOTAL  CLG_DONE  CLG_SKIP
#   CLG_TODO      newline-separated labels of the unchecked ones
#
# A heading with no checkboxes under it never becomes a group at all (see
# checklist_aggregate), so it comes back unmatched. That is what lets the
# callers tell "the section is not there" from "the section is finished" -
# counting unchecked boxes cannot, because both come to zero.
_checklist_group_eval() {
    local want="$1"

    CLG_MATCHED=0
    CLG_TOTAL=0
    CLG_DONE=0
    CLG_SKIP=0
    CLG_TODO=""

    local i=0
    while (( i < ${#CL_GROUPS[@]} )); do
        if [[ "${CL_GROUPS[$i]}" == "$want" ]]; then
            CLG_MATCHED=1
            CLG_TOTAL=$(( CLG_TOTAL + ${CL_TOTAL[$i]} ))
            CLG_DONE=$(( CLG_DONE + ${CL_DONE[$i]} ))
            CLG_SKIP=$(( CLG_SKIP + ${CL_SKIP[$i]} ))
            if [[ -n "${CL_TODO[$i]}" ]]; then
                if [[ -n "$CLG_TODO" ]]; then
                    CLG_TODO="${CLG_TODO}"$'\n'"${CL_TODO[$i]}"
                else
                    CLG_TODO="${CL_TODO[$i]}"
                fi
            fi
        fi
        i=$((i + 1))
    done

    return 0
}

# The groups that do exist, printed under a failure so the reader can see what
# the name should have been.
_checklist_print_groups() {
    if [[ ${#CL_GROUPS[@]} -eq 0 ]]; then
        echo "Neither the ticket nor the note has any checkboxes."
        return 0
    fi

    echo "Groups that do exist:"
    local current="" i=0
    while (( i < ${#CL_GROUPS[@]} )); do
        if [[ "${CL_FILES[$i]}" != "$current" ]]; then
            current="${CL_FILES[$i]}"
            echo "  ${current}"
        fi
        echo "    - ${CL_GROUPS[$i]}"
        i=$((i + 1))
    done
    return 0
}

# Judge a single group, named by the caller. The caller is the one that knows
# which stage the work is at; ticket.sh only has to match a string.
#
# The name is matched against heading text alone, with no file qualifier: a
# group by that name in EITHER file is judged, and both together if it appears
# in both. Callers say which stage they expect to be finished, not which file
# the author chose to keep it in.
#
# A name that matches nothing is a failure, not a pass. Letting it pass would
# turn a typo into a check that always succeeds - the caller would believe it
# is enforcing something while nothing is being looked at, which is the same
# hole this whole feature exists to close.
#
# Usage: checklist_require <ticket-file> <note-file> <group-name>
checklist_require() {
    local ticket_file="$1"
    local note_file="$2"
    local want="$3"

    checklist_aggregate "$ticket_file" "$note_file"
    _checklist_group_eval "$want"

    if [[ $CLG_MATCHED -eq 0 ]]; then
        echo "✗ No checklist group named \"${want}\""
        echo ""
        _checklist_print_groups
        return 1
    fi

    if [[ -z "$CLG_TODO" ]]; then
        local msg="✓ ${want}: ${CLG_DONE} / ${CLG_TOTAL}"
        if (( CLG_SKIP > 0 )); then
            msg="${msg}  (${CLG_SKIP} skipped)"
        fi
        echo "$msg"
        return 0
    fi

    echo "✗ ${want}: ${CLG_DONE} / ${CLG_TOTAL}"
    echo ""
    echo "  Unchecked"
    local label
    while IFS= read -r label; do
        echo "    - ${label}"
    done <<< "$CLG_TODO"
    echo ""
    checklist_hint
    return 1
}

# Judge the groups the config declares must be there - the
# `require_checklist_groups` key. Used by close's preflight.
#
# This is the half `require_checklist` cannot cover. That one counts unchecked
# boxes, so a section that is not in the file at all contributes nothing and
# reads exactly like a section where everything got done: close passes, and
# nothing in the output says the check looked at nothing. Naming the section
# here turns its absence into a refusal, the same way checklist_require already
# treats a name that matches nothing as a failure rather than a pass.
#
# What is refused, per declared name:
#   - no heading by that name in either file          -> missing
#   - a heading by that name with no checkboxes under -> missing (same thing,
#     as far as the aggregate is concerned, and the same thing to a reader:
#     there is nothing there to have been judged)
#   - checkboxes by that name still unchecked         -> unfinished
#
# The last one overlaps with require_checklist when that is on. It is here
# anyway, because the two keys are independent: declaring a group is the opt-in
# for that group, whether or not the whole-file gate is switched on.
#
# Prints nothing when every declared name is present and settled. Writes to
# stdout; close redirects it to stderr alongside its other refusals.
#
# Usage: checklist_require_groups <ticket-file> <note-file> <name>...
checklist_require_groups() {
    local ticket_file="$1"
    local note_file="$2"
    shift 2
    [[ $# -eq 0 ]] && return 0

    checklist_aggregate "$ticket_file" "$note_file"

    local want missing="" unfinished="" failed=0
    for want in "$@"; do
        [[ -z "$want" ]] && continue
        _checklist_group_eval "$want"
        if [[ $CLG_MATCHED -eq 0 ]]; then
            missing="${missing}${want}"$'\n'
            failed=1
        elif [[ -n "$CLG_TODO" ]]; then
            unfinished="${unfinished}${want}"$'\n'
            failed=1
        fi
    done
    [[ $failed -eq 0 ]] && return 0

    local name label
    if [[ -n "$missing" ]]; then
        local count=0
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            count=$((count + 1))
        done <<< "$missing"
        local noun="required checklist groups are missing"
        [[ $count -eq 1 ]] && noun="required checklist group is missing"
        echo "✗ ${count} ${noun}"
        echo ""
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            echo "    - ${name}"
        done <<< "$missing"
        echo ""
        echo "Declared in config under \`require_checklist_groups\`. A group is a heading"
        echo "with at least one checkbox under it, in the ticket body or the note."
        echo ""
        _checklist_print_groups
    fi

    if [[ -n "$unfinished" ]]; then
        [[ -n "$missing" ]] && echo ""
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            _checklist_group_eval "$name"
            echo "✗ ${name}: ${CLG_DONE} / ${CLG_TOTAL}"
            echo ""
            echo "  Unchecked"
            while IFS= read -r label; do
                echo "    - ${label}"
            done <<< "$CLG_TODO"
            echo ""
        done <<< "$unfinished"
        checklist_hint
    fi

    return 1
}

# Show where the declared groups stand, without judging. `check` is
# deliberately a command that never fails - mid-ticket, the later groups being
# empty is the normal state - so a missing required group is shown here and
# refused at close.
#
# Usage: checklist_report_groups <ticket-file> <note-file> <name>...
checklist_report_groups() {
    local ticket_file="$1"
    local note_file="$2"
    shift 2
    [[ $# -eq 0 ]] && return 0

    checklist_aggregate "$ticket_file" "$note_file"

    local want width=0
    for want in "$@"; do
        [[ -z "$want" ]] && continue
        (( ${#want} > width )) && width=${#want}
    done
    width=$((width + 4))

    echo ""
    echo "Required groups"

    local pad line
    for want in "$@"; do
        [[ -z "$want" ]] && continue
        _checklist_group_eval "$want"
        pad=""
        while (( ${#want} + ${#pad} < width )); do pad="${pad} "; done
        if [[ $CLG_MATCHED -eq 0 ]]; then
            line="    ${want}${pad}missing  (close will refuse)"
        else
            line="    ${want}${pad}${CLG_DONE} / ${CLG_TOTAL}"
            if [[ -z "$CLG_TODO" ]]; then
                line="${line}  done"
                if (( CLG_SKIP > 0 )); then
                    line="${line} (${CLG_SKIP} skipped)"
                fi
            fi
        fi
        echo "$line"
    done

    return 0
}

# Judge every group in both files. Used by close's preflight.
# Succeeds when there are no checkboxes at all, so projects that put none in
# either template are unaffected.
#
# Usage: checklist_gate <ticket-file> <note-file>
checklist_gate() {
    checklist_aggregate "$1" "$2"
    [[ $CL_SUM_TODO -eq 0 ]] && return 0

    local width
    width=$(_checklist_width 3 true)

    local noun="items remain"
    [[ $CL_SUM_TODO -eq 1 ]] && noun="item remains"
    echo "✗ ${CL_SUM_TODO} unchecked ${noun}" >&2
    echo "" >&2

    local i=0 current="" name pad count label
    while (( i < ${#CL_GROUPS[@]} )); do
        if [[ -n "${CL_TODO[$i]}" ]]; then
            if [[ "${CL_FILES[$i]}" != "$current" ]]; then
                current="${CL_FILES[$i]}"
                echo "  ${current}" >&2
            fi
            name="${CL_GROUPS[$i]}"
            pad=""
            while (( ${#name} + ${#pad} < width )); do pad="${pad} "; done
            count=0
            while IFS= read -r label; do count=$((count + 1)); done <<< "${CL_TODO[$i]}"
            echo "    ${name}${pad}${count}" >&2
            while IFS= read -r label; do
                echo "        - ${label}" >&2
            done <<< "${CL_TODO[$i]}"
        fi
        i=$((i + 1))
    done
    echo "" >&2
    checklist_hint >&2
    return 1
}
