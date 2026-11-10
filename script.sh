#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# git-recap — Commit recap data generator (AI writing lives in the agent skill)
# ==============================================================================

VERSION="2.0.1"
CONFIG_FILE="$HOME/.git-recaprc"

# Defaults
DEFAULT_PERIOD="current-month"
DEFAULT_MODE="all"
DEFAULT_FORMAT="text"

# State
ARG_USER=""
ARG_PERIOD=""
ARG_MODE=""
ARG_FORMAT=""
ARG_OUTPUT=""
ARG_BRANCH=""
ARG_REPO=""
ARG_INIT=false
ARG_TEAM=false
ARG_ALL_BRANCHES=false
ARG_SINCE=""
ARG_UNTIL=""
ARG_EXCLUDE_AUTHORS=""  # newline-separated glob patterns
ARG_ALL_COMMITS=false

# Resolved values
USER_NAME=""
REPO_FULL=""
REPO_NAME=""
REPO_MODE=""  # local or remote
LOCAL_REPO_DIR=""
REPO_WEB_URL=""
BRANCH=""
SINCE=""
UNTIL=""
PERIOD_LABEL=""
WORK_DIR=""      # Scratch directory, removed on exit
DETAILS_FILE=""  # JSON lines {hash, body, files?, additions?, deletions?} (json format only)

# ==============================================================================
# Helpers
# ==============================================================================

_color() { if [[ -t 2 ]]; then printf '\033[%sm' "$1" >&2; fi; }
_reset() { if [[ -t 2 ]]; then printf '\033[0m' >&2; fi; }

info()  { _color "34"; printf ":: %s\n" "$*" >&2; _reset; }
warn()  { _color "33"; printf "!! %s\n" "$*" >&2; _reset; }
error() { _color "31"; printf "!! %s\n" "$*" >&2; _reset; }
die()   { error "$@"; exit 1; }

cleanup() {
    if [[ -n "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

# --- Dates ---
# Calendar math is done in Bash arithmetic so that it behaves the same with
# GNU and BSD date; the clock is only read in _today.

_MONTH_NAMES=(January February March April May June July August September October November December)

# Today's date (YYYY-MM-DD)
_today() { date +%Y-%m-%d; }

# _jdn <YYYY-MM-DD> → Julian day number (jdn % 7 is 0 on Mondays)
_jdn() {
    local y=$((10#${1:0:4})) m=$((10#${1:5:2})) d=$((10#${1:8:2}))
    local a=$(( (14 - m) / 12 ))
    local yy=$(( y + 4800 - a )) mm=$(( m + 12 * a - 3 ))
    echo $(( d + (153 * mm + 2) / 5 + 365 * yy + yy / 4 - yy / 100 + yy / 400 - 32045 ))
}

# _from_jdn <jdn> → YYYY-MM-DD
_from_jdn() {
    local a=$(( $1 + 32044 ))
    local b=$(( (4 * a + 3) / 146097 ))
    local c=$(( a - 146097 * b / 4 ))
    local d=$(( (4 * c + 3) / 1461 ))
    local e=$(( c - 1461 * d / 4 ))
    local m=$(( (5 * e + 2) / 153 ))
    printf '%04d-%02d-%02d\n' \
        $(( 100 * b + d - 4800 + m / 10 )) $(( m + 3 - 12 * (m / 10) )) $(( e - (153 * m + 2) / 5 + 1 ))
}

# _is_valid_date <YYYY-MM-DD> : true for a real calendar date
_is_valid_date() {
    [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    [[ "$(_from_jdn "$(_jdn "$1")")" == "$1" ]]
}

# _month_shift <YYYY-MM> <offset> → YYYY-MM, offset months away
_month_shift() {
    local idx=$(( 10#${1:0:4} * 12 + 10#${1:5:2} - 1 + $2 ))
    printf '%04d-%02d\n' $(( idx / 12 )) $(( idx % 12 + 1 ))
}

# _month_label <YYYY-MM> → "January 2026"
_month_label() {
    echo "${_MONTH_NAMES[$(( 10#${1:5:2} - 1 ))]} ${1:0:4}"
}

# raw_bullets <commits> → commit messages, one per line, for modes bullets/all
raw_bullets() {
    local mode="${ARG_MODE:-$DEFAULT_MODE}"
    [[ "$mode" != "bullets" && "$mode" != "all" ]] && return
    [[ -z "$1" ]] && return
    printf '%s\n' "$1" | cut -f2
}

# --- Commit rows and details (body, changed files) ---
# Rows are TSV. Fetchers guarantee that no field contains a tab and that no
# field is empty (placeholders below), so rows always split cleanly.

NO_SUBJECT="(no commit message)"
NO_AUTHOR="(unknown)"

# _tsv_rows : stdin = rows of \x1f-separated fields (git log) → TSV rows
_tsv_rows() {
    LC_ALL=C awk -F'\037' -v OFS='\t' -v no_subject="$NO_SUBJECT" -v no_author="$NO_AUTHOR" '{
        for (i = 1; i <= NF; i++) gsub(/\t/, " ", $i)
        if ($2 == "") $2 = no_subject
        if (NF >= 4 && $4 == "") $4 = no_author
        $1 = $1
        print
    }'
}

# jq program turning a GitHub API commit list into TSV rows, merges excluded.
# Fields: hash, subject, date[, author], body (the body is JSON-encoded)
# shellcheck disable=SC2016  # the $names below are jq variables
_gh_commit_jq() {
    local author=""
    [[ "${1:-}" == "team" ]] && author=', ((.author.login // .commit.author.name // "") | field($no_author))'
    printf '%s' '
        def field($placeholder):
            gsub("[\\t\\r\\n]+"; " ") | sub("^ +"; "") | sub(" +$"; "")
            | if . == "" then $placeholder else . end;
        "'"$NO_SUBJECT"'" as $no_subject | "'"$NO_AUTHOR"'" as $no_author
        | .[] | select((.parents | length) < 2)
        | [ .sha[0:7],
            (.commit.message | split("\n")[0] // "" | field($no_subject)),
            (.commit.author.date | split("T")[0])'"$author"',
            (.commit.message | split("\n")[1:] | join("\n") | @json) ]
        | join("\t")'
}

# _split_details <n> : stdin = TSV whose field n+1 is the JSON-encoded body.
# Records bodies in DETAILS_FILE and prints the first n fields.
_split_details() {
    local n="$1" raw
    raw=$(cat)
    [[ -z "$raw" ]] && return 0
    if [[ -n "$DETAILS_FILE" ]]; then
        printf '%s\n' "$raw" | jq -R -c --argjson n "$n" '
            select(length > 0) | split("\t") | {
                hash: .[0],
                body: ((.[$n] // "\"\"") | fromjson | gsub("\r"; "") | sub("^\\s+"; "") | sub("\\s+$"; ""))
            }' >> "$DETAILS_FILE" || die "Could not read commit bodies from the GitHub API response"
    fi
    printf '%s\n' "$raw" | LC_ALL=C cut -f1-"$n"
}

# _collect_local_details <git log args...> : records body + numstat per commit
_collect_local_details() {
    [[ -n "$DETAILS_FILE" ]] || return 0
    git -C "$LOCAL_REPO_DIR" -c core.quotePath=false log "$@" --numstat --format='%x1e%h%x1f%b%x1f' -- | jq -R -s -c '
        split("\u001e") | .[1:][] | split("\u001f") as $p
        | {
            hash: $p[0],
            body: ($p[1] | sub("^\\s+"; "") | sub("\\s+$"; "")),
            files: [($p[2] // "") | split("\n")[] | split("\t") | select(length >= 3)
                | {path: (.[2:] | join("\t")), additions: (.[0] | tonumber? // 0), deletions: (.[1] | tonumber? // 0)}]
        }
        | .additions = ([.files[].additions] | add // 0)
        | .deletions = ([.files[].deletions] | add // 0)' >> "$DETAILS_FILE" \
        || die "Could not read commit details from $LOCAL_REPO_DIR"
}

# --- JSON assembly ---
# The JSON document is built by one jq run that reads the commit rows on stdin
# and everything else from files (--slurpfile): commit data never goes on a
# command line, where a large recap would exceed the argument size limit.

# jq definitions shared by the single-user and team documents.
#   $d    slurped DETAILS_FILE      $mode    summary|commits|bullets|all
# shellcheck disable=SC2016  # the $names below are jq variables
_JQ_RECAP='
    # stdin (raw, slurped) → array of rows, each an array of fields
    def rows: split("\n") | map(select(length > 0) | split("\t"));

    # recorded details by commit hash
    def details: $d | map({key: .hash, value: del(.hash)}) | from_entries;

    # compute_stats fields (see _stats_json) → stats object
    def stats_object: {
        total_commits: .[0], active_days: .[5], avg_per_day: .[6], longest_streak: .[8],
        first_date: .[1], last_date: .[2], busiest_day: .[3], busiest_day_commits: .[4],
        busiest_weekday: .[7]
    };

    # rows → {lines_added, lines_deleted, files_changed}, or null without file data
    def change_stats($m):
        [.[] | $m[.[0]] | select(. != null and .files != null)] as $c
        | if ($c | length) == 0 then null else {
            lines_added: ([$c[].additions] | add),
            lines_deleted: ([$c[].deletions] | add),
            files_changed: ([$c[].files[].path] | unique | length)
        } end;

    # object with a stats key → same object, stats extended with change stats
    def with_change_stats($rows; $m; $key):
        ($rows | change_stats($m)) as $ch | if $ch then .[$key] += $ch else . end;

    # object → same object plus the bullets and commits the mode asks for
    def with_content($rows; $m):
        [$rows[] | .[1] | select(length > 0)] as $bullets
        | if ($mode == "bullets" or $mode == "all") and ($bullets | length) > 0
            then . + {bullets: $bullets} else . end
        | if ($mode == "commits" or $mode == "all") and ($rows | length) > 0
            then . + {commits: ($rows | map({hash: .[0], message: .[1], date: .[2]} + ($m[.[0]] // {})))}
            else . end;
'

# _stats_json <stats> → the compute_stats fields as a JSON array:
# [total, first_date, last_date, busiest_day, busiest_count, active_days,
#  avg_per_day, busiest_weekday, longest_streak]
_stats_json() {
    local total first_date last_date busiest_day busiest_count active_days avg_per_day busiest_weekday longest_streak
    IFS='|' read -r total first_date last_date busiest_day busiest_count active_days avg_per_day busiest_weekday longest_streak <<< "$1"
    printf '[%s,"%s","%s","%s",%s,%s,%s,"%s",%s]\n' "${total:-0}" "$first_date" "$last_date" "$busiest_day" \
        "${busiest_count:-0}" "${active_days:-0}" "${avg_per_day:-0.0}" "$busiest_weekday" "${longest_streak:-0}"
}

# --- Noise filtering ---

_is_bot_author() {
    case "$1" in
        *\[bot\]|*-bot|*" bot"|*-Bot|*" Bot") return 0 ;;
    esac
    return 1
}

_is_release_commit() {
    [[ "$1" =~ ^chore\(release\) || "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# _lowercase : stdin → stdout in lower case. Text that is not valid in the
# current locale (BSD tr stops on it) is lowercased byte-wise instead.
_lowercase() {
    local text out
    text=$(cat)
    out=$(printf '%s\n' "$text" | tr '[:upper:]' '[:lower:]' 2>/dev/null) \
        || out=$(printf '%s\n' "$text" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    printf '%s\n' "$out"
}

# filter_noise <fields> : stdin = commit rows (author in field 4 when <fields> is 4).
# Drops bot authors, release commits and --exclude-author matches.
filter_noise() {
    local fields="$1" rows line rest subject author="" skipped=0
    rows=$(cat)
    [[ -z "$rows" ]] && return 0

    # --exclude-author is case-insensitive: lowercase the patterns and the
    # author column once, instead of forking for every commit
    local exclude=false patterns=() pattern lowered="" lower_author=""
    if [[ "$fields" -eq 4 && -n "$ARG_EXCLUDE_AUTHORS" ]]; then
        while IFS= read -r pattern; do
            [[ -n "$pattern" ]] && patterns+=("$pattern")
        done <<< "$(printf '%s' "$ARG_EXCLUDE_AUTHORS" | _lowercase)"
        if [[ ${#patterns[@]} -gt 0 ]]; then
            exclude=true
            lowered=$(printf '%s\n' "$rows" | LC_ALL=C cut -f4 | _lowercase)
        fi
    fi

    # Rows on fd 3, lowercased authors on fd 4, read in step
    while IFS= read -r line <&3; do
        [[ "$exclude" == true ]] && { IFS= read -r lower_author <&4 || true; }
        [[ -z "$line" ]] && continue
        rest="${line#*$'\t'}"
        subject="${rest%%$'\t'*}"
        [[ "$fields" -eq 4 ]] && author="${line##*$'\t'}"

        if [[ "$ARG_ALL_COMMITS" == false ]] && { _is_release_commit "$subject" || { [[ -n "$author" ]] && _is_bot_author "$author"; }; }; then
            skipped=$((skipped + 1))
            continue
        fi
        if [[ "$exclude" == true ]]; then
            for pattern in "${patterns[@]}"; do
                # A literal name first ("dependabot[bot]" is not a character class), then a glob
                # shellcheck disable=SC2053  # glob matching is intended
                if [[ "$lower_author" == "$pattern" || "$lower_author" == $pattern ]]; then
                    skipped=$((skipped + 1))
                    continue 2
                fi
            done
        fi
        printf '%s\n' "$line"
    done 3<<< "$rows" 4<<< "$lowered"

    if [[ $skipped -gt 0 ]]; then
        info "Skipped $skipped bot/release/excluded commit(s) (use --all-commits to keep bots and releases)"
    fi
}

# _print_bullets <bullets> <prefix> : one prefixed line per bullet
# (printf, not echo: a subject may be "-n" or "-e")
_print_bullets() {
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && printf '%s%s\n' "$2" "$line"
    done <<< "$1"
    return 0
}

_markdown_commit_ref() {
    local hash="$1"
    if [[ -n "$REPO_WEB_URL" ]]; then
        printf '[%s](%s/commit/%s)' "$hash" "$REPO_WEB_URL" "$hash"
    else
        printf '%s' "$hash"
    fi
}

# ==============================================================================
# Help
# ==============================================================================

show_help() {
    cat <<'HELP'
git-recap — Monthly commit recap generator

Usage:
  git-recap [OPTIONS] <repo>

# Arguments

  <repo>              GitHub URL, owner/repo, repo name, SSH URL, or local path (.)

# Options

  -u, --user <user>       GitHub username (auto-detected via gh)
  -p, --period <period>   Period (default: current-month). Values:
                          current-month, last-month, current-week, last-week,
                          current-year, last-year, all, <N>, YYYY-MM, YYYY
  -m, --mode <mode>       Mode: summary, commits, bullets, all (default: all)
                          (bullets are raw commit messages; summaries are
                          written by the git-recap agent skill)
  -f, --format <format>   Format: text, markdown, json (default: text)
  -o, --output <file>     Write output to file
  -b, --branch <branch>   Branch (default: auto-detected)
  --since <YYYY-MM-DD>    Start date (inclusive), instead of -p
  --until <YYYY-MM-DD>    End date (inclusive), instead of -p
  --team                  Team mode: recap for all contributors grouped by author
  --all-branches          Fetch commits from all branches (not just default/specified)
  --exclude-author <glob> Skip commits from matching authors in team mode
                          (case-insensitive, repeatable, e.g. "*bot*")
  --all-commits           Keep bot authors and release commits (skipped by default)
  --init                  Initialize configuration
  -h, --help              Show this help
  -v, --version           Show version

# Agent skill

  git-recap never calls an AI model. Install the agent skill to have your
  coding agent (Claude Code, Codex, ...) write summaries and bullet points:

    npx skills add maxgfr/git-recap

# Examples

  ## Basic usage
  git-recap maxgfr/subtool                            # Current month recap
  git-recap .                                          # Local repo recap

  ## Period selection (-p)
  git-recap -p current-month maxgfr/subtool            # Current month (default)
  git-recap -p last-month maxgfr/subtool               # Last month
  git-recap -p current-week maxgfr/subtool             # Current week (Mon-Sun)
  git-recap -p last-week maxgfr/subtool                # Last week
  git-recap -p current-year maxgfr/subtool             # Current year
  git-recap -p last-year maxgfr/subtool                # Last year
  git-recap -p 2026-01 maxgfr/subtool                  # January 2026
  git-recap -p 2025 maxgfr/subtool                     # Full year 2025
  git-recap -p 3 maxgfr/subtool                        # Last 3 months
  git-recap -p all maxgfr/subtool                      # All commits ever
  git-recap --since 2026-01-05 --until 2026-01-16 .    # Custom date range (sprint)

  ## Output format (-f) and file output (-o)
  git-recap -f markdown -o recap.md maxgfr/subtool     # Markdown saved to file
  git-recap -f json maxgfr/subtool | jq .              # JSON piped to jq
                                                       # (includes commit bodies, and
                                                       # changed files for local repos)

  ## Mode selection (-m)
  git-recap -m summary maxgfr/subtool                  # Stats only
  git-recap -m commits maxgfr/subtool                  # Commit list only
  git-recap -m bullets maxgfr/subtool                  # Bullet points only

  ## Team mode (--team)
  git-recap --team maxgfr/subtool                      # All contributors recap
  git-recap --team -p last-month maxgfr/subtool        # Team recap for last month
  git-recap --team -f markdown -o recap.md maxgfr/subtool  # Team markdown report
  git-recap --team -b develop maxgfr/subtool           # Team recap on develop branch
  git-recap --team --all-branches .                    # All contributors, all branches
  git-recap --team --exclude-author "jdoe" .           # Team recap without jdoe
  git-recap --team --all-commits .                     # Keep bots and release commits

  ## Repo formats
  git-recap maxgfr/subtool                             # owner/repo
  git-recap https://github.com/maxgfr/subtool          # HTTPS URL
  git-recap git@github.com:maxgfr/subtool.git          # SSH URL
HELP
}

# ==============================================================================
# Argument parsing
# ==============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -u|--user)    ARG_USER="${2:?Missing value for $1}"; shift 2 ;;
            -p|--period)  ARG_PERIOD="${2:?Missing value for $1}"; shift 2 ;;
            -m|--mode)    ARG_MODE="${2:?Missing value for $1}"; shift 2 ;;
            -f|--format)  ARG_FORMAT="${2:?Missing value for $1}"; shift 2 ;;
            -o|--output)  ARG_OUTPUT="${2:?Missing value for $1}"; shift 2 ;;
            -b|--branch)  ARG_BRANCH="${2:?Missing value for $1}"; shift 2 ;;
            --provider|--model|--lang|--voice)
                die "$1 was removed in git-recap 2.0: AI writing now happens through the git-recap agent skill (npx skills add maxgfr/git-recap)" ;;
            --no-ai)      shift ;;  # Kept for compatibility: git-recap never calls AI
            --since)      ARG_SINCE="${2:?Missing value for $1}"; shift 2 ;;
            --until)      ARG_UNTIL="${2:?Missing value for $1}"; shift 2 ;;
            --exclude-author)
                ARG_EXCLUDE_AUTHORS+="${2:?Missing value for $1}"$'\n'; shift 2 ;;
            --all-commits) ARG_ALL_COMMITS=true; shift ;;
            --team)       ARG_TEAM=true; shift ;;
            --all-branches) ARG_ALL_BRANCHES=true; shift ;;
            --init)       ARG_INIT=true; shift ;;
            -h|--help)    show_help; exit 0 ;;
            -v|--version) echo "git-recap $VERSION"; exit 0 ;;
            -*)           die "Unknown option: $1" ;;
            *)
                [[ -z "$ARG_REPO" ]] || die "Unexpected argument: $1"
                ARG_REPO="$1"; shift ;;
        esac
    done
}

validate_args() {
    local mode="${ARG_MODE:-$DEFAULT_MODE}"
    local format="${ARG_FORMAT:-$DEFAULT_FORMAT}"

    case "$mode" in
        summary|commits|bullets|all) ;;
        *) die "Invalid mode: $mode (expected: summary, commits, bullets, all)" ;;
    esac

    case "$format" in
        text|markdown|json) ;;
        *) die "Invalid format: $format (expected: text, markdown, json)" ;;
    esac

    # A leading dash would be read as an option by git log
    [[ "$ARG_BRANCH" != -* ]] || die "Invalid branch name: $ARG_BRANCH"

    local d
    for d in "$ARG_SINCE" "$ARG_UNTIL"; do
        [[ -z "$d" ]] || _is_valid_date "$d" || die "Invalid date: $d (expected: YYYY-MM-DD)"
    done
    if [[ -n "$ARG_SINCE" && -n "$ARG_UNTIL" && "$ARG_SINCE" > "$ARG_UNTIL" ]]; then
        die "--since ($ARG_SINCE) is after --until ($ARG_UNTIL)"
    fi
    if [[ -n "$ARG_PERIOD" && ( -n "$ARG_SINCE" || -n "$ARG_UNTIL" ) ]]; then
        die "Use either -p/--period or --since/--until, not both"
    fi

    if [[ "$ARG_INIT" == false && -z "$ARG_REPO" ]]; then
        die "Missing required argument: <repo>. Use -h for help."
    fi
}

# ==============================================================================
# Configuration
# ==============================================================================

config_load() {
    if [[ -f "$CONFIG_FILE" ]]; then
        local _line_num=0
        while IFS= read -r _line || [[ -n "$_line" ]]; do
            _line_num=$((_line_num + 1))
            [[ -z "$_line" || "$_line" =~ ^[[:space:]]*# ]] && continue
            if [[ "$_line" =~ ^GIT_RECAP_USER=\"([^\"]*)\"$ ]]; then
                GIT_RECAP_USER="${BASH_REMATCH[1]}"
            elif [[ "$_line" =~ ^GIT_RECAP_FORMAT=\"([^\"]*)\"$ ]]; then
                GIT_RECAP_FORMAT="${BASH_REMATCH[1]}"
            elif [[ "$_line" =~ ^GIT_RECAP_(PROVIDER|MODEL|LANG|VOICE)=\"[^\"]*\"$ ]]; then
                :  # Legacy 1.x AI settings: accepted and ignored
            else
                warn "Ignoring unrecognized config line $_line_num in $CONFIG_FILE"
            fi
        done < "$CONFIG_FILE"
    fi
}

detect_github_user() {
    if command -v gh &>/dev/null; then
        if ! gh auth status &>/dev/null; then
            return
        fi
        gh api user --jq '.login' 2>/dev/null || true
    fi
}

detect_local_repo_user() {
    [[ -d "$ARG_REPO" ]] || return 1
    git -C "$ARG_REPO" rev-parse --is-inside-work-tree &>/dev/null || return 1

    local user
    user=$(git -C "$ARG_REPO" config user.name 2>/dev/null || true)
    [[ -z "$user" ]] && user=$(git -C "$ARG_REPO" log -1 --format='%an' 2>/dev/null || true)
    [[ -n "$user" ]] && printf '%s\n' "$user"
}

config_init() {
    info "Initializing git-recap configuration..."

    local detected_user
    detected_user=$(detect_github_user)

    local user=""
    if [[ -n "$detected_user" ]]; then
        printf "GitHub username [%s]: " "$detected_user" >&2
        read -r user
        [[ -z "$user" ]] && user="$detected_user"
    else
        printf "GitHub username: " >&2
        read -r user
        [[ -z "$user" ]] && die "Username is required"
    fi

    local default_format=""
    printf "Default format (text/markdown/json) [text]: " >&2
    read -r default_format
    [[ -z "$default_format" ]] && default_format="text"

    cat > "$CONFIG_FILE" <<EOF
# git-recap configuration
GIT_RECAP_USER="$user"
GIT_RECAP_FORMAT="$default_format"
EOF

    info "Configuration saved to $CONFIG_FILE"
}

# ==============================================================================
# Period computation
# ==============================================================================

compute_period() {
    if [[ -n "$ARG_SINCE" || -n "$ARG_UNTIL" ]]; then
        SINCE="${ARG_SINCE:+${ARG_SINCE}T00:00:00}"
        UNTIL="${ARG_UNTIL:+${ARG_UNTIL}T23:59:59}"
        PERIOD_LABEL="${ARG_SINCE:-beginning} → ${ARG_UNTIL:-today}"
        info "Period: $PERIOD_LABEL"
        return
    fi

    local period="${ARG_PERIOD:-$DEFAULT_PERIOD}"
    local today this_month
    today=$(_today)
    this_month="${today:0:7}"

    case "$period" in
        all)
            SINCE=""
            UNTIL=""
            PERIOD_LABEL="All time"
            ;;
        current|current-month)
            SINCE="${this_month}-01T00:00:00"
            UNTIL="$(_month_shift "$this_month" 1)-01T00:00:00"
            PERIOD_LABEL=$(_month_label "$this_month")
            ;;
        last|last-month)
            local last_month
            last_month=$(_month_shift "$this_month" -1)
            SINCE="${last_month}-01T00:00:00"
            UNTIL="${this_month}-01T00:00:00"
            PERIOD_LABEL=$(_month_label "$last_month")
            ;;
        current-week|last-week)
            # Weeks run Monday to Sunday
            local jdn monday
            jdn=$(_jdn "$today")
            monday=$(( jdn - jdn % 7 ))
            PERIOD_LABEL="Current week"
            if [[ "$period" == "last-week" ]]; then
                monday=$(( monday - 7 ))
                PERIOD_LABEL="Last week"
            fi
            SINCE="$(_from_jdn "$monday")T00:00:00"
            UNTIL="$(_from_jdn $(( monday + 7 )))T00:00:00"
            ;;
        current-year|last-year)
            local year=$(( 10#${today:0:4} ))
            [[ "$period" == "last-year" ]] && year=$(( year - 1 ))
            SINCE="${year}-01-01T00:00:00"
            UNTIL="$(( year + 1 ))-01-01T00:00:00"
            PERIOD_LABEL="$year"
            ;;
        [0-9]|[0-9][0-9])
            local first_month
            first_month=$(_month_shift "$this_month" "-$(( 10#$period ))")
            SINCE="${first_month}-01T00:00:00"
            UNTIL="$(_month_shift "$this_month" 1)-01T00:00:00"
            PERIOD_LABEL="$(_month_label "$first_month") - $(_month_label "$this_month")"
            ;;
        [0-9][0-9][0-9][0-9]-[0-9][0-9])
            local month=$(( 10#${period:5:2} ))
            [[ $month -ge 1 && $month -le 12 ]] || die "Invalid period: $period (month must be 01-12)"
            SINCE="${period}-01T00:00:00"
            UNTIL="$(_month_shift "$period" 1)-01T00:00:00"
            PERIOD_LABEL=$(_month_label "$period")
            ;;
        [0-9][0-9][0-9][0-9])
            SINCE="${period}-01-01T00:00:00"
            UNTIL="$(printf '%04d' $(( 10#$period + 1 )))-01-01T00:00:00"
            PERIOD_LABEL="$period"
            ;;
        *)
            die "Invalid period: $period (expected: current-month, last-month, current-week, last-week, current-year, last-year, all, <N>, YYYY-MM, YYYY)"
            ;;
    esac

    if [[ -n "$SINCE" && -n "$UNTIL" ]]; then
        info "Period: $PERIOD_LABEL ($SINCE → $UNTIL)"
    else
        info "Period: $PERIOD_LABEL"
    fi
}

# ==============================================================================
# Repo resolution
# ==============================================================================

resolve_repo() {
    local repo="$ARG_REPO"

    # Local path
    if [[ -d "$repo" ]] && git -C "$repo" rev-parse --is-inside-work-tree &>/dev/null; then
        REPO_MODE="local"
        local dir
        dir=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) || die "Could not resolve Git repository root: $repo"
        LOCAL_REPO_DIR="$dir"
        REPO_NAME="$(basename "$dir")"
        local remote_url
        remote_url=$(git -C "$dir" remote get-url origin 2>/dev/null || true)
        case "$remote_url" in
            https://github.com/*|git@github.com:*)
                REPO_FULL=$(echo "$remote_url" | sed -E 's#^(https://github\.com/|git@github\.com:)##; s/\.git$//; s#/$##')
                REPO_NAME="${REPO_FULL##*/}"
                REPO_WEB_URL="https://github.com/${REPO_FULL}"
                ;;
            *)
                REPO_FULL="$REPO_NAME"
                REPO_WEB_URL=""
                ;;
        esac
        info "Local repo: $REPO_FULL"
        return
    fi

    # A path that is not a work tree must not be mistaken for a GitHub repo
    case "$repo" in
        .|..|./*|../*|/*|"~"*) die "Not a git repository: $repo" ;;
    esac

    REPO_MODE="remote"

    local via=""
    case "$repo" in
        https://github.com/*|git@github.com:*)
            # Keep owner/repo only: URLs copied from a browser carry /tree/..., /pull/...
            repo=$(printf '%s\n' "$repo" | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#^([^/]+/[^/]+).*#\1#; s/\.git$//')
            ;;
        */*) ;;
        *)
            # repo name only — prefix with username
            [[ -n "$USER_NAME" ]] || die "Cannot resolve \"$repo\" without a GitHub user. Use owner/repo or -u"
            repo="${USER_NAME}/${repo}"
            via=" (using user: $USER_NAME)"
            ;;
    esac

    # The name goes into API paths: accept what GitHub accepts, nothing else
    [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
        || die "Invalid repository: $ARG_REPO (expected owner/repo, a GitHub URL or a local path)"

    REPO_FULL="$repo"
    REPO_NAME="${REPO_FULL##*/}"
    REPO_WEB_URL="https://github.com/${REPO_FULL}"
    info "Repo: ${REPO_FULL}${via}"
}

# _local_ref_exists <ref> : true when <ref> names a commit in the local repo
_local_ref_exists() {
    git -C "$LOCAL_REPO_DIR" rev-parse --verify --quiet "${1}^{commit}" >/dev/null 2>&1
}

detect_default_branch() {
    if [[ "$ARG_ALL_BRANCHES" == true ]]; then
        BRANCH="__all__"
        info "Branch: all branches"
        return
    fi

    if [[ -n "$ARG_BRANCH" ]]; then
        if [[ "$REPO_MODE" == "local" ]] && ! _local_ref_exists "$ARG_BRANCH"; then
            die "Branch not found in $REPO_NAME: $ARG_BRANCH"
        fi
        BRANCH="$ARG_BRANCH"
        info "Branch: $BRANCH"
        return
    fi

    if [[ "$REPO_MODE" == "local" ]]; then
        # origin's default branch when it exists here (as a local branch, else
        # as origin/<branch>), otherwise the current branch
        local default
        default=$(git -C "$LOCAL_REPO_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#refs/remotes/origin/##' || true)
        if [[ -n "$default" ]] && _local_ref_exists "refs/heads/$default"; then
            BRANCH="$default"
        elif [[ -n "$default" ]] && _local_ref_exists "refs/remotes/origin/$default"; then
            BRANCH="origin/$default"
        else
            BRANCH=$(git -C "$LOCAL_REPO_DIR" branch --show-current 2>/dev/null || true)
        fi
        [[ -z "$BRANCH" ]] && BRANCH="HEAD"
    else
        BRANCH=$(_github_get "repos/${REPO_FULL}" '.default_branch') || exit 1
    fi

    info "Branch: $BRANCH"
}

# ==============================================================================
# Dependencies
# ==============================================================================

check_gh_auth() {
    if command -v gh &>/dev/null; then
        if ! gh auth status &>/dev/null; then
            die "gh is not authenticated. Run: gh auth login"
        fi
    fi
}

check_dependencies() {
    command -v git &>/dev/null || die "git is required but not found"

    local format="${ARG_FORMAT:-$DEFAULT_FORMAT}"
    if [[ "$format" == "json" ]]; then
        command -v jq &>/dev/null || die "jq is required for JSON format"
    fi

    if [[ "${REPO_MODE:-remote}" == "remote" ]]; then
        if ! command -v gh &>/dev/null; then
            command -v curl &>/dev/null || die "gh or curl is required for remote repos"
            command -v jq &>/dev/null || die "jq is required when using curl fallback"
        fi
        check_gh_auth
    fi
}

# ==============================================================================
# Fetch commits
# ==============================================================================

# Commits travel as TSV: hash, subject, date, plus the author in team mode.
# Every fetcher takes <mode> ("team" or "") and <fields> (3 or 4).

# _urlencode <string> → percent-encoded query parameter value (byte-wise)
_urlencode() {
    local LC_ALL=C
    local s="$1" out="" c code hex i
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9._~/-]) out+="$c" ;;
            *)
                printf -v code '%d' "'$c"
                printf -v hex '%%%02X' $(( code & 255 ))
                out+="$hex"
                ;;
        esac
    done
    printf '%s' "$out"
}

# _commits_query <branch> <mode> → query string for the GitHub commits endpoint
_commits_query() {
    local query
    query="sha=$(_urlencode "$1")"
    [[ "$2" == "team" ]] || query+="&author=$(_urlencode "$USER_NAME")"
    query+="&per_page=100"
    [[ -n "$SINCE" ]] && query+="&since=${SINCE}Z"
    [[ -n "$UNTIL" ]] && query+="&until=${UNTIL}Z"
    printf '%s' "$query"
}

_fetch_local() {
    local mode="$1"
    # --no-show-signature: log.showSignature would mix gpg output into the rows
    local git_args=(--no-show-signature)
    if [[ "$ARG_ALL_BRANCHES" == true ]]; then
        # Not --all: that also walks refs/stash and refs/notes
        git_args+=(--branches --remotes --tags)
    else
        # A repository without any commit has nothing to list
        _local_ref_exists "$BRANCH" || return 0
        git_args+=("$BRANCH")
    fi
    local row_format='%h%x1f%s%x1f%as%x1f%aN'
    if [[ "$mode" != "team" ]]; then
        row_format='%h%x1f%s%x1f%as'
        git_args+=(--author="$USER_NAME")
    fi
    git_args+=(--no-merges)
    [[ -n "$SINCE" ]] && git_args+=(--since="$SINCE")
    [[ -n "$UNTIL" ]] && git_args+=(--until="$UNTIL")
    # The trailing "--" keeps a branch named like a path from being ambiguous
    git -C "$LOCAL_REPO_DIR" log "${git_args[@]}" --format="$row_format" -- | _tsv_rows \
        || die "git log failed in $LOCAL_REPO_DIR"
    _collect_local_details "${git_args[@]}"
}

# _github_die <error text> : exit with a readable message for a failed API call.
# The HTTP status is read from a "(HTTP nnn)" marker, as printed by gh.
_github_die() {
    local err="$1" status=""
    [[ "$err" =~ \(HTTP\ ([0-9]{3})\) ]] && status="${BASH_REMATCH[1]}"
    case "$status" in
        401) die "GitHub rejected the credentials. Run: gh auth login" ;;
        403|429) die "Access denied (rate limit or permissions): ${REPO_FULL}" ;;
        404)
            if [[ -n "$ARG_BRANCH" ]]; then
                die "Repository or branch not found: ${REPO_FULL} (branch: ${ARG_BRANCH})"
            fi
            die "Repository not found: ${REPO_FULL}" ;;
        *) die "GitHub API error: ${err:-unknown error}" ;;
    esac
}

# _github_get <path?query> <jq filter> → filtered output of a paginated GitHub
# API GET, through gh or, without it, curl. Any failure aborts: a partial
# result is never returned. An empty repository (HTTP 409) yields nothing.
_github_get() {
    local path="$1" filter="$2" out err
    if ! command -v gh &>/dev/null; then
        _github_get_curl "$path" "$filter"
        return
    fi
    if ! out=$(gh api "$path" --paginate --jq "$filter" 2>"$WORK_DIR/api.err" </dev/null); then
        err=$(cat "$WORK_DIR/api.err")
        [[ "$err" == *"(HTTP 409)"* ]] && return 0
        _github_die "$err"
    fi
    [[ -z "$out" ]] || printf '%s\n' "$out"
}

# curl backend of _github_get: unauthenticated, follows Link rel="next" pages
_github_get_curl() {
    local url="https://api.github.com/$1" filter="$2" status
    local body="$WORK_DIR/curl.body" headers="$WORK_DIR/curl.headers"
    while [[ -n "$url" ]]; do
        # -g: brackets in a URL are data, not a glob
        if ! status=$(curl -sS -g -L -o "$body" -D "$headers" -w '%{http_code}' \
            -H "Accept: application/vnd.github+json" "$url" 2>"$WORK_DIR/api.err"); then
            _github_die "$(cat "$WORK_DIR/api.err")"
        fi
        case "$status" in
            200) ;;
            409) return 0 ;;
            *) _github_die "$(jq -r '.message // empty' "$body" 2>/dev/null) (HTTP ${status})" ;;
        esac
        jq -r "$filter" "$body" || die "Unexpected response from the GitHub API: $url"
        url=$(sed -n 's/.*<\([^>]*\)>; *rel="next".*/\1/p' "$headers" | tr -d '\r')
    done
}

_fetch_github() {
    local mode="$1" fields="$2" filter raw
    filter=$(_gh_commit_jq "$mode")

    if [[ "$ARG_ALL_BRANCHES" == true ]]; then
        local branches branch
        branches=$(_github_get "repos/${REPO_FULL}/branches?per_page=100" '.[].name') || exit 1
        raw=$(
            while IFS= read -r branch; do
                [[ -z "$branch" ]] && continue
                _github_get "repos/${REPO_FULL}/commits?$(_commits_query "$branch" "$mode")" "$filter" || exit 1
            done <<< "$branches"
        ) || exit 1
        # A commit reachable from several branches is listed once; newest day first
        raw=$(printf '%s\n' "$raw" | awk -F'\t' '!seen[$1]++' | sort -s -t$'\t' -k3,3r)
    else
        raw=$(_github_get "repos/${REPO_FULL}/commits?$(_commits_query "$BRANCH" "$mode")" "$filter") || exit 1
    fi

    printf '%s\n' "$raw" | _split_details "$fields"
}

# fetch_commits [team] → filtered commit TSV (empty line when there is none)
fetch_commits() {
    local mode="${1:-}" fields=3 what="commits" suffix=""
    if [[ "$mode" == "team" ]]; then
        fields=4 what="all commits" suffix=", team mode"
    fi

    # Errors inside $(...) do not stop the caller: propagate them explicitly
    local commits=""
    if [[ "$REPO_MODE" == "local" ]]; then
        info "Fetching ${what} (local${suffix})..."
        commits=$(_fetch_local "$mode") || exit 1
    else
        local client="gh api"
        command -v gh &>/dev/null || client="curl"
        info "Fetching ${what} (${client}${suffix})..."
        commits=$(_fetch_github "$mode" "$fields") || exit 1
    fi

    commits=$(printf '%s\n' "$commits" | filter_noise "$fields")

    if [[ -z "$commits" ]]; then
        if [[ "$mode" == "team" ]]; then
            warn "No commits found on $REPO_FULL ($PERIOD_LABEL)"
        else
            warn "No commits found for $USER_NAME on $REPO_FULL ($PERIOD_LABEL)"
        fi
        echo ""
        return
    fi

    local count
    count=$(echo "$commits" | wc -l | tr -d ' ')
    if [[ "$mode" == "team" ]]; then
        local author_count
        author_count=$(echo "$commits" | cut -f4 | sort -u | wc -l | tr -d ' ')
        info "Found $count commit(s) from $author_count contributor(s)"
    else
        info "Found $count commit(s)"
    fi

    echo "$commits"
}

# ==============================================================================
# Stats
# ==============================================================================

# compute_stats <rows> → total|first_date|last_date|busiest_day|busiest_count|
#                        active_days|avg_per_day|busiest_weekday|longest_streak
compute_stats() {
    local commits="$1"
    [[ -z "$commits" ]] && return

    printf '%s\n' "$commits" | LC_ALL=C awk -F'\t' '
        # Julian day number of YYYY-MM-DD (jdn % 7 is 0 on Mondays)
        function jdn(date,    p, y, m, d, a) {
            split(date, p, "-")
            y = p[1] + 0; m = p[2] + 0; d = p[3] + 0
            a = int((14 - m) / 12); y = y + 4800 - a; m = m + 12 * a - 3
            return d + int((153 * m + 2) / 5) + 365 * y + int(y / 4) - int(y / 100) + int(y / 400) - 32045
        }
        length($0) > 0 {
            total++
            date = $3 ""
            if (!(date in per_day)) {
                j = jdn(date)
                on_day[j] = 1
                if (active_days == 0 || j < first_j) first_j = j
                if (active_days == 0 || j > last_j) last_j = j
                active_days++
            }
            per_day[date]++
            if (first == "" || date < first) first = date
            if (date > last) last = date
        }
        END {
            if (total == 0) exit

            # Busiest day: most commits, the latest one on a tie
            busiest_day = ""; busiest_count = 0
            for (date in per_day) {
                if (per_day[date] > busiest_count || (per_day[date] == busiest_count && (date "") > busiest_day)) {
                    busiest_count = per_day[date]
                    busiest_day = date ""
                }
                per_weekday[(jdn(date) + 1) % 7] += per_day[date]  # 0 = Sunday
            }

            # Busiest weekday: the first one in the week on a tie
            split("Sunday Monday Tuesday Wednesday Thursday Friday Saturday", names, " ")
            best = 0; most = 0
            for (i = 0; i <= 6; i++) {
                if (per_weekday[i] + 0 > most) { most = per_weekday[i]; best = i }
            }

            # Longest streak of consecutive days with commits
            streak = 0; longest = 0
            for (j = first_j; j <= last_j; j++) {
                if (j in on_day) { streak++; if (streak > longest) longest = streak } else streak = 0
            }

            printf "%d|%s|%s|%s|%d|%d|%.1f|%s|%d", total, first, last, busiest_day, busiest_count,
                active_days, total / active_days, names[best + 1], longest
        }'
}

# ==============================================================================
# Formatting
# ==============================================================================

format_output() {
    local commits="$1"
    local summary="$2"
    local bullets="$3"
    local stats="$4"
    local format="${ARG_FORMAT:-$DEFAULT_FORMAT}"
    local mode="${ARG_MODE:-$DEFAULT_MODE}"

    case "$format" in
        markdown) format_markdown "$commits" "$summary" "$mode" "$bullets" "$stats" ;;
        json)     format_json "$commits" "$summary" "$mode" "$bullets" "$stats" ;;
        *)        format_text "$commits" "$summary" "$mode" "$bullets" "$stats" ;;
    esac
}

format_markdown() {
    local commits="$1"
    local summary="$2"
    local mode="$3"
    local bullets="$4"
    local stats="$5"

    echo "# Monthly Recap - ${REPO_NAME} - ${PERIOD_LABEL}"
    echo ""

    if [[ -n "$stats" ]]; then
        local total first_date last_date busiest_day busiest_count active_days avg_per_day busiest_weekday longest_streak
        IFS='|' read -r total first_date last_date busiest_day busiest_count active_days avg_per_day busiest_weekday longest_streak <<< "$stats"
        echo "## Stats"
        echo ""
        echo "| Metric | Value |"
        echo "|--------|-------|"
        echo "| Total commits | ${total} |"
        echo "| Active days | ${active_days:-0} |"
        echo "| Avg per day | ${avg_per_day:-0.0} |"
        echo "| Longest streak | ${longest_streak:-0} day(s) |"
        echo "| First commit | ${first_date} |"
        echo "| Last commit | ${last_date} |"
        echo "| Busiest day | ${busiest_day} (${busiest_count} commits) |"
        echo "| Busiest weekday | ${busiest_weekday:-N/A} |"
        echo ""
    fi

    if [[ ("$mode" == "summary" || "$mode" == "all") && -n "$summary" ]]; then
        echo "## Summary"
        echo ""
        echo "$summary"
        echo ""
    fi

    if [[ "$mode" == "bullets" || "$mode" == "all" ]]; then
        if [[ -n "$bullets" ]]; then
            echo "## Changes"
            echo ""
            _print_bullets "$bullets" "- "
            echo ""
        fi
    fi

    if [[ "$mode" == "commits" || "$mode" == "all" ]]; then
        if [[ -n "$commits" ]]; then
            echo "## Commits"
            echo ""
            echo "| Date | Hash | Message |"
            echo "|------|------|---------|"
            echo "$commits" | while IFS=$'\t' read -r hash msg date; do
                local commit_ref
                commit_ref=$(_markdown_commit_ref "$hash")
                echo "| ${date} | ${commit_ref} | ${msg//|/\\|} |"
            done
            echo ""
        fi
    fi
}

format_text() {
    local commits="$1"
    local summary="$2"
    local mode="$3"
    local bullets="$4"
    local stats="$5"

    echo "=== Monthly Recap - ${REPO_NAME} - ${PERIOD_LABEL} ==="
    echo ""

    if [[ -n "$stats" ]]; then
        local total first_date last_date busiest_day busiest_count active_days avg_per_day busiest_weekday longest_streak
        IFS='|' read -r total first_date last_date busiest_day busiest_count active_days avg_per_day busiest_weekday longest_streak <<< "$stats"
        echo "--- Stats ---"
        echo ""
        echo "  Total commits:   ${total}"
        echo "  Active days:     ${active_days:-0}"
        echo "  Avg per day:     ${avg_per_day:-0.0}"
        echo "  Longest streak:  ${longest_streak:-0} day(s)"
        echo "  First commit:    ${first_date}"
        echo "  Last commit:     ${last_date}"
        echo "  Busiest day:     ${busiest_day} (${busiest_count} commits)"
        echo "  Busiest weekday: ${busiest_weekday:-N/A}"
        echo ""
    fi

    if [[ ("$mode" == "summary" || "$mode" == "all") && -n "$summary" ]]; then
        echo "--- Summary ---"
        echo ""
        echo "$summary"
        echo ""
    fi

    if [[ "$mode" == "bullets" || "$mode" == "all" ]]; then
        if [[ -n "$bullets" ]]; then
            echo "--- Changes ---"
            echo ""
            _print_bullets "$bullets" "  • "
            echo ""
        fi
    fi

    if [[ "$mode" == "commits" || "$mode" == "all" ]]; then
        if [[ -n "$commits" ]]; then
            echo "--- Commits ---"
            echo ""
            local prev_date=""
            echo "$commits" | while IFS=$'\t' read -r hash msg date; do
                if [[ "$date" != "$prev_date" ]]; then
                    [[ -n "$prev_date" ]] && echo ""
                    echo "  ${date}"
                    prev_date="$date"
                fi
                echo "    ${hash}  ${msg}"
            done
            echo ""
        fi
    fi
}

format_json() {
    local commits="$1"
    local mode="$3"
    local stats="$5"

    # shellcheck disable=SC2016  # the $names below are jq variables
    printf '%s\n' "$commits" | jq -R -s \
        --slurpfile d "$DETAILS_FILE" \
        --arg mode "$mode" \
        --arg repo "$REPO_FULL" \
        --arg repo_name "$REPO_NAME" \
        --arg period "$PERIOD_LABEL" \
        --arg since "$SINCE" \
        --arg until "$UNTIL" \
        --arg user "$USER_NAME" \
        --argjson stats "$(_stats_json "$stats")" \
        "$_JQ_RECAP"'
        rows as $rows | details as $m
        | {
            repo: $repo,
            repo_name: $repo_name,
            period: $period,
            since: $since,
            until: $until,
            user: $user,
            stats: ($stats | stats_object)
        }
        | with_change_stats($rows; $m; "stats")
        | with_content($rows; $m)' \
        || die "Could not build the JSON output"
}

# ==============================================================================
# Team mode output
# ==============================================================================

# _author_commits <team rows> <author> → that author's rows, without the author
# column. The name goes through the environment (awk -v would interpret its
# backslashes) and is compared as a string ("0123" is not "123").
_author_commits() {
    printf '%s\n' "$1" | AUTHOR="$2" LC_ALL=C awk -F'\t' -v OFS='\t' \
        '($4 "") == (ENVIRON["AUTHOR"] "") { print $1, $2, $3 }'
}

_team_stats_text() {
    local stats="$1" label="$2"
    [[ -z "$stats" ]] && return
    local total first_date last_date busiest_day busiest_count active_days avg_per_day busiest_weekday longest_streak
    IFS='|' read -r total first_date last_date busiest_day busiest_count active_days avg_per_day busiest_weekday longest_streak <<< "$stats"
    echo "  ${label}"
    echo "    Commits:        ${total}"
    echo "    Active days:    ${active_days:-0}"
    echo "    Avg per day:    ${avg_per_day:-0.0}"
    echo "    Streak:         ${longest_streak:-0} day(s)"
    echo "    Busiest day:    ${busiest_day} (${busiest_count})"
    echo "    Busiest weekday: ${busiest_weekday:-N/A}"
}

output_team_text() {
    local all_commits="$1"
    local mode="${ARG_MODE:-$DEFAULT_MODE}"

    local authors
    authors=$(echo "$all_commits" | cut -f4 | sort | uniq -c | sort -rn | sed -E 's/^ *[0-9]+ //')
    local num_authors
    num_authors=$(echo "$authors" | wc -l | tr -d ' ')

    local global_3f
    global_3f=$(echo "$all_commits" | cut -f1-3)
    local global_stats
    global_stats=$(compute_stats "$global_3f")
    local total first_date last_date busiest_day busiest_count active_days avg_per_day busiest_weekday longest_streak
    IFS='|' read -r total first_date last_date busiest_day busiest_count active_days avg_per_day busiest_weekday longest_streak <<< "$global_stats"

    local branch_label
    if [[ "$ARG_ALL_BRANCHES" == true ]]; then
        branch_label="all branches"
    else
        branch_label="$BRANCH"
    fi

    echo "=== Team Recap - ${REPO_NAME} - ${PERIOD_LABEL} ==="
    echo ""
    echo "--- Overview ---"
    echo ""
    echo "  Contributors:    ${num_authors}"
    echo "  Total commits:   ${total}"
    echo "  Branch:          ${branch_label}"
    echo "  Active days:     ${active_days:-0}"
    echo "  Avg per day:     ${avg_per_day:-0.0}"
    echo "  Longest streak:  ${longest_streak:-0} day(s)"
    echo "  Period:          ${first_date} → ${last_date}"
    echo "  Busiest day:     ${busiest_day} (${busiest_count} commits)"
    echo "  Busiest weekday: ${busiest_weekday:-N/A}"
    echo ""

    # Top contributors ranking
    echo "--- Contributors ---"
    echo ""
    local rank=1
    echo "$all_commits" | cut -f4 | sort | uniq -c | sort -rn | while read -r cnt author; do
        local pct
        pct=$(LANG=C LC_ALL=C awk "BEGIN {printf \"%.0f\", ($cnt / $total) * 100}")
        printf '  %d. %-20s %3d commits (%s%%)\n' "$rank" "$author" "$cnt" "$pct"
        rank=$((rank + 1))
    done
    echo ""

    # Per-author sections
    while IFS= read -r author; do
        [[ -z "$author" ]] && continue
        local ac
        ac=$(_author_commits "$all_commits" "$author")
        local ac_count
        ac_count=$(echo "$ac" | wc -l | tr -d ' ')

        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        printf '▶ %s (%d commits)\n' "$author" "$ac_count"
        echo ""

        # Per-author stats (compact)
        local ac_stats
        ac_stats=$(compute_stats "$ac")
        _team_stats_text "$ac_stats" "Stats:"
        echo ""

        # Raw content (summaries are written by the git-recap agent skill)
        local ac_summary="" ac_bullets=""
        USER_NAME="$author"
        ac_bullets=$(raw_bullets "$ac")

        if [[ ("$mode" == "summary" || "$mode" == "all") && -n "$ac_summary" ]]; then
            echo "  Summary:"
            printf '%s\n' "${ac_summary//$'\n'/$'\n'    }" | sed 's/^/    /'
            echo ""
        fi

        if [[ "$mode" == "bullets" || "$mode" == "all" ]]; then
            if [[ -n "$ac_bullets" ]]; then
                echo "  Changes:"
                _print_bullets "$ac_bullets" "    • "
                echo ""
            fi
        fi

        if [[ "$mode" == "commits" || "$mode" == "all" ]]; then
            if [[ -n "$ac" ]]; then
                echo "  Commits:"
                local prev_date=""
                echo "$ac" | while IFS=$'\t' read -r hash msg date; do
                    if [[ "$date" != "$prev_date" ]]; then
                        [[ -n "$prev_date" ]] && echo ""
                        echo "    ${date}"
                        prev_date="$date"
                    fi
                    echo "      ${hash}  ${msg}"
                done
                echo ""
            fi
        fi
    done <<< "$authors"
}

output_team_markdown() {
    local all_commits="$1"
    local mode="${ARG_MODE:-$DEFAULT_MODE}"

    local authors
    authors=$(echo "$all_commits" | cut -f4 | sort | uniq -c | sort -rn | sed -E 's/^ *[0-9]+ //')
    local num_authors
    num_authors=$(echo "$authors" | wc -l | tr -d ' ')

    local global_3f
    global_3f=$(echo "$all_commits" | cut -f1-3)
    local global_stats
    global_stats=$(compute_stats "$global_3f")
    local total first_date last_date busiest_day busiest_count active_days avg_per_day busiest_weekday longest_streak
    IFS='|' read -r total first_date last_date busiest_day busiest_count active_days avg_per_day busiest_weekday longest_streak <<< "$global_stats"

    local branch_label
    if [[ "$ARG_ALL_BRANCHES" == true ]]; then
        branch_label="all branches"
    else
        branch_label="$BRANCH"
    fi

    echo "# Team Recap - ${REPO_NAME} - ${PERIOD_LABEL}"
    echo ""
    echo "## Overview"
    echo ""
    echo "| Metric | Value |"
    echo "|--------|-------|"
    echo "| Contributors | ${num_authors} |"
    echo "| Total commits | ${total} |"
    echo "| Branch | ${branch_label} |"
    echo "| Active days | ${active_days:-0} |"
    echo "| Avg per day | ${avg_per_day:-0.0} |"
    echo "| Longest streak | ${longest_streak:-0} day(s) |"
    echo "| Period | ${first_date} → ${last_date} |"
    echo "| Busiest day | ${busiest_day} (${busiest_count} commits) |"
    echo "| Busiest weekday | ${busiest_weekday:-N/A} |"
    echo ""

    # Contributors ranking
    echo "## Contributors"
    echo ""
    echo "| # | Contributor | Commits | % |"
    echo "|---|-------------|---------|---|"
    local rank=1
    echo "$all_commits" | cut -f4 | sort | uniq -c | sort -rn | while read -r cnt author; do
        local pct
        pct=$(LANG=C LC_ALL=C awk "BEGIN {printf \"%.0f\", ($cnt / $total) * 100}")
        echo "| ${rank} | ${author//|/\\|} | ${cnt} | ${pct}% |"
        rank=$((rank + 1))
    done
    echo ""

    # Per-author sections
    while IFS= read -r author; do
        [[ -z "$author" ]] && continue
        local ac
        ac=$(_author_commits "$all_commits" "$author")
        local ac_count
        ac_count=$(echo "$ac" | wc -l | tr -d ' ')

        echo "## ${author} (${ac_count} commits)"
        echo ""

        # Per-author stats
        local ac_stats
        ac_stats=$(compute_stats "$ac")
        local a_total a_busiest_day a_busiest_count a_active_days a_avg a_streak
        IFS='|' read -r a_total _ _ a_busiest_day a_busiest_count a_active_days a_avg _ a_streak <<< "$ac_stats"
        echo "| Metric | Value |"
        echo "|--------|-------|"
        echo "| Commits | ${a_total} |"
        echo "| Active days | ${a_active_days:-0} |"
        echo "| Avg per day | ${a_avg:-0.0} |"
        echo "| Streak | ${a_streak:-0} day(s) |"
        echo "| Busiest day | ${a_busiest_day} (${a_busiest_count}) |"
        echo ""

        # Raw content (summaries are written by the git-recap agent skill)
        local ac_summary="" ac_bullets=""
        USER_NAME="$author"
        ac_bullets=$(raw_bullets "$ac")

        if [[ ("$mode" == "summary" || "$mode" == "all") && -n "$ac_summary" ]]; then
            echo "### Summary"
            echo ""
            echo "$ac_summary"
            echo ""
        fi

        if [[ "$mode" == "bullets" || "$mode" == "all" ]]; then
            if [[ -n "$ac_bullets" ]]; then
                echo "### Changes"
                echo ""
                _print_bullets "$ac_bullets" "- "
                echo ""
            fi
        fi

        if [[ "$mode" == "commits" || "$mode" == "all" ]]; then
            if [[ -n "$ac" ]]; then
                echo "### Commits"
                echo ""
                echo "| Date | Hash | Message |"
                echo "|------|------|---------|"
                echo "$ac" | while IFS=$'\t' read -r hash msg date; do
                    local commit_ref
                    commit_ref=$(_markdown_commit_ref "$hash")
                    echo "| ${date} | ${commit_ref} | ${msg//|/\\|} |"
                done
                echo ""
            fi
        fi
    done <<< "$authors"
}

output_team_json() {
    local all_commits="$1"
    local mode="${ARG_MODE:-$DEFAULT_MODE}"

    local branch_label
    if [[ "$ARG_ALL_BRANCHES" == true ]]; then
        branch_label="all"
    else
        branch_label="$BRANCH"
    fi

    local global_stats
    global_stats=$(compute_stats "$(echo "$all_commits" | cut -f1-3)")

    # Authors by commit count, and their stats in the same order
    local authors author
    authors=$(echo "$all_commits" | cut -f4 | sort | uniq -c | sort -rn | sed -E 's/^ *[0-9]+ //')
    printf '%s\n' "$authors" | jq -R 'select(length > 0)' > "$WORK_DIR/authors.json" \
        || die "Could not build the JSON output"
    while IFS= read -r author; do
        [[ -z "$author" ]] && continue
        _stats_json "$(compute_stats "$(_author_commits "$all_commits" "$author")")"
    done <<< "$authors" > "$WORK_DIR/author_stats.json"

    # shellcheck disable=SC2016  # the $names below are jq variables
    printf '%s\n' "$all_commits" | jq -R -s \
        --slurpfile d "$DETAILS_FILE" \
        --slurpfile authors "$WORK_DIR/authors.json" \
        --slurpfile author_stats "$WORK_DIR/author_stats.json" \
        --arg mode "$mode" \
        --arg repo "$REPO_FULL" \
        --arg repo_name "$REPO_NAME" \
        --arg period "$PERIOD_LABEL" \
        --arg since "$SINCE" \
        --arg until "$UNTIL" \
        --arg branch "$branch_label" \
        --argjson stats "$(_stats_json "$global_stats")" \
        "$_JQ_RECAP"'
        rows as $rows | details as $m
        | (reduce $rows[] as $r ({}; .[$r[3]] += [$r[0:3]])) as $by_author
        | {
            repo: $repo,
            repo_name: $repo_name,
            period: $period,
            since: $since,
            until: $until,
            branch: $branch,
            team: true,
            global_stats: ($stats | stats_object | to_entries
                | .[0:1] + [{key: "contributors", value: ($authors | length)}] + .[1:]
                | from_entries),
            contributors: [
                range(0; $authors | length) as $i
                | ($by_author[$authors[$i]] // []) as $own
                | {user: $authors[$i], stats: ($author_stats[$i] | stats_object)}
                | with_change_stats($own; $m; "stats")
                | with_content($own; $m)
            ]
        }
        | with_change_stats($rows; $m; "global_stats")' \
        || die "Could not build the JSON output"
}

output_team() {
    local all_commits="$1"
    local format="${ARG_FORMAT:-$DEFAULT_FORMAT}"

    case "$format" in
        text)     output_team_text "$all_commits" ;;
        markdown) output_team_markdown "$all_commits" ;;
        json)     output_team_json "$all_commits" ;;
    esac
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    parse_args "$@"

    # Load config
    config_load

    # Handle --init
    if [[ "$ARG_INIT" == true ]]; then
        config_init
        exit 0
    fi

    # Resolve format from config if not set via CLI (before validation, so a
    # bad config value is rejected like a bad -f)
    if [[ -z "$ARG_FORMAT" && -n "${GIT_RECAP_FORMAT:-}" ]]; then
        ARG_FORMAT="$GIT_RECAP_FORMAT"
    fi

    validate_args

    # Compute period (first: a bad period must fail before any network call)
    compute_period

    # Resolve user: CLI flag > config > auto-detect
    if [[ "$ARG_TEAM" == true ]]; then
        # In team mode, user is optional (only needed for repo name resolution)
        if [[ -n "$ARG_USER" ]]; then
            USER_NAME="$ARG_USER"
        elif [[ -n "${GIT_RECAP_USER:-}" ]]; then
            USER_NAME="$GIT_RECAP_USER"
        else
            USER_NAME=$(detect_github_user) || true
        fi
        info "Team mode: all contributors"
    else
        if [[ -n "$ARG_USER" ]]; then
            USER_NAME="$ARG_USER"
        elif [[ -n "${GIT_RECAP_USER:-}" ]]; then
            USER_NAME="$GIT_RECAP_USER"
        else
            USER_NAME=$(detect_local_repo_user || true)
            [[ -z "$USER_NAME" ]] && USER_NAME=$(detect_github_user)
            [[ -n "$USER_NAME" ]] || die "Could not detect GitHub user. Use -u or run --init"
        fi
        info "User: $USER_NAME"
    fi

    # Resolve repo
    resolve_repo

    # Check deps
    check_dependencies

    WORK_DIR=$(mktemp -d)

    # Detect branch
    detect_default_branch

    # JSON output carries commit bodies (and changed files for local repos)
    if [[ "${ARG_FORMAT:-$DEFAULT_FORMAT}" == "json" ]]; then
        DETAILS_FILE="$WORK_DIR/details.jsonl"
        : > "$DETAILS_FILE"
    fi

    # === Team mode ===
    if [[ "$ARG_TEAM" == true ]]; then
        local all_commits
        all_commits=$(fetch_commits team)

        if [[ -z "$all_commits" ]]; then
            local format="${ARG_FORMAT:-$DEFAULT_FORMAT}"
            local output=""
            case "$format" in
                markdown) output="# Team Recap - ${REPO_NAME} - ${PERIOD_LABEL}

No commits found during this period.
" ;;
                json) output=$(jq -n \
                    --arg repo "$REPO_FULL" \
                    --arg repo_name "$REPO_NAME" \
                    --arg period "$PERIOD_LABEL" \
                    --arg since "$SINCE" \
                    --arg until "$UNTIL" \
                    '{repo: $repo, repo_name: $repo_name, period: $period, since: $since, until: $until, team: true, contributors: []}') ;;
                *) output="=== Team Recap - ${REPO_NAME} - ${PERIOD_LABEL} ===

No commits found during this period.
" ;;
            esac
            if [[ -n "$ARG_OUTPUT" ]]; then
                echo "$output" > "$ARG_OUTPUT"
                info "Output written to $ARG_OUTPUT"
            else
                echo "$output"
            fi
            exit 0
        fi

        local output
        output=$(output_team "$all_commits")

        if [[ -n "$ARG_OUTPUT" ]]; then
            echo "$output" > "$ARG_OUTPUT"
            info "Output written to $ARG_OUTPUT"
        else
            echo "$output"
        fi
        exit 0
    fi

    # === Single user mode ===
    local commits
    commits=$(fetch_commits)

    if [[ -z "$commits" ]]; then
        local format="${ARG_FORMAT:-$DEFAULT_FORMAT}"
        local output=""
        case "$format" in
            markdown)
                output="# Monthly Recap - ${REPO_NAME} - ${PERIOD_LABEL}

No commits found for **${USER_NAME}** during this period.
"
                ;;
            json)
                output=$(jq -n \
                    --arg repo "$REPO_FULL" \
                    --arg repo_name "$REPO_NAME" \
                    --arg period "$PERIOD_LABEL" \
                    --arg since "$SINCE" \
                    --arg until "$UNTIL" \
                    --arg user "$USER_NAME" \
                    '{repo: $repo, repo_name: $repo_name, period: $period, since: $since, until: $until, user: $user, commits: []}')
                ;;
            *)
                output="=== Monthly Recap - ${REPO_NAME} - ${PERIOD_LABEL} ===

No commits found for ${USER_NAME} during this period.
"
                ;;
        esac
        if [[ -n "$ARG_OUTPUT" ]]; then
            echo "$output" > "$ARG_OUTPUT"
            info "Output written to $ARG_OUTPUT"
        else
            echo "$output"
        fi
        exit 0
    fi

    # Compute stats
    local stats
    stats=$(compute_stats "$commits")

    # Raw content (summaries are written by the git-recap agent skill)
    local summary="" bullets=""
    bullets=$(raw_bullets "$commits")

    # Format output
    local output
    output=$(format_output "$commits" "$summary" "$bullets" "$stats")

    # Write or print
    if [[ -n "$ARG_OUTPUT" ]]; then
        echo "$output" > "$ARG_OUTPUT"
        info "Output written to $ARG_OUTPUT"
    else
        echo "$output"
    fi
}

main "$@"
