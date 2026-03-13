#!/usr/bin/env bash
# ==============================================================================
# Tests for git-recap
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_RECAP="${SCRIPT_DIR}/git-recap"

PASS=0
FAIL=0
TOTAL=0

# Colors
_green() { printf '\033[32m%s\033[0m' "$*"; }
_red()   { printf '\033[31m%s\033[0m' "$*"; }
_bold()  { printf '\033[1m%s\033[0m' "$*"; }

# ==============================================================================
# Test helpers
# ==============================================================================

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        printf '  %s %s\n' "$(_green "PASS")" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf '  %s %s\n' "$(_red "FAIL")" "$desc"
        printf '    expected: %s\n' "$expected"
        printf '    actual:   %s\n' "$actual"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS + 1))
        printf '  %s %s\n' "$(_green "PASS")" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf '  %s %s\n' "$(_red "FAIL")" "$desc"
        printf '    expected to contain: %s\n' "$needle"
        printf '    actual output: %s\n' "$(echo "$haystack" | head -5)"
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        PASS=$((PASS + 1))
        printf '  %s %s\n' "$(_green "PASS")" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf '  %s %s\n' "$(_red "FAIL")" "$desc"
        printf '    expected NOT to contain: %s\n' "$needle"
    fi
}

assert_exit() {
    local desc="$1" expected_code="$2"
    shift 2
    TOTAL=$((TOTAL + 1))
    "$@" >/dev/null 2>&1
    local actual_code=$?
    if [[ "$actual_code" -eq "$expected_code" ]]; then
        PASS=$((PASS + 1))
        printf '  %s %s\n' "$(_green "PASS")" "$desc"
    else
        FAIL=$((FAIL + 1))
        printf '  %s %s\n' "$(_red "FAIL")" "$desc"
        printf '    expected exit code: %s\n' "$expected_code"
        printf '    actual exit code:   %s\n' "$actual_code"
    fi
}

# ==============================================================================
# Tests
# ==============================================================================

echo ""
echo "$(_bold "=== git-recap tests ===")"
echo ""

# ---------- CLI basics ----------

echo "$(_bold "CLI basics")"

# 1. --help
out=$("$GIT_RECAP" --help 2>/dev/null)
assert_exit "--help exits 0" 0 "$GIT_RECAP" --help
assert_contains "--help shows usage" "$out" "Usage:"
assert_contains "--help shows options" "$out" "Options:"

# 2. --version
out=$("$GIT_RECAP" --version 2>/dev/null)
assert_exit "--version exits 0" 0 "$GIT_RECAP" --version
assert_contains "--version shows version" "$out" "git-recap"

# 3. No arguments
assert_exit "no arguments exits 1" 1 "$GIT_RECAP"
err=$("$GIT_RECAP" 2>&1 || true)
assert_contains "no arguments shows error" "$err" "Missing required argument"

# 4. Invalid mode
assert_exit "invalid mode exits 1" 1 "$GIT_RECAP" -m invalid somerepo
err=$("$GIT_RECAP" -m invalid somerepo 2>&1 || true)
assert_contains "invalid mode shows error" "$err" "Invalid mode"

# 5. Invalid format
assert_exit "invalid format exits 1" 1 "$GIT_RECAP" -f xml somerepo
err=$("$GIT_RECAP" -f xml somerepo 2>&1 || true)
assert_contains "invalid format shows error" "$err" "Invalid format"

# 6. Invalid provider
assert_exit "invalid provider exits 1" 1 "$GIT_RECAP" --provider gemini somerepo
err=$("$GIT_RECAP" --provider gemini somerepo 2>&1 || true)
assert_contains "invalid provider shows error" "$err" "Invalid provider"

echo ""

# ---------- Repo resolution ----------

echo "$(_bold "Repo resolution")"

# 7. owner/repo format
# We test by sourcing the functions. Since we can't easily source a set -e script,
# we use the output which prints "Repo: owner/repo"
out=$("$GIT_RECAP" -m commits -u testuser maxgfr/subtool 2>&1 || true)
assert_contains "owner/repo resolves correctly" "$out" "Repo: maxgfr/subtool"

# 8. URL format
out=$("$GIT_RECAP" -m commits -u testuser https://github.com/maxgfr/subtool 2>&1 || true)
assert_contains "URL resolves correctly" "$out" "Repo: maxgfr/subtool"

# 9. Repo name only (prefixed with username)
out=$("$GIT_RECAP" -m commits -u maxgfr mytestrepo 2>&1 || true)
assert_contains "repo name prefixed with user" "$out" "Repo: maxgfr/mytestrepo"

echo ""

# ---------- Period computation ----------

echo "$(_bold "Period computation")"

# 10. current period
out=$("$GIT_RECAP" -m commits -p current -u testuser maxgfr/subtool 2>&1 || true)
current_month=$(LC_ALL=C date +"%B %Y")
assert_contains "period current shows current month" "$out" "$current_month"

# 11. last period
out=$("$GIT_RECAP" -m commits -p last -u testuser maxgfr/subtool 2>&1 || true)
last_month=$(LC_ALL=C date -v-1m +"%B %Y")
assert_contains "period last shows last month" "$out" "$last_month"

# 12. YYYY-MM period
out=$("$GIT_RECAP" -m commits -p 2026-01 -u testuser maxgfr/subtool 2>&1 || true)
assert_contains "YYYY-MM period: correct SINCE" "$out" "2026-01-01"
assert_contains "YYYY-MM period: correct UNTIL" "$out" "2026-02-01"

# 13. Numeric month (december rollover)
out=$("$GIT_RECAP" -m commits -p 12 -u testuser maxgfr/subtool 2>&1 || true)
# 12 months ago should show a valid period label
assert_contains "numeric period shows Period:" "$out" "Period:"

echo ""

# ---------- Fetch commits (integration) ----------

echo "$(_bold "Fetch commits (integration)")"

# 14. Fetch commits from maxgfr/subtool
out=$("$GIT_RECAP" -m commits -p 2025-01 -u maxgfr maxgfr/subtool 2>&1)
# Should contain commit data (TSV format) or "No commits"
if [[ "$out" == *"Commits"* ]] || [[ "$out" == *"No commits"* ]]; then
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    printf '  %s %s\n' "$(_green "PASS")" "fetch commits returns data or empty"
else
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    printf '  %s %s\n' "$(_red "FAIL")" "fetch commits returns data or empty"
    printf '    output: %s\n' "$(echo "$out" | head -5)"
fi

echo ""

# ---------- Mode filtering ----------

echo "$(_bold "Mode filtering")"

# 15. Mode commits
out=$("$GIT_RECAP" -m commits -p 2025-04 -u maxgfr maxgfr/subtool 2>&1)
if [[ "$out" == *"No commits"* ]]; then
    # No commits in this period — check mode filtering still works
    assert_contains "mode commits: no summary in empty" "$out" "Recap"
    assert_not_contains "mode commits: no Summary section" "$out" "Summary"
else
    assert_contains "mode commits: output has Commits" "$out" "Commits"
    assert_not_contains "mode commits: no Summary section" "$out" "Summary"
fi

# 16. Mode bullets
out=$("$GIT_RECAP" -m bullets -p 2025-04 -u maxgfr maxgfr/subtool 2>&1)
if [[ "$out" == *"No commits"* ]]; then
    assert_contains "mode bullets: no commits in empty" "$out" "Recap"
    assert_not_contains "mode bullets: no Commits section" "$out" "Commits"
else
    assert_contains "mode bullets: output has Changes" "$out" "Changes"
    assert_not_contains "mode bullets: no Commits section" "$out" "Commits"
fi

echo ""

# ---------- Format output ----------

echo "$(_bold "Format output")"

# 17. Markdown format
out=$("$GIT_RECAP" -m commits -p 2025-01 -f markdown -u maxgfr maxgfr/subtool 2>&1)
assert_contains "markdown format: has # header" "$out" "#"

# 18. Text format
out=$("$GIT_RECAP" -m commits -p 2025-01 -f text -u maxgfr maxgfr/subtool 2>&1)
assert_contains "text format: has === header" "$out" "==="

echo ""

# ---------- Output file ----------

echo "$(_bold "Output file")"

# 19. --output writes file
tmpfile=$(mktemp /tmp/git-recap-test.XXXXXX)
"$GIT_RECAP" -m commits -p 2025-01 -u maxgfr -o "$tmpfile" maxgfr/subtool 2>/dev/null || true
if [[ -s "$tmpfile" ]]; then
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    printf '  %s %s\n' "$(_green "PASS")" "--output creates file with content"
else
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    printf '  %s %s\n' "$(_red "FAIL")" "--output creates file with content"
fi
rm -f "$tmpfile"

# ==============================================================================
# Results
# ==============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $FAIL -eq 0 ]]; then
    echo "$(_green "All $TOTAL tests passed")"
else
    echo "$(_red "$FAIL/$TOTAL tests failed")"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exit "$FAIL"
