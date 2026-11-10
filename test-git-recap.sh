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
# gh mock
# ==============================================================================
# Remote tests talk to the GitHub API through gh. A mock serves fixtures for the
# deterministic tests, and replaces the real gh for the whole suite when no
# credentials are available (or with GIT_RECAP_OFFLINE=1).
#
#   GH_MOCK_COMMITS         commits fixture (default: commits.json)
#   GH_MOCK_BRANCHES        branches fixture (default: a single "main")
#   GH_MOCK_DEFAULT_BRANCH  default branch name (default: main)
#   GH_MOCK_FAIL            HTTP status to fail api calls with (e.g. 404)
#   GH_MOCK_FAIL_ON         only fail calls whose path contains this (default: all)
#   GH_MOCK_STDERR          line printed on stderr by every api call
#   GH_MOCK_AUTH_RC         exit code of `gh auth status` (default: 0); when not 0,
#                           api calls fail like a logged-out gh
#   GH_MOCK_LOG             file receiving one line per gh invocation
# A fixture named commits-<branch>.json next to the mock is served for sha=<branch>.

mock_dir=$(mktemp -d /tmp/git-recap-mock.XXXXXX)
mkdir -p "$mock_dir/bin"
cat > "$mock_dir/bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
dir="$(cd "$(dirname "$0")/.." && pwd)"
[[ -n "${GH_MOCK_LOG:-}" ]] && printf '%s\n' "$1 ${2:-}" >> "$GH_MOCK_LOG"
[[ "$1" == "auth" ]] && exit "${GH_MOCK_AUTH_RC:-0}"
[[ "$1" == "api" ]] || exit 1
if [[ "${GH_MOCK_AUTH_RC:-0}" -ne 0 ]]; then
    printf '%s\n' "To get started with GitHub CLI, please run:  gh auth login" >&2
    exit 4
fi
path="$2"; shift 2
filter="."
while [[ $# -gt 0 ]]; do
    case "$1" in
        --jq) filter="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n "${GH_MOCK_STDERR:-}" ]] && printf '%s\n' "$GH_MOCK_STDERR" >&2
if [[ -n "${GH_MOCK_FAIL:-}" && "$path" == *"${GH_MOCK_FAIL_ON:-}"* ]]; then
    printf '{"message":"Mock failure","status":"%s"}\n' "$GH_MOCK_FAIL"
    printf 'gh: Mock failure (HTTP %s)\n' "$GH_MOCK_FAIL" >&2
    exit 1
fi
case "$path" in
    user) printf '%s\n' '{"login":"recaptester"}' | jq -r "$filter" ;;
    *"/branches"*)
        if [[ -n "${GH_MOCK_BRANCHES:-}" ]]; then
            jq -r "$filter" "$GH_MOCK_BRANCHES"
        else
            printf '%s\n' '[{"name":"main"}]' | jq -r "$filter"
        fi ;;
    *"/commits"*)
        sha=$(printf '%s\n' "$path" | sed -n 's/.*[?&]sha=\([^&]*\).*/\1/p')
        fixture="${GH_MOCK_COMMITS:-$dir/commits.json}"
        [[ -n "$sha" && -f "$dir/commits-$sha.json" ]] && fixture="$dir/commits-$sha.json"
        jq -r "$filter" "$fixture" ;;
    *) printf '{"default_branch":"%s"}\n' "${GH_MOCK_DEFAULT_BRANCH:-main}" | jq -r "$filter" ;;
esac
MOCK_GH
chmod +x "$mock_dir/bin/gh"
cat > "$mock_dir/commits.json" <<'FIXTURE'
[
  {"sha": "aaaaaaa1111", "parents": [{"sha": "p0"}], "author": {"login": "recaptester"},
   "commit": {"message": "feat: remote feature\n\nWhy: users asked\twith a tab", "author": {"name": "Recap Tester", "date": "2025-03-02T10:00:00Z"}}},
  {"sha": "bbbbbbb2222", "parents": [{"sha": "p0"}, {"sha": "p1"}], "author": {"login": "recaptester"},
   "commit": {"message": "Merge pull request #1 from x/y", "author": {"name": "Recap Tester", "date": "2025-03-03T10:00:00Z"}}},
  {"sha": "ccccccc3333", "parents": [{"sha": "p0"}], "author": {"login": "semantic-release-bot"},
   "commit": {"message": "chore(release): 1.2.0", "author": {"name": "semantic-release-bot", "date": "2025-03-04T10:00:00Z"}}}
]
FIXTURE

if [[ -n "${GIT_RECAP_OFFLINE:-}" ]] || ! command -v gh &>/dev/null || ! gh auth status &>/dev/null; then
    echo "gh credentials unavailable (or GIT_RECAP_OFFLINE set): remote tests use the gh mock"
    export PATH="$mock_dir/bin:$PATH"
fi

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

# ---------- Dates and periods ----------

echo "$(_bold "  dates")"

assert_eq "_jdn of 2000-01-01" "2451545" "$(_jdn 2000-01-01)"
assert_eq "_from_jdn round trip (leap day)" "2024-02-29" "$(_from_jdn "$(_jdn 2024-02-29)")"
assert_eq "_from_jdn crosses a year" "2026-01-01" "$(_from_jdn $(( $(_jdn 2025-12-31) + 1 )))"
assert_eq "_month_shift back over a year" "2025-11" "$(_month_shift 2026-02 -3)"
assert_eq "_month_shift forward over a year" "2027-01" "$(_month_shift 2026-12 1)"
assert_eq "_month_label" "January 2026" "$(_month_label 2026-01)"
assert_eq "_today is a valid date" "yes" "$(_is_valid_date "$(_today)" && echo yes || echo no)"
assert_eq "_is_valid_date rejects Feb 30" "no" "$(_is_valid_date 2025-02-30 && echo yes || echo no)"
assert_eq "_is_valid_date accepts a leap day" "yes" "$(_is_valid_date 2024-02-29 && echo yes || echo no)"

# _period <today> <period> → SINCE|UNTIL|LABEL as computed on that day
_period() {
    (
        pinned_today="$1"
        # shellcheck disable=SC2329  # called by compute_period
        _today() { echo "$pinned_today"; }
        # shellcheck disable=SC2034
        ARG_SINCE="" ARG_UNTIL="" ARG_PERIOD="$2"
        compute_period 2>/dev/null
        echo "${SINCE}|${UNTIL}|${PERIOD_LABEL}"
    )
}

echo "$(_bold "  _urlencode")"

assert_eq "_urlencode keeps unreserved characters and slashes" "feature/a-b_c.d~1" "$(_urlencode "feature/a-b_c.d~1")"
assert_eq "_urlencode escapes query delimiters" "feature/%23123%20a%26b%2Bc%3Dd%25" "$(_urlencode "feature/#123 a&b+c=d%")"
assert_eq "_urlencode escapes brackets" "dependabot%5Bbot%5D" "$(_urlencode "dependabot[bot]")"
assert_eq "_urlencode escapes UTF-8 bytes" "%C3%A9t%C3%A9" "$(_urlencode "été")"

echo "$(_bold "  compute_period")"

assert_eq "current-week on a Monday starts that day" \
    "2026-11-09T00:00:00|2026-11-16T00:00:00|Current week" "$(_period 2026-11-09 current-week)"
assert_eq "current-week on a Sunday" \
    "2026-11-09T00:00:00|2026-11-16T00:00:00|Current week" "$(_period 2026-11-15 current-week)"
assert_eq "current-week across a year boundary" \
    "2025-12-29T00:00:00|2026-01-05T00:00:00|Current week" "$(_period 2026-01-01 current-week)"
assert_eq "last-week on a Monday is the previous Mon-Sun" \
    "2026-11-02T00:00:00|2026-11-09T00:00:00|Last week" "$(_period 2026-11-09 last-week)"
assert_eq "last-week midweek" \
    "2026-11-02T00:00:00|2026-11-09T00:00:00|Last week" "$(_period 2026-11-12 last-week)"
assert_eq "current-month in December rolls into next year" \
    "2026-12-01T00:00:00|2027-01-01T00:00:00|December 2026" "$(_period 2026-12-31 current-month)"
assert_eq "last-month on the 31st names the right month" \
    "2026-02-01T00:00:00|2026-03-01T00:00:00|February 2026" "$(_period 2026-03-31 last-month)"
assert_eq "last-month in January is last December" \
    "2025-12-01T00:00:00|2026-01-01T00:00:00|December 2025" "$(_period 2026-01-15 last-month)"
assert_eq "<N> months on the 31st" \
    "2026-02-01T00:00:00|2026-06-01T00:00:00|February 2026 - May 2026" "$(_period 2026-05-31 3)"
assert_eq "<N> with a leading zero is decimal" \
    "2026-03-01T00:00:00|2026-12-01T00:00:00|March 2026 - November 2026" "$(_period 2026-11-10 08)"
assert_eq "current-year" "2026-01-01T00:00:00|2027-01-01T00:00:00|2026" "$(_period 2026-06-01 current-year)"
assert_eq "last-year" "2025-01-01T00:00:00|2026-01-01T00:00:00|2025" "$(_period 2026-06-01 last-year)"
assert_eq "YYYY-MM in December" "2025-12-01T00:00:00|2026-01-01T00:00:00|December 2025" "$(_period 2026-06-01 2025-12)"
assert_eq "YYYY" "2025-01-01T00:00:00|2026-01-01T00:00:00|2025" "$(_period 2026-06-01 2025)"
assert_eq "all" "||All time" "$(_period 2026-06-01 all)"

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

# _resolve <repo arg> [user] [gh login] → REPO_FULL|REPO_NAME|REPO_WEB_URL, or "died"
_resolve() {
    (
        gh_login="${3:-}"
        # shellcheck disable=SC2329  # called by resolve_repo
        detect_github_user() { [[ -z "$gh_login" ]] || echo "$gh_login"; }
        # shellcheck disable=SC2034
        ARG_REPO="$1" USER_NAME="${2:-}" REPO_MODE="" REPO_FULL="" REPO_NAME=""
        resolve_repo 2>/dev/null
        echo "${REPO_FULL}|${REPO_NAME}|${REPO_WEB_URL}"
    ) || echo "died"
}
assert_eq "browser URL keeps owner/repo only" "maxgfr/subtool|subtool|https://github.com/maxgfr/subtool" "$(_resolve "https://github.com/maxgfr/subtool/tree/main/src")"
assert_eq "URL with .git and trailing slash" "maxgfr/subtool|subtool|https://github.com/maxgfr/subtool" "$(_resolve "https://github.com/maxgfr/subtool.git/")"
assert_eq "repo name with dots" "maxgfr/my.repo-1|my.repo-1|https://github.com/maxgfr/my.repo-1" "$(_resolve "maxgfr/my.repo-1")"
assert_eq "bare name uses the user" "me/thing|thing|https://github.com/me/thing" "$(_resolve "thing" "me")"
assert_eq "bare name without a user is rejected" "died" "$(_resolve "thing")"
assert_eq "bare name falls back to the gh login" "ghme/thing|thing|https://github.com/ghme/thing" "$(_resolve "thing" "" "ghme")"
assert_eq "extra path segments are rejected" "died" "$(_resolve "owner/repo/extra")"
assert_eq "characters GitHub does not allow are rejected" "died" "$(_resolve "owner/re po?x=1")"
assert_eq "missing absolute path is not a GitHub repo" "died" "$(_resolve "/no/such/path")"
assert_eq "missing relative path is not a GitHub repo" "died" "$(_resolve "./nope")"

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

assert_eq "stats, every field" "3|2026-03-01|2026-03-15|2026-03-01|2|2|1.5|Sunday|1" "$out"

# Ties: the latest day wins, and the first weekday of the week (Sunday first)
input=$'abc1234\tone\t2026-03-03\nabc1235\ttwo\t2026-03-02'
assert_eq "stats tie-breaking and a two-day streak" "2|2026-03-02|2026-03-03|2026-03-03|1|2|1.0|Monday|2" "$(compute_stats "$input")"

# Streaks across a year boundary and a leap day, input in any order
input=$'a1\tx\t2024-02-29\na2\tx\t2023-12-31\na3\tx\t2024-03-01\na4\tx\t2024-01-01\na5\tx\t2024-02-28'
assert_eq "stats streak over a leap day" "5|2023-12-31|2024-03-01|2024-03-01|1|5|1.0|Sunday|3" "$(compute_stats "$input")"

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
current_month=$(LC_ALL=C date +"%B %Y")
assert_contains "period current shows current month" "$out" "$current_month"

# 17. last period
out=$("$GIT_RECAP" -m commits -p last -u testuser maxgfr/subtool 2>&1 || true)
last_month=$(_month_label "$(_month_shift "$(date +%Y-%m)" -1)")
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

# ---------- Recap data ----------

echo "$(_bold "Recap data")"

data_dir=$(mktemp -d /tmp/git-recap-data.XXXXXX)
data_repo="$data_dir/repo"
mkdir -p "$data_repo"
git -C "$data_repo" init -q -b main
git -C "$data_repo" config user.email "recap@example.invalid"

# _data_commit <date> <author> <subject> [body]
_data_commit() {
    local date="$1" author="$2" subject="$3" body="${4:-}"
    local msg_args=(-m "$subject")
    [[ -n "$body" ]] && msg_args+=(-m "$body")
    printf '%s\n' "$subject" >> "$data_repo/notes.txt"
    git -C "$data_repo" add notes.txt
    GIT_AUTHOR_DATE="${date}T12:00:00" GIT_COMMITTER_DATE="${date}T12:00:00" \
        git -C "$data_repo" -c user.name="$author" commit -q "${msg_args[@]}"
}
_data_commit 2025-01-10 "Recap Tester" "feat: add login page" $'Adds the OAuth flow.\n\nCloses #12'
_data_commit 2025-01-20 "Recap Tester" "chore(release): 1.0.0"
_data_commit 2025-01-21 "semantic-release-bot" "docs: update changelog"
_data_commit 2025-01-22 "dependabot[bot]" "build(deps): bump foo"
_data_commit 2025-02-10 "Jane Doe" "fix: crash on save"
_data_commit 2025-02-11 "Recap Tester" "feat: export csv"

# Team mode: author names with spaces, bots and release commits skipped
out=$("$GIT_RECAP" --team -f json -m all -p all "$data_repo" 2>/dev/null)
assert_eq "team keeps full author names with spaces" "Jane Doe,Recap Tester" "$(echo "$out" | jq -r '[.contributors[].user] | sort | join(",")')"
assert_eq "team author with spaces gets its commits" "2" "$(echo "$out" | jq '.contributors[] | select(.user == "Recap Tester") | .bullets | length')"
assert_eq "bots and release commits are skipped" "3" "$(echo "$out" | jq '.global_stats.total_commits')"
assert_eq "team global stats include lines added" "3" "$(echo "$out" | jq '.global_stats.lines_added')"

out=$("$GIT_RECAP" --team --all-commits -f json -m all -p all "$data_repo" 2>/dev/null)
assert_eq "--all-commits keeps bots and release commits" "6" "$(echo "$out" | jq '.global_stats.total_commits')"

out=$("$GIT_RECAP" --team --exclude-author "jane*" -f json -m all -p all "$data_repo" 2>/dev/null)
assert_eq "--exclude-author removes matching authors" "Recap Tester" "$(echo "$out" | jq -r '[.contributors[].user] | join(",")')"

out=$("$GIT_RECAP" --team -m all -p all "$data_repo" 2>&1)
assert_contains "team text ranks authors with spaces" "$out" "Recap Tester"
assert_contains "skipped commits are reported on stderr" "$out" "Skipped 3"

# Single mode JSON: release commit skipped, body + numstat present
out=$("$GIT_RECAP" -f json -m all -p all -u "Recap Tester" "$data_repo" 2>/dev/null)
assert_eq "single mode skips release commits" "feat: export csv|feat: add login page" "$(echo "$out" | jq -r '[.commits[].message] | join("|")')"
assert_eq "json commit carries its body" $'Adds the OAuth flow.\n\nCloses #12' "$(echo "$out" | jq -r '.commits[] | select(.message == "feat: add login page") | .body')"
assert_eq "json commit without body has empty body" "" "$(echo "$out" | jq -r '.commits[0].body')"
assert_eq "json commit lists changed files" "notes.txt:1:0" "$(echo "$out" | jq -r '.commits[0].files[0] | "\(.path):\(.additions):\(.deletions)"')"
assert_eq "json stats include change totals" "2|0|1" "$(echo "$out" | jq -r '.stats | "\(.lines_added)|\(.lines_deleted)|\(.files_changed)"')"

out=$("$GIT_RECAP" -m all -p all -u "Recap Tester" "$data_repo" 2>/dev/null)
assert_not_contains "text output does not include commit bodies" "$out" "OAuth flow"

# Custom date range
out=$("$GIT_RECAP" -f json -m commits --since 2025-01-01 --until 2025-01-31 -u "Recap Tester" "$data_repo" 2>/dev/null)
assert_eq "--since/--until selects the range" "feat: add login page" "$(echo "$out" | jq -r '[.commits[].message] | join("|")')"
assert_eq "--since/--until period label" "2025-01-01 → 2025-01-31" "$(echo "$out" | jq -r '.period')"
out=$("$GIT_RECAP" -f json -m commits --until 2025-01-10 -u "Recap Tester" "$data_repo" 2>/dev/null)
assert_eq "--until is inclusive" "1" "$(echo "$out" | jq '.commits | length')"
out=$("$GIT_RECAP" -f json -m commits --since 2025-02-11 -u "Recap Tester" "$data_repo" 2>/dev/null)
assert_eq "--since alone runs until today" "feat: export csv" "$(echo "$out" | jq -r '[.commits[].message] | join("|")')"
assert_exit "-p with --since exits 1" 1 "$GIT_RECAP" -p all --since 2025-01-01 "$data_repo"
assert_exit "invalid --since date exits 1" 1 "$GIT_RECAP" --since 2025-13 "$data_repo"
assert_exit "--since after --until exits 1" 1 "$GIT_RECAP" --since 2025-02-01 --until 2025-01-01 "$data_repo"

# Remote mode through the gh mock: body kept, merges and release commits skipped
out=$(PATH="$mock_dir/bin:$PATH" \
    "$GIT_RECAP" -f json -m all -p 2025-03 -u recaptester mock/repo 2>/dev/null)
assert_eq "remote skips merges and release commits" "aaaaaaa" "$(echo "$out" | jq -r '[.commits[].hash] | join(",")')"
assert_eq "remote commit carries its body" $'Why: users asked\twith a tab' "$(echo "$out" | jq -r '.commits[0].body')"
assert_eq "remote commit has no file list" "false" "$(echo "$out" | jq '.commits[0] | has("files")')"
out=$(PATH="$mock_dir/bin:$PATH" \
    "$GIT_RECAP" --team -f json -m all -p 2025-03 mock/repo 2>/dev/null)
assert_eq "remote team skips bot authors" "recaptester" "$(echo "$out" | jq -r '[.contributors[].user] | join(",")')"

rm -rf "$data_dir"

echo ""

# ---------- Regression tests ----------

echo "$(_bold "Regressions")"

reg_dir=$(mktemp -d /tmp/git-recap-reg.XXXXXX)
reg_home="$reg_dir/home"
reg_repo="$reg_dir/repo"
mkdir -p "$reg_home"

# _reg_init <dir> : empty repository with a fixed identity
_reg_init() {
    mkdir -p "$1"
    git -C "$1" init -q -b main
    git -C "$1" config user.name "Recap Tester"
    git -C "$1" config user.email "recap@example.invalid"
    git -C "$1" config commit.gpgsign false
}

# _reg_commit <dir> <date> <author> <subject> [body]
_reg_commit() {
    local dir="$1" date="$2" author="$3" subject="$4" body="${5:-}"
    local msg_args=(-m "$subject")
    [[ -n "$body" ]] && msg_args+=(-m "$body")
    GIT_AUTHOR_DATE="${date}T12:00:00" GIT_COMMITTER_DATE="${date}T12:00:00" \
        git -C "$dir" -c user.name="$author" commit -q --allow-empty --allow-empty-message "${msg_args[@]}"
}

_reg_init "$reg_repo"
_reg_commit "$reg_repo" 2025-01-10 "Recap Tester" "feat: first"
_reg_commit "$reg_repo" 2025-01-11 "Jane Doe" "fix: second"

# Config: an invalid format from ~/.git-recaprc is rejected like an invalid -f
mkdir -p "$reg_dir/badhome"
printf '%s\n' 'GIT_RECAP_FORMAT="xml"' > "$reg_dir/badhome/.git-recaprc"
assert_exit "invalid config format exits 1 (single)" 1 env HOME="$reg_dir/badhome" "$GIT_RECAP" -p all -u "Recap Tester" "$reg_repo"
assert_exit "invalid config format exits 1 (team)" 1 env HOME="$reg_dir/badhome" "$GIT_RECAP" --team -p all "$reg_repo"
err=$(HOME="$reg_dir/badhome" "$GIT_RECAP" --team -p all "$reg_repo" 2>&1 || true)
assert_contains "invalid config format is reported" "$err" "Invalid format: xml"
out=$(HOME="$reg_dir/badhome" "$GIT_RECAP" --team -f text -p all "$reg_repo" 2>/dev/null)
assert_contains "-f overrides an invalid config format" "$out" "Team Recap"

# Periods and dates are range-checked, before anything else runs
assert_exit "-p with month 13 exits 1" 1 env HOME="$reg_home" "$GIT_RECAP" -p 2026-13 -u x "$reg_repo"
assert_exit "-p with month 00 exits 1" 1 env HOME="$reg_home" "$GIT_RECAP" -p 2026-00 -u x "$reg_repo"
assert_exit "--since with month 13 exits 1" 1 env HOME="$reg_home" "$GIT_RECAP" --since 2025-13-01 -u x "$reg_repo"
assert_exit "--until on Feb 30 exits 1" 1 env HOME="$reg_home" "$GIT_RECAP" --until 2025-02-30 -u x "$reg_repo"
assert_exit "--since on a leap day exits 0" 0 env HOME="$reg_home" "$GIT_RECAP" --since 2024-02-29 -u x "$reg_repo"
err=$(HOME="$reg_home" "$GIT_RECAP" -p 2026-13 -u x "$reg_repo" 2>&1 || true)
assert_contains "invalid month is reported" "$err" "Invalid period: 2026-13"
assert_not_contains "invalid period fails before the repo is resolved" "$err" "Local repo"

# Tabs and empty subjects do not shift columns (local)
_reg_init "$reg_dir/odd"
_reg_commit "$reg_dir/odd" 2025-01-12 "Recap Tester" $'fix:\tindent with\ttabs'
_reg_commit "$reg_dir/odd" 2025-01-13 "dependabot[bot]" ""
_reg_commit "$reg_dir/odd" 2025-01-14 "Recap Tester" ""
out=$(HOME="$reg_home" "$GIT_RECAP" --team -f json -p all "$reg_dir/odd" 2>/dev/null)
assert_eq "tab in a subject does not invent a contributor" "Recap Tester" "$(echo "$out" | jq -r '[.contributors[].user] | join(",")')"
assert_eq "tab in a subject becomes a space" "fix: indent with tabs" "$(echo "$out" | jq -r '.contributors[0].commits[1].message')"
assert_eq "tab in a subject keeps the date column" "2025-01-12" "$(echo "$out" | jq -r '.contributors[0].commits[1].date')"
assert_eq "empty subject gets a placeholder" "(no commit message)|2025-01-14" "$(echo "$out" | jq -r '.contributors[0].commits[0] | "\(.message)|\(.date)"')"
assert_eq "empty subject does not shield a bot from the filter" "2" "$(echo "$out" | jq '.global_stats.total_commits')"
assert_eq "stats ignore tabs in subjects" "2025-01-12|2025-01-14" "$(echo "$out" | jq -r '.global_stats | "\(.first_date)|\(.last_date)"')"
out=$(HOME="$reg_home" "$GIT_RECAP" -p all -m commits -u "Recap Tester" "$reg_dir/odd" 2>/dev/null)
assert_contains "text lists the tabbed subject under its date" "$out" "  fix: indent with tabs"

# A commit that is not valid UTF-8 (legacy Latin-1 history) does not truncate the recap.
# git commit would re-encode it, so the commits are written with fast-import; \351 is a Latin-1 "é".
_reg_init "$reg_dir/latin1"
{
    printf 'commit refs/heads/main\nmark :1\n'
    printf 'author Recap Tester <recap@example.invalid> 1736510400 +0000\n'
    printf 'committer Recap Tester <recap@example.invalid> 1736510400 +0000\n'
    printf 'data 13\nfeat: before\n'
    printf 'commit refs/heads/main\nmark :2\n'
    printf 'author Ren\351 Latin <rene@example.invalid> 1736596800 +0000\n'
    printf 'committer Ren\351 Latin <rene@example.invalid> 1736596800 +0000\n'
    printf 'data 20\nfix: caf\351 in latin1\nfrom :1\n'
    printf 'commit refs/heads/main\nmark :3\n'
    printf 'author Recap Tester <recap@example.invalid> 1736683200 +0000\n'
    printf 'committer Recap Tester <recap@example.invalid> 1736683200 +0000\n'
    printf 'data 12\nfeat: after\nfrom :2\n'
} | git -C "$reg_dir/latin1" fast-import --quiet
for latin1_locale in en_US.UTF-8 C; do
    out=$(HOME="$reg_home" LC_ALL="$latin1_locale" "$GIT_RECAP" --team -p all "$reg_dir/latin1" 2>/dev/null)
    assert_contains "non-UTF-8 commit ($latin1_locale): stats count every commit" "$out" "Total commits:   3"
    assert_contains "non-UTF-8 commit ($latin1_locale): period covers every commit" "$out" "Period:          2025-01-10 → 2025-01-12"
    assert_contains "non-UTF-8 commit ($latin1_locale): two contributors" "$out" "Contributors:    2"
    assert_contains "non-UTF-8 commit ($latin1_locale): bullets after it are kept" "$out" "• feat: before"
    out=$(HOME="$reg_home" LC_ALL="$latin1_locale" "$GIT_RECAP" -p all -u "Recap Tester" "$reg_dir/latin1" 2>/dev/null)
    assert_contains "non-UTF-8 commit ($latin1_locale): single-user recap is complete" "$out" "Total commits:   2"
    out=$(HOME="$reg_home" LC_ALL="$latin1_locale" "$GIT_RECAP" -f json -p all -u "Latin" "$reg_dir/latin1" 2>/dev/null)
    assert_eq "non-UTF-8 commit ($latin1_locale): JSON is produced" "1" "$(echo "$out" | jq '.commits | length' 2>/dev/null)"
    out=$(HOME="$reg_home" LC_ALL="$latin1_locale" "$GIT_RECAP" --team --exclude-author "recap*" -p all "$reg_dir/latin1" 2>/dev/null)
    assert_contains "non-UTF-8 author ($latin1_locale): --exclude-author filters the others" "$out" "Contributors:    1"
done

# Pipes in subjects and author names do not add markdown table columns
_reg_init "$reg_dir/pipes"
_reg_commit "$reg_dir/pipes" 2025-01-12 "Pipe|Name" "feat: support a|b syntax"
out=$(HOME="$reg_home" "$GIT_RECAP" -f markdown -p all -m commits -u "Pipe" "$reg_dir/pipes" 2>/dev/null)
assert_contains "markdown commit table escapes pipes" "$out" '| feat: support a\|b syntax |'
out=$(HOME="$reg_home" "$GIT_RECAP" --team -f markdown -p all "$reg_dir/pipes" 2>/dev/null)
assert_contains "team markdown ranking escapes pipes" "$out" '| 1 | Pipe\|Name | 1 | 100% |'
assert_contains "team markdown commit table escapes pipes" "$out" '| feat: support a\|b syntax |'
assert_contains "markdown lists keep the raw subject" "$out" '- feat: support a|b syntax'
out=$(HOME="$reg_home" "$GIT_RECAP" -p all -m commits -u "Pipe" "$reg_dir/pipes" 2>/dev/null)
assert_contains "text output keeps pipes as they are" "$out" 'feat: support a|b syntax'

# A subject that looks like an echo option is still printed
_reg_init "$reg_dir/dash"
_reg_commit "$reg_dir/dash" 2025-01-12 "Recap Tester" "-n"
out=$(HOME="$reg_home" "$GIT_RECAP" -p all -m bullets -u "Recap Tester" "$reg_dir/dash" 2>/dev/null)
assert_contains "text bullet for a subject named -n" "$out" "  • -n"
out=$(HOME="$reg_home" "$GIT_RECAP" -f markdown -p all -m bullets -u "Recap Tester" "$reg_dir/dash" 2>/dev/null)
assert_contains "markdown bullet for a subject named -n" "$out" "- -n"
out=$(HOME="$reg_home" "$GIT_RECAP" --team -p all -m bullets "$reg_dir/dash" 2>/dev/null)
assert_contains "team bullet for a subject named -n" "$out" "    • -n"

# --exclude-author takes a literal name as well as a glob, in any case
out=$(HOME="$reg_home" "$GIT_RECAP" --team --all-commits -f json -p all "$reg_dir/odd" 2>/dev/null)
assert_eq "--all-commits keeps the bot" "Recap Tester,dependabot[bot]" "$(echo "$out" | jq -r '[.contributors[].user] | sort | join(",")')"
out=$(HOME="$reg_home" "$GIT_RECAP" --team --all-commits --exclude-author 'Dependabot[bot]' -f json -p all "$reg_dir/odd" 2>/dev/null)
assert_eq "--exclude-author matches a name with brackets literally" "Recap Tester" "$(echo "$out" | jq -r '[.contributors[].user] | join(",")')"
out=$(HOME="$reg_home" "$GIT_RECAP" --team --all-commits --exclude-author 'RECAP*' -f json -p all "$reg_dir/odd" 2>/dev/null)
assert_eq "--exclude-author still matches globs case-insensitively" "dependabot[bot]" "$(echo "$out" | jq -r '[.contributors[].user] | join(",")')"

# Large recaps: JSON is built without putting commit data on a command line
# (2500 commits is past the 1 MB argument limit on macOS, far past Linux's 128 KB per argument)
_reg_init "$reg_dir/large"
LC_ALL=C awk 'BEGIN {
    body = ""
    while (length(body) < 400) body = body "Explains at length why the change was needed. "
    for (i = 1; i <= 2500; i++) {
        msg = "feat: change number " i "\n\n" body "\n"
        printf "commit refs/heads/main\nmark :%d\n", i
        printf "author Recap Tester <recap@example.invalid> %d +0000\n", 1735732800 + i * 3600
        printf "committer Recap Tester <recap@example.invalid> %d +0000\n", 1735732800 + i * 3600
        printf "data %d\n%s", length(msg), msg
        if (i > 1) printf "from :%d\n", i - 1
        content = "line " i "\n"
        printf "M 100644 inline file%d.txt\ndata %d\n%s\n", i % 20, length(content), content
    }
}' | git -C "$reg_dir/large" fast-import --quiet
out=$(HOME="$reg_home" "$GIT_RECAP" -f json -p all -u "Recap Tester" "$reg_dir/large" 2>/dev/null)
assert_eq "large single JSON exits 0" "0" "$?"
assert_eq "large single JSON lists every commit" "2500" "$(echo "$out" | jq '.commits | length' 2>/dev/null)"
assert_eq "large single JSON keeps bodies and files" "true" "$(echo "$out" | jq '.commits[0] | (.body | length > 100) and (.files | length == 1)' 2>/dev/null)"
out=$(HOME="$reg_home" "$GIT_RECAP" --team -f json -p all "$reg_dir/large" 2>/dev/null)
assert_eq "large team JSON lists every commit" "2500" "$(echo "$out" | jq '.contributors[0].commits | length' 2>/dev/null)"
assert_eq "large team JSON totals match" "2500|2500" "$(echo "$out" | jq -r '"\(.global_stats.total_commits)|\(.contributors[0].stats.total_commits)"' 2>/dev/null)"

# Team sections for authors whose name has a backslash or looks like a number
_reg_init "$reg_dir/names"
_reg_commit "$reg_dir/names" 2025-01-10 'CORP\jsmith' "feat: one"
_reg_commit "$reg_dir/names" 2025-01-11 'CORP\jsmith' "feat: two"
_reg_commit "$reg_dir/names" 2025-01-12 '0123' "feat: three"
_reg_commit "$reg_dir/names" 2025-01-13 '123' "feat: four"
out=$(HOME="$reg_home" "$GIT_RECAP" --team -f json -p all "$reg_dir/names" 2>/dev/null)
assert_eq "author with a backslash keeps its commits" "2" "$(echo "$out" | jq '.contributors[] | select(.user == "CORP\\jsmith") | .commits | length')"
assert_eq "numeric-looking authors are not merged" "feat: three|feat: four" \
    "$(echo "$out" | jq -r '[(.contributors[] | select(.user == "0123") | .commits[].message), (.contributors[] | select(.user == "123") | .commits[].message)] | join("|")')"
out=$(HOME="$reg_home" "$GIT_RECAP" --team -p all "$reg_dir/names" 2>/dev/null)
assert_contains "team text counts the commits of an author with a backslash" "$out" '▶ CORP\jsmith (2 commits)'
out=$(HOME="$reg_home" "$GIT_RECAP" --team -f markdown -p all "$reg_dir/names" 2>/dev/null)
assert_contains "team markdown counts the commits of an author with a backslash" "$out" '## CORP\jsmith (2 commits)'

# Backslashes, tabs and CRLF in remote subjects, authors and bodies
cat > "$mock_dir/commits-odd.json" <<'FIXTURE'
[
  {"sha": "fffffff6666", "parents": [{"sha": "p0"}], "author": null,
   "commit": {"message": "fix: handle C:\\temp\\new\tpath\r\n\r\nBody line\r\nwith a \\n literal", "author": {"name": "CORP\\jsmith", "date": "2025-03-06T10:00:00Z"}}},
  {"sha": "9999999aaaa", "parents": [{"sha": "p0"}], "author": {"login": "recaptester"},
   "commit": {"message": "", "author": {"name": "Recap Tester", "date": "2025-03-05T10:00:00Z"}}}
]
FIXTURE
out=$(PATH="$mock_dir/bin:$PATH" HOME="$reg_home" "$GIT_RECAP" -b odd -f json -p all -u recaptester mock/repo 2>/dev/null)
assert_eq "remote subject keeps single backslashes" 'fix: handle C:\temp\new path' "$(echo "$out" | jq -r '.commits[0].message')"
assert_eq "remote body is decoded once" $'Body line\nwith a \\n literal' "$(echo "$out" | jq -r '.commits[0].body')"
assert_eq "remote empty message gets a placeholder" "(no commit message)" "$(echo "$out" | jq -r '.commits[1].message')"
out=$(PATH="$mock_dir/bin:$PATH" HOME="$reg_home" "$GIT_RECAP" --team -b odd -f json -p all mock/repo 2>/dev/null)
assert_eq "remote author keeps single backslashes" 'CORP\jsmith' "$(echo "$out" | jq -r '.contributors[] | select(.user | startswith("CORP")) | .user')"

# A path that is not a repository is an error, not a GitHub lookup
mkdir -p "$reg_dir/plain"
err=$(cd "$reg_dir/plain" && PATH="$mock_dir/bin:$PATH" HOME="$reg_home" "$GIT_RECAP" -p all -u recaptester . 2>&1)
assert_eq "\".\" outside a repository exits 1" "1" "$?"
assert_contains "\".\" outside a repository is reported" "$err" "Not a git repository: ."
assert_not_contains "\".\" outside a repository is not sent to GitHub" "$err" "Repo:"
err=$(PATH="$mock_dir/bin:$PATH" HOME="$reg_home" "$GIT_RECAP" -p all -u recaptester /no/such/path 2>&1)
assert_contains "missing path is reported" "$err" "Not a git repository: /no/such/path"

# Local branches: unknown or option-like names fail instead of "No commits found"
assert_exit "unknown local branch exits 1" 1 env HOME="$reg_home" "$GIT_RECAP" -b does-not-exist -p all -u "Recap Tester" "$reg_repo"
err=$(HOME="$reg_home" "$GIT_RECAP" -b does-not-exist -p all -u "Recap Tester" "$reg_repo" 2>&1 || true)
assert_contains "unknown local branch is reported" "$err" "Branch not found"
assert_exit "branch starting with a dash exits 1" 1 env HOME="$reg_home" "$GIT_RECAP" -b -1 -p all -u "Recap Tester" "$reg_repo"
assert_exit "option-like branch exits 1" 1 env HOME="$reg_home" "$GIT_RECAP" -b "--output=$reg_dir/pwned" -p all -u "Recap Tester" "$reg_repo"
assert_eq "option-like branch never reaches git" "no" "$([[ -e "$reg_dir/pwned" ]] && echo yes || echo no)"

# A branch named like a path is not ambiguous
mkdir -p "$reg_repo/docs"
git -C "$reg_repo" branch docs
out=$(HOME="$reg_home" "$GIT_RECAP" -b docs -p all -m commits -u "Recap Tester" "$reg_repo" 2>/dev/null)
assert_contains "branch named like a directory is read" "$out" "feat: first"
rmdir "$reg_repo/docs"
git -C "$reg_repo" branch -q -D docs

# origin's default branch without a local copy falls back to origin/<branch>
git -C "$reg_repo" branch dev
git clone -q --branch dev "$reg_repo" "$reg_dir/clone" 2>/dev/null
out=$(HOME="$reg_home" "$GIT_RECAP" -p all -m commits -u "Recap Tester" "$reg_dir/clone" 2>&1)
assert_contains "default branch without local copy uses origin/<branch>" "$out" "Branch: origin/main"
assert_contains "default branch without local copy returns commits" "$out" "feat: first"
git -C "$reg_repo" branch -q -D dev

# A repository without commits is an empty recap, not an error
_reg_init "$reg_dir/empty"
assert_exit "repository without commits exits 0" 0 env HOME="$reg_home" "$GIT_RECAP" -p all -u "Recap Tester" "$reg_dir/empty"
out=$(HOME="$reg_home" "$GIT_RECAP" -p all -u "Recap Tester" "$reg_dir/empty" 2>/dev/null)
assert_contains "repository without commits reports none" "$out" "No commits found"

# --all-branches walks branches, not the stash
_reg_init "$reg_dir/stash"
printf 'one\n' > "$reg_dir/stash/tracked.txt"
git -C "$reg_dir/stash" add tracked.txt
git -C "$reg_dir/stash" commit -q -m "feat: tracked file"
printf 'two\n' >> "$reg_dir/stash/tracked.txt"
printf 'new\n' > "$reg_dir/stash/untracked.txt"
git -C "$reg_dir/stash" stash push -q -u -m "wip"
out=$(HOME="$reg_home" "$GIT_RECAP" --all-branches -p all -m commits -u "Recap Tester" "$reg_dir/stash" 2>/dev/null)
assert_contains "--all-branches lists branch commits" "$out" "feat: tracked file"
assert_not_contains "--all-branches skips stash index commits" "$out" "index on main"
assert_not_contains "--all-branches skips stash untracked commits" "$out" "untracked files on main"

# Changed files keep non-ASCII names readable
printf 'x\n' > "$reg_dir/stash/数据.txt"
git -C "$reg_dir/stash" add .
git -C "$reg_dir/stash" commit -q -m "feat: unicode path"
out=$(HOME="$reg_home" "$GIT_RECAP" -f json -p all -u "Recap Tester" "$reg_dir/stash" 2>/dev/null)
assert_eq "non-ASCII file names are not C-quoted" "数据.txt" "$(echo "$out" | jq -r '.commits[0].files[0].path')"

# GitHub API failures are reported, in every mode, instead of "No commits found"
_mock_run() { PATH="$mock_dir/bin:$PATH" HOME="$reg_home" "$GIT_RECAP" "$@"; }
for api_mode in "" "--all-branches" "--team" "--team --all-branches"; do
    # shellcheck disable=SC2086  # api_mode holds zero or more flags
    err=$(GH_MOCK_FAIL=404 _mock_run $api_mode -p all -u recaptester mock/repo 2>&1 >/dev/null)
    assert_eq "404 exits 1 (${api_mode:-single branch})" "1" "$?"
    assert_contains "404 is reported (${api_mode:-single branch})" "$err" "Repository not found: mock/repo"
    assert_not_contains "404 body does not leak into diagnostics (${api_mode:-single branch})" "$err" '{"message"'
done
err=$(GH_MOCK_FAIL=403 _mock_run -p all -u recaptester mock/repo 2>&1 >/dev/null)
assert_contains "403 is reported as access denied" "$err" "Access denied"
err=$(GH_MOCK_FAIL=500 _mock_run --all-branches -p all -u recaptester mock/repo 2>&1 >/dev/null)
assert_eq "500 exits 1" "1" "$?"
assert_contains "500 is reported" "$err" "GitHub API error"
err=$(GH_MOCK_FAIL=404 GH_MOCK_FAIL_ON=commits _mock_run -b nope -p all -u recaptester mock/repo 2>&1 >/dev/null)
assert_contains "404 with -b mentions the branch" "$err" "(branch: nope)"
out=$(GH_MOCK_FAIL=409 GH_MOCK_FAIL_ON=commits _mock_run -p all -u recaptester mock/repo 2>/dev/null)
assert_eq "empty remote repository exits 0" "0" "$?"
assert_contains "empty remote repository reports no commits" "$out" "No commits found"

# Branch and author reach the API percent-encoded ("#" would cut the query short)
GH_MOCK_LOG="$reg_dir/gh.log" _mock_run -b "feature/#123" -p 2025-03 -u "Jane Doe" mock/repo >/dev/null 2>&1
assert_contains "branch is percent-encoded in the query" "$(cat "$reg_dir/gh.log")" "sha=feature/%23123&"
assert_contains "author is percent-encoded in the query" "$(cat "$reg_dir/gh.log")" "author=Jane%20Doe&"
assert_contains "the rest of the query survives" "$(cat "$reg_dir/gh.log")" "since=2025-03-01T00:00:00Z"

# gh is only called when its answer is needed
rm -f "$reg_dir/gh.log"
GH_MOCK_LOG="$reg_dir/gh.log" _mock_run --team -p all "$reg_repo" >/dev/null 2>&1
assert_eq "team recap of a local repo never calls gh" "no" "$([[ -s "$reg_dir/gh.log" ]] && echo yes || echo no)"
rm -f "$reg_dir/gh.log"
GH_MOCK_LOG="$reg_dir/gh.log" _mock_run --team -p all mock/repo >/dev/null 2>&1
assert_eq "team recap of owner/repo: default branch and commits only" "api repos/mock/repo|api repos/mock/repo/commits" \
    "$(sed 's/?.*//' "$reg_dir/gh.log" | tr '\n' '|' | sed 's/|$//')"
rm -f "$reg_dir/gh.log"
GH_MOCK_LOG="$reg_dir/gh.log" _mock_run -p all mock/repo >/dev/null 2>&1
assert_eq "user detection is a single call, without an auth check" "api user|api repos/mock/repo|api repos/mock/repo/commits" \
    "$(sed 's/?.*//' "$reg_dir/gh.log" | tr '\n' '|' | sed 's/|$//')"
out=$(_mock_run --team -p all barename 2>&1)
assert_contains "team recap of a bare repo name looks the user up" "$out" "Repo: recaptester/barename (using user: recaptester)"
err=$(GH_MOCK_AUTH_RC=1 _mock_run -p all -u recaptester mock/repo 2>&1 >/dev/null)
assert_eq "logged-out gh exits 1" "1" "$?"
assert_contains "logged-out gh is reported as such" "$err" "gh is not authenticated. Run: gh auth login"

# gh warnings on stderr are not parsed as commits
out=$(GH_MOCK_STDERR="warning: something on stderr" _mock_run -f json -p all -u recaptester mock/repo 2>/dev/null)
assert_eq "gh stderr does not become a commit" "aaaaaaa" "$(echo "$out" | jq -r '[.commits[].hash] | join(",")')"

# Remote --all-branches: each commit once, newest day first across branches
cat > "$mock_dir/branches.json" <<'FIXTURE'
[{"name": "main"}, {"name": "dev"}]
FIXTURE
cat > "$mock_dir/commits-main.json" <<'FIXTURE'
[
  {"sha": "1111111aaaa", "parents": [{"sha": "p0"}], "author": {"login": "recaptester"},
   "commit": {"message": "feat: newest on main", "author": {"name": "Recap Tester", "date": "2025-03-04T10:00:00Z"}}},
  {"sha": "2222222bbbb", "parents": [{"sha": "p0"}], "author": {"login": "recaptester"},
   "commit": {"message": "feat: shared base", "author": {"name": "Recap Tester", "date": "2025-03-02T10:00:00Z"}}}
]
FIXTURE
cat > "$mock_dir/commits-dev.json" <<'FIXTURE'
[
  {"sha": "3333333cccc", "parents": [{"sha": "p0"}], "author": {"login": "recaptester"},
   "commit": {"message": "feat: only on dev\n\nDev body", "author": {"name": "Recap Tester", "date": "2025-03-03T10:00:00Z"}}},
  {"sha": "2222222bbbb", "parents": [{"sha": "p0"}], "author": {"login": "recaptester"},
   "commit": {"message": "feat: shared base", "author": {"name": "Recap Tester", "date": "2025-03-02T10:00:00Z"}}}
]
FIXTURE
out=$(GH_MOCK_BRANCHES="$mock_dir/branches.json" _mock_run --all-branches -f json -p all -u recaptester mock/repo 2>/dev/null)
assert_eq "remote --all-branches dedupes and sorts by date" "1111111,3333333,2222222" "$(echo "$out" | jq -r '[.commits[].hash] | join(",")')"
assert_eq "remote --all-branches keeps commit bodies" "Dev body" "$(echo "$out" | jq -r '.commits[1].body')"
out=$(GH_MOCK_BRANCHES="$mock_dir/branches.json" _mock_run --all-branches -p all -m commits -u recaptester mock/repo 2>/dev/null)
assert_eq "remote --all-branches prints each date once" "1" "$(echo "$out" | grep -c '^  2025-03-02$')"
rm -f "$mock_dir/branches.json" "$mock_dir/commits-main.json" "$mock_dir/commits-dev.json"

# curl fallback (no gh on PATH): a sandboxed PATH with a curl mock
#   CURL_MOCK_STATUS  HTTP status to answer with (default: 200)
#   CURL_MOCK_LOG     file receiving one line per URL requested
# The commits endpoint is served in two pages; the default branch is "trunk".
nogh_bin="$reg_dir/nogh-bin"
mkdir -p "$nogh_bin"
for tool in bash env git jq sed cut tr awk sort uniq wc head tail cat mktemp rm basename date; do
    ln -s "$(command -v "$tool")" "$nogh_bin/$tool"
done
cat > "$nogh_bin/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
body=/dev/null headers=/dev/null url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) body="$2"; shift 2 ;;
        -D) headers="$2"; shift 2 ;;
        -w|-H) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
[[ -n "${CURL_MOCK_LOG:-}" ]] && printf '%s\n' "$url" >> "$CURL_MOCK_LOG"
status="${CURL_MOCK_STATUS:-200}"
: > "$headers"
if [[ "$status" != 200 ]]; then
    printf '%s\n' '{"message":"API rate limit exceeded"}' > "$body"
elif [[ "$url" == *"/branches"* ]]; then
    printf '%s\n' '[{"name":"trunk"}]' > "$body"
elif [[ "$url" == *"/commits"*"page=2"* ]]; then
    printf '%s\n' '[{"sha": "eeeeeee5555", "parents": [{"sha": "p0"}], "author": {"login": "recaptester"},
        "commit": {"message": "fix: second page", "author": {"name": "Recap Tester", "date": "2025-03-01T10:00:00Z"}}}]' > "$body"
elif [[ "$url" == *"/commits"* ]]; then
    printf '%s\n' '[{"sha": "aaaaaaa1111", "parents": [{"sha": "p0"}], "author": {"login": "recaptester"},
        "commit": {"message": "feat: first page\n\nPage body", "author": {"name": "Recap Tester", "date": "2025-03-02T10:00:00Z"}}}]' > "$body"
    printf 'link: <%s&page=2>; rel="next"\r\n' "$url" > "$headers"
else
    printf '%s\n' '{"default_branch":"trunk"}' > "$body"
fi
printf '%s' "$status"
MOCK_CURL
chmod +x "$nogh_bin/curl"
_curl_run() { PATH="$nogh_bin" HOME="$reg_home" "$GIT_RECAP" "$@"; }

out=$(CURL_MOCK_LOG="$reg_dir/curl.log" _curl_run -f json -p all -u recaptester mock/repo 2>"$reg_dir/curl.err")
assert_contains "curl fallback is used without gh" "$(cat "$reg_dir/curl.err")" "(curl)"
assert_eq "curl fallback follows pagination" "aaaaaaa,eeeeeee" "$(echo "$out" | jq -r '[.commits[].hash] | join(",")')"
assert_eq "curl fallback keeps commit bodies" "Page body" "$(echo "$out" | jq -r '.commits[0].body')"
assert_contains "curl fallback asks for the default branch" "$(cat "$reg_dir/curl.log")" "sha=trunk&"
out=$(CURL_MOCK_LOG="$reg_dir/curl-all.log" _curl_run --all-branches -f json -p all -u recaptester mock/repo 2>/dev/null)
assert_eq "curl fallback supports --all-branches" "2" "$(echo "$out" | jq '.commits | length')"
assert_not_contains "curl fallback never sends a placeholder branch" "$(cat "$reg_dir/curl-all.log")" "__all__"
err=$(CURL_MOCK_STATUS=403 _curl_run -p all -u recaptester mock/repo 2>&1 >/dev/null)
assert_eq "curl fallback exits 1 on an HTTP error" "1" "$?"
assert_contains "curl fallback reports the HTTP error" "$err" "Access denied"
err=$(CURL_MOCK_STATUS=404 _curl_run --team -p all mock/repo 2>&1 >/dev/null)
assert_contains "curl fallback reports a missing repository" "$err" "Repository not found: mock/repo"

# Team mode with a bare repo name needs a user to build owner/repo
err=$(_curl_run --team -p all barename 2>&1 >/dev/null)
assert_eq "bare repo name without a user exits 1" "1" "$?"
assert_contains "bare repo name without a user is reported" "$err" "without a GitHub user"

rm -rf "$reg_dir"

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

rm -rf "$mock_dir"

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
