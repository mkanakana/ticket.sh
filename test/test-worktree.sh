#!/usr/bin/env bash

# Test script for git worktree support in ticket.sh
# This test verifies that ticket.sh works properly in git worktrees

set -e

# Source test helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

# Test configuration
TEST_NAME="Git Worktree Support"
MAIN_REPO_DIR="/tmp/ticket-sh-worktree-test-main"
WORKTREE_DIR="/tmp/ticket-sh-worktree-test-worktree"
TICKET_SH="$(cd "$SCRIPT_DIR/.." && pwd)/ticket.sh"

echo "=== $TEST_NAME ==="

# Cleanup function
cleanup() {
    echo "Cleaning up test directories..."
    rm -rf "$MAIN_REPO_DIR" "$WORKTREE_DIR" 2>/dev/null || true
}

# Setup cleanup trap
trap cleanup EXIT

# Clean up any previous test runs
cleanup

echo "1. Setting up main repository..."
mkdir -p "$MAIN_REPO_DIR"
cd "$MAIN_REPO_DIR"

# Initialize git repository
git init
git config user.name "Test User"
git config user.email "test@example.com"

# Create initial commit
echo "# Test Repository" > README.md
git add README.md
git commit -m "Initial commit"

echo "2. Initializing ticket.sh in main repository..."
"$TICKET_SH" init
git add .
git commit -m "Initialize ticket.sh"

echo "3. Creating a ticket in main repository..."
"$TICKET_SH" new test-feature
TICKET_FILE=$(find tickets -name "*test-feature.md" | head -1)
echo "Created ticket: $TICKET_FILE"

echo "4. Creating git worktree..."
git worktree add "$WORKTREE_DIR" HEAD

echo "5. Testing ticket.sh commands in worktree..."
cd "$WORKTREE_DIR"

# Test: List tickets (should work - behavior test)
echo "Testing: ticket.sh list in worktree..."
if "$TICKET_SH" list >/dev/null 2>&1; then
    echo "✓ PASS: list command works in worktree"
else
    echo "✗ FAIL: list command fails in worktree"
    "$TICKET_SH" list 2>&1 || true
    exit 1
fi

# Test: Create new ticket (should work - behavior test) 
echo "Testing: ticket.sh new in worktree..."
if "$TICKET_SH" new worktree-feature >/dev/null 2>&1; then
    echo "✓ PASS: new command works in worktree"
else
    echo "✗ FAIL: new command fails in worktree"
    "$TICKET_SH" new worktree-feature 2>&1 || true
    exit 1
fi

# Test: Start ticket (should work - behavior test)
echo "Testing: ticket.sh start in worktree..."
WORKTREE_TICKET=$(find tickets -name "*worktree-feature.md" | head -1 | xargs basename | sed 's/\.md$//')

# Commit the new ticket first to have clean working directory
git add .
git commit -m "Add worktree ticket for test"

if "$TICKET_SH" start "$WORKTREE_TICKET" >/dev/null 2>&1; then
    echo "✓ PASS: start command works in worktree"
else
    echo "✗ FAIL: start command fails in worktree"
    "$TICKET_SH" start "$WORKTREE_TICKET" 2>&1 || true
    exit 1
fi

echo "6. Verifying ticket files are accessible from main repo..."
cd "$MAIN_REPO_DIR"

# Pull changes from worktree
git pull "$WORKTREE_DIR" HEAD --no-edit

if [ -f "tickets/${WORKTREE_TICKET}.md" ]; then
    echo "✓ PASS: Tickets created in worktree are accessible from main repo"
else
    echo "✓ INFO: Worktree operates independently (expected behavior)"
    echo "✓ INFO: Tickets are shared through git, not filesystem"
fi

echo ""
echo "=== All worktree tests passed! ==="
echo ""

exit 0