#!/usr/bin/env bash
# ==============================================================================
# Tests for git-recap
# ==============================================================================
# shellcheck disable=SC2005  # echo "$(func)" needed — our printf helpers don't add newlines

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_RECAP="${SCRIPT_DIR}/script.sh"

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
# Unit tests (source script without running main)
# ==============================================================================

echo ""
echo "$(_bold "=== git-recap tests ===")"
echo ""

echo "$(_bold "Unit tests")"
echo ""

# Source the script without set -e and without running main
_GR_TMP=$(mktemp)
sed -e '/^set -euo pipefail$/d' -e '/^main "\$@"$/d' "$GIT_RECAP" > "$_GR_TMP"
# shellcheck disable=SC1090
source "$_GR_TMP"
rm -f "$_GR_TMP"

# ---------- portable_date ----------

echo "$(_bold "  portable_date")"

out=$(portable_date first_of_month 0)
assert_contains "first_of_month format has T00:00:00" "$out" "T00:00:00"
assert_contains "first_of_month day is 01" "$out" "-01T"

out=$(portable_date first_of_next_month)
assert_contains "first_of_next_month format has T00:00:00" "$out" "T00:00:00"
assert_contains "first_of_next_month day is 01" "$out" "-01T"

out=$(portable_date month_label 0)
current_year=$(date +%Y)
assert_contains "month_label contains year" "$out" "$current_year"

out=$(portable_date month_label_from "2026-01-15")
assert_contains "month_label_from January" "$out" "January"
assert_contains "month_label_from 2026" "$out" "2026"

echo ""

# ---------- resolve_repo (SSH URL) ----------

echo "$(_bold "  resolve_repo (SSH URL)")"

out=$(
    ARG_REPO="git@github.com:maxgfr/subtool.git"
    REPO_MODE="" REPO_FULL="" REPO_NAME="" USER_NAME="test"
    resolve_repo 2>/dev/null
    echo "${REPO_FULL}|${REPO_NAME}|${REPO_MODE}"
)
assert_eq "SSH URL resolves correctly" "maxgfr/subtool|subtool|remote" "$out"

out=$(
    # shellcheck disable=SC2034
    ARG_REPO="git@github.com:owner/repo"
    # shellcheck disable=SC2034
    REPO_MODE="" REPO_FULL="" REPO_NAME="" USER_NAME="test"
    resolve_repo 2>/dev/null
    echo "${REPO_FULL}|${REPO_NAME}|${REPO_MODE}"
)
assert_eq "SSH URL without .git resolves" "owner/repo|repo|remote" "$out"

echo ""

# ---------- compute_stats ----------

echo "$(_bold "  compute_stats")"

input=$'abc1234\tfirst commit\t2026-03-01\nabc1235\tsecond commit\t2026-03-01\nabc1236\tthird commit\t2026-03-15'
out=$(compute_stats "$input")
assert_contains "stats total=3" "$out" "3|"
assert_contains "stats first date" "$out" "2026-03-01"
assert_contains "stats last date" "$out" "2026-03-15"
assert_contains "stats busiest day is 2026-03-01" "$out" "|2026-03-01|"
assert_contains "stats busiest count is 2" "$out" "|2|"
assert_contains "stats active days=2" "$out" "|2|"
assert_contains "stats avg per day=1.5" "$out" "|1.5"

# Single commit
input=$'abc1234\tonly commit\t2026-05-10'
out=$(compute_stats "$input")
assert_contains "single commit total=1" "$out" "1|"
assert_contains "single commit date" "$out" "2026-05-10"
assert_contains "single commit active days=1" "$out" "|1|"
assert_contains "single commit avg per day=1.0" "$out" "|1.0"

echo ""

# ==============================================================================
# Integration tests
# ==============================================================================

echo "$(_bold "CLI basics")"

# 1. --help
out=$("$GIT_RECAP" --help 2>/dev/null)
assert_exit "--help exits 0" 0 "$GIT_RECAP" --help
assert_contains "--help shows usage" "$out" "Usage:"
assert_contains "--help shows options" "$out" "# Options"
assert_not_contains "--help no longer documents --provider" "$out" "--provider"
assert_contains "--help points to the agent skill" "$out" "npx skills add maxgfr/git-recap"
assert_contains "--help shows json format" "$out" "json"
assert_contains "--help shows SSH example" "$out" "git@github.com"

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

# 6. Removed AI flags point to the agent skill
for removed_flag in --provider --model --lang --voice; do
    assert_exit "$removed_flag exits 1" 1 "$GIT_RECAP" "$removed_flag" value somerepo
    err=$("$GIT_RECAP" "$removed_flag" value somerepo 2>&1 || true)
    assert_contains "$removed_flag error mentions the agent skill" "$err" "agent skill"
done

# 7. --no-ai stays accepted for compatibility
assert_exit "--no-ai with --help exits 0" 0 "$GIT_RECAP" --no-ai --help

echo ""

# ---------- Repo resolution ----------

echo "$(_bold "Repo resolution")"

# 10. owner/repo format
out=$("$GIT_RECAP" -m commits -u testuser maxgfr/subtool 2>&1 || true)
assert_contains "owner/repo resolves correctly" "$out" "Repo: maxgfr/subtool"

# 11. URL format
out=$("$GIT_RECAP" -m commits -u testuser https://github.com/maxgfr/subtool 2>&1 || true)
assert_contains "URL resolves correctly" "$out" "Repo: maxgfr/subtool"

# 12. Repo name only (prefixed with username)
out=$("$GIT_RECAP" -m commits -u maxgfr mytestrepo 2>&1 || true)
assert_contains "repo name prefixed with user" "$out" "Repo: maxgfr/mytestrepo"

# 13. SSH URL
out=$("$GIT_RECAP" -m commits -u testuser git@github.com:maxgfr/subtool.git 2>&1 || true)
assert_contains "SSH URL resolves correctly" "$out" "Repo: maxgfr/subtool"

# 14. Local repository without an origin uses its current branch
local_repo=$(mktemp -d /tmp/git-recap-local.XXXXXX)
git -C "$local_repo" init -q -b master
git -C "$local_repo" config user.name "Recap Tester"
git -C "$local_repo" config user.email "recap@example.invalid"
git -C "$local_repo" commit -q --allow-empty -m "feat: local-only commit"
out=$("$GIT_RECAP" --no-ai -m commits -p all -u "Recap Tester" "$local_repo" 2>&1)
assert_contains "local repo without origin is accepted" "$out" "Local repo:"
assert_contains "local repo uses current branch" "$out" "Branch: master"
assert_contains "local repo returns its commits" "$out" "local-only commit"

mkdir -p "$local_repo/empty-home"
out=$(HOME="$local_repo/empty-home" "$GIT_RECAP" --no-ai -m commits -p all "$local_repo" 2>&1)
assert_contains "local repo infers author from repository config" "$out" "User: Recap Tester"
assert_contains "local repo without GitHub identity returns commits" "$out" "local-only commit"

mkdir -p "$local_repo/docs"
out=$("$GIT_RECAP" --no-ai -m commits -p all -u "Recap Tester" "$local_repo/docs" 2>&1)
assert_contains "local repo subdirectory resolves to repository root" "$out" "Local repo: $(basename "$local_repo")"
out=$("$GIT_RECAP" --no-ai -f markdown -m commits -p all -u "Recap Tester" "$local_repo" 2>&1)
assert_not_contains "local-only markdown hash has no fabricated GitHub link" "$out" "https://github.com/$(basename "$local_repo")/commit/"

# 15. Git worktrees are recognized as local repositories
worktree_repo=$(mktemp -d /tmp/git-recap-worktree-base.XXXXXX)
worktree_path=$(mktemp -d /tmp/git-recap-worktree.XXXXXX)
rmdir "$worktree_path"
git -C "$worktree_repo" init -q -b main
git -C "$worktree_repo" config user.name "Recap Tester"
git -C "$worktree_repo" config user.email "recap@example.invalid"
git -C "$worktree_repo" commit -q --allow-empty -m "feat: base commit"
git -C "$worktree_repo" worktree add -q -b feature "$worktree_path"
git -C "$worktree_path" commit -q --allow-empty -m "feat: worktree commit"
out=$("$GIT_RECAP" --no-ai -m commits -p all -u "Recap Tester" "$worktree_path" 2>&1)
assert_contains "worktree is accepted as a local repo" "$out" "Local repo:"
assert_contains "worktree uses its current branch" "$out" "Branch: feature"
assert_contains "worktree returns its commits" "$out" "worktree commit"

rm -rf "$local_repo"
git -C "$worktree_repo" worktree remove --force "$worktree_path"
rm -rf "$worktree_repo"

echo ""

# ---------- Period computation ----------

echo "$(_bold "Period computation")"

# 16. current period
out=$("$GIT_RECAP" -m commits -p current -u testuser maxgfr/subtool 2>&1 || true)
current_month=$(portable_date month_label 0)
assert_contains "period current shows current month" "$out" "$current_month"

# 17. last period
out=$("$GIT_RECAP" -m commits -p last -u testuser maxgfr/subtool 2>&1 || true)
last_month=$(portable_date month_label -1)
assert_contains "period last shows last month" "$out" "$last_month"

# 18. YYYY-MM period
out=$("$GIT_RECAP" -m commits -p 2026-01 -u testuser maxgfr/subtool 2>&1 || true)
assert_contains "YYYY-MM period: correct SINCE" "$out" "2026-01-01"
assert_contains "YYYY-MM period: correct UNTIL" "$out" "2026-02-01"

# 19. Numeric month (december rollover)
out=$("$GIT_RECAP" -m commits -p 12 -u testuser maxgfr/subtool 2>&1 || true)
assert_contains "numeric period shows Period:" "$out" "Period:"

echo ""

# ---------- Fetch commits (integration) ----------

echo "$(_bold "Fetch commits (integration)")"

# 20. Fetch commits from maxgfr/subtool
out=$("$GIT_RECAP" -m commits -p 2025-01 -u maxgfr maxgfr/subtool 2>&1)
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

# ---------- No built-in AI ----------

echo "$(_bold "No built-in AI")"

noai_dir=$(mktemp -d /tmp/git-recap-noai.XXXXXX)
mkdir -p "$noai_dir/bin" "$noai_dir/repo" "$noai_dir/home"
git -C "$noai_dir/repo" init -q -b main
git -C "$noai_dir/repo" config user.name "Recap Tester"
git -C "$noai_dir/repo" config user.email "recap@example.invalid"
git -C "$noai_dir/repo" commit -q --allow-empty -m "feat: first raw message"
git -C "$noai_dir/repo" commit -q --allow-empty -m "fix: second raw message"

# Fake AI CLIs record any invocation
for ai_cli in claude codex; do
    printf '#!/usr/bin/env bash\ntouch "%s/%s-called"\necho "AI OUTPUT"\n' "$noai_dir" "$ai_cli" > "$noai_dir/bin/$ai_cli"
    chmod +x "$noai_dir/bin/$ai_cli"
done
printf '%s\n' 'GIT_RECAP_PROVIDER="claude"' 'GIT_RECAP_MODEL="sonnet"' 'GIT_RECAP_LANG="fr"' 'GIT_RECAP_VOICE="we"' > "$noai_dir/home/.git-recaprc"

out=$(HOME="$noai_dir/home" PATH="$noai_dir/bin:$PATH" \
    "$GIT_RECAP" -m all -p all -u "Recap Tester" "$noai_dir/repo" 2>&1)
assert_eq "claude CLI is never called" "no" "$([[ -e "$noai_dir/claude-called" ]] && echo yes || echo no)"
assert_eq "codex CLI is never called" "no" "$([[ -e "$noai_dir/codex-called" ]] && echo yes || echo no)"
assert_not_contains "no AI output in recap" "$out" "AI OUTPUT"
assert_not_contains "no Summary section without the skill" "$out" "--- Summary ---"
assert_contains "raw commit messages are used as bullets" "$out" "• fix: second raw message"
assert_not_contains "text output does not print a Unicode escape literally" "$out" '\u2022'
assert_not_contains "legacy AI config keys are ignored silently" "$out" "Ignoring unrecognized config line"

out=$("$GIT_RECAP" -f json -m all -p all -u "Recap Tester" "$noai_dir/repo" 2>/dev/null)
assert_eq "json bullets are raw commit messages" "fix: second raw message|feat: first raw message" "$(echo "$out" | jq -r '.bullets | join("|")')"
assert_eq "json has no summary field" "false" "$(echo "$out" | jq 'has("summary")')"

out=$("$GIT_RECAP" --team -f json -m all -p all "$noai_dir/repo" 2>/dev/null)
assert_eq "team json has no team_summary field" "false" "$(echo "$out" | jq 'has("team_summary")')"
assert_eq "team json contributors have no summary field" "false" "$(echo "$out" | jq '.contributors[0] | has("summary")')"

out_noai=$("$GIT_RECAP" --no-ai -m all -p all -u "Recap Tester" "$noai_dir/repo" 2>/dev/null)
out_default=$("$GIT_RECAP" -m all -p all -u "Recap Tester" "$noai_dir/repo" 2>/dev/null)
assert_eq "--no-ai is a no-op" "$out_default" "$out_noai"

rm -rf "$noai_dir"

echo ""

# ---------- Agent skill ----------

echo "$(_bold "Agent skill")"

SKILL_DIR="${SCRIPT_DIR}/skills/git-recap"
TOTAL=$((TOTAL + 1))
if cmp -s "$GIT_RECAP" "$SKILL_DIR/scripts/git-recap.sh"; then
    PASS=$((PASS + 1))
    printf '  %s %s\n' "$(_green "PASS")" "bundled skill script matches script.sh"
else
    FAIL=$((FAIL + 1))
    printf '  %s %s\n' "$(_red "FAIL")" "bundled skill script matches script.sh (run: cp script.sh skills/git-recap/scripts/git-recap.sh)"
fi
skill_md=$(cat "$SKILL_DIR/SKILL.md")
assert_eq "SKILL.md starts with frontmatter" "---" "$(head -1 "$SKILL_DIR/SKILL.md")"
assert_contains "SKILL.md declares its name" "$skill_md" "name: git-recap"
assert_contains "SKILL.md declares a description" "$skill_md" "description: "

echo ""

# ---------- Mode filtering ----------

echo "$(_bold "Mode filtering")"

# 19. Mode commits
out=$("$GIT_RECAP" --no-ai -m commits -p 2025-04 -u maxgfr maxgfr/subtool 2>&1)
if [[ "$out" == *"No commits"* ]]; then
    assert_contains "mode commits: no summary in empty" "$out" "Recap"
    assert_not_contains "mode commits: no Summary section" "$out" "Summary"
else
    assert_contains "mode commits: output has Commits" "$out" "Commits"
    assert_not_contains "mode commits: no Summary section" "$out" "Summary"
fi

# 20. Mode bullets
out=$("$GIT_RECAP" --no-ai -m bullets -p 2025-04 -u maxgfr maxgfr/subtool 2>&1)
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

# 21. Markdown format
out=$("$GIT_RECAP" --no-ai -m commits -p 2025-01 -f markdown -u maxgfr maxgfr/subtool 2>&1)
assert_contains "markdown format: has # header" "$out" "#"

# 22. Text format
out=$("$GIT_RECAP" --no-ai -m commits -p 2025-01 -f text -u maxgfr maxgfr/subtool 2>&1)
assert_contains "text format: has === header" "$out" "==="

# 23. Markdown commit links
if [[ "$out" != *"No commits"* ]]; then
    md_out=$("$GIT_RECAP" --no-ai -m commits -p 2025-01 -f markdown -u maxgfr maxgfr/subtool 2>/dev/null || true)
    if [[ "$md_out" == *"github.com"* ]]; then
        assert_contains "markdown has commit links" "$md_out" "https://github.com/maxgfr/subtool/commit/"
    fi
fi

echo ""

# ---------- JSON format ----------

echo "$(_bold "JSON format")"

# 24. JSON output is valid
if command -v jq &>/dev/null; then
    json_out=$("$GIT_RECAP" --no-ai -f json -m commits -p 2025-01 -u maxgfr maxgfr/subtool 2>/dev/null)
    if echo "$json_out" | jq . >/dev/null 2>&1; then
        TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
        printf '  %s %s\n' "$(_green "PASS")" "-f json produces valid JSON"
    else
        TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
        printf '  %s %s\n' "$(_red "FAIL")" "-f json produces valid JSON"
    fi

    # 25. JSON has expected fields
    assert_contains "json has repo field" "$json_out" '"repo"'
    assert_contains "json has period field" "$json_out" '"period"'
    assert_contains "json has user field" "$json_out" '"user"'
    if [[ "$json_out" != *'"commits": []'* ]]; then
        assert_contains "json has stats field" "$json_out" '"stats"'
    else
        TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
        printf '  %s %s\n' "$(_green "PASS")" "json stats: no commits (skip)"
    fi

    # 26. JSON empty commits
    json_empty=$("$GIT_RECAP" --no-ai -f json -m commits -p 2020-01 -u maxgfr maxgfr/subtool 2>/dev/null)
    if echo "$json_empty" | jq . >/dev/null 2>&1; then
        TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
        printf '  %s %s\n' "$(_green "PASS")" "-f json with no commits is valid JSON"
    else
        TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
        printf '  %s %s\n' "$(_red "FAIL")" "-f json with no commits is valid JSON"
    fi
else
    echo "  SKIP: jq not installed, skipping JSON tests"
fi

echo ""

# ---------- --no-ai ----------

echo "$(_bold "--no-ai flag")"

# 27. --no-ai skips summary
out=$("$GIT_RECAP" --no-ai -m all -p 2025-04 -u maxgfr -f text maxgfr/subtool 2>&1)
if [[ "$out" != *"No commits"* ]]; then
    assert_not_contains "--no-ai: no Summary section" "$out" "--- Summary ---"
    assert_contains "--no-ai: Changes section present (raw bullets)" "$out" "Changes"
else
    TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
    printf '  %s %s\n' "$(_green "PASS")" "--no-ai: no commits to verify (skip)"
fi

echo ""

# ---------- Stats section ----------

echo "$(_bold "Stats section")"

# 28. Stats in text output
out=$("$GIT_RECAP" --no-ai -m commits -p 2025-04 -u maxgfr -f text maxgfr/subtool 2>&1)
if [[ "$out" != *"No commits"* ]]; then
    assert_contains "stats section in text output" "$out" "Stats"
    assert_contains "stats has total commits" "$out" "Total commits"
else
    TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1))
    printf '  %s %s\n' "$(_green "PASS")" "stats: no commits to verify (skip)"
fi

# 29. Stats in markdown output
out=$("$GIT_RECAP" --no-ai -m commits -p 2025-04 -u maxgfr -f markdown maxgfr/subtool 2>&1)
if [[ "$out" != *"No commits"* ]]; then
    assert_contains "stats section in markdown output" "$out" "## Stats"
fi

echo ""

# ---------- Output file ----------

echo "$(_bold "Output file")"

# 30. --output writes file
tmpfile=$(mktemp /tmp/git-recap-test.XXXXXX)
"$GIT_RECAP" --no-ai -m commits -p 2025-01 -u maxgfr -o "$tmpfile" maxgfr/subtool 2>/dev/null || true
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
