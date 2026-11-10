#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# git-recap — Commit recap data generator (AI writing lives in the agent skill)
# ==============================================================================

VERSION="2.0.0"
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
    if [[ -n "$DETAILS_FILE" ]]; then
        rm -f "$DETAILS_FILE"
    fi
}
trap cleanup EXIT

# --- Portable date ---

_GNU_DATE=""
_is_gnu_date() {
    if [[ -z "$_GNU_DATE" ]]; then
        if date --version >/dev/null 2>&1; then
            _GNU_DATE=1
        else
            _GNU_DATE=0
        fi
    fi
    [[ "$_GNU_DATE" -eq 1 ]]
}

# portable_date <operation> [args...]
#   first_of_month <offset>       - First day of month, offset months from now
#   first_of_next_month           - First day of next month
#   month_label <offset>          - Human month label, offset months from now
#   month_label_from <YYYY-MM-DD> - Human month label from specific date
portable_date() {
    local op="$1"; shift
    case "$op" in
        first_of_month)
            local offset="${1:-0}"
            if _is_gnu_date; then
                if [[ "$offset" -eq 0 ]]; then
                    date -d "$(date +%Y-%m-01)" +%Y-%m-%dT00:00:00
                elif [[ "$offset" -lt 0 ]]; then
                    local abs=$(( -offset ))
                    date -d "$(date +%Y-%m-01) -${abs} month" +%Y-%m-%dT00:00:00
                else
                    date -d "$(date +%Y-%m-01) +${offset} month" +%Y-%m-%dT00:00:00
                fi
            else
                if [[ "$offset" -eq 0 ]]; then
                    LC_ALL=C date -v1d -v0H -v0M -v0S +%Y-%m-%dT%H:%M:%S
                elif [[ "$offset" -lt 0 ]]; then
                    LC_ALL=C date -v1d -v"${offset}"m -v0H -v0M -v0S +%Y-%m-%dT%H:%M:%S
                else
                    LC_ALL=C date -v1d -v+"${offset}"m -v0H -v0M -v0S +%Y-%m-%dT%H:%M:%S
                fi
            fi
            ;;
        first_of_next_month)
            if _is_gnu_date; then
                date -d "$(date +%Y-%m-01) +1 month" +%Y-%m-%dT00:00:00
            else
                LC_ALL=C date -v1d -v+1m -v0H -v0M -v0S +%Y-%m-%dT%H:%M:%S
            fi
            ;;
        month_label)
            local offset="${1:-0}"
            if _is_gnu_date; then
                if [[ "$offset" -eq 0 ]]; then
                    LC_ALL=C date +"%B %Y"
                elif [[ "$offset" -lt 0 ]]; then
                    local abs=$(( -offset ))
                    LC_ALL=C date -d "-${abs} month" +"%B %Y"
                else
                    LC_ALL=C date -d "+${offset} month" +"%B %Y"
                fi
            else
                if [[ "$offset" -eq 0 ]]; then
                    LC_ALL=C date +"%B %Y"
                else
                    LC_ALL=C date -v"${offset}"m +"%B %Y"
                fi
            fi
            ;;
        month_label_from)
            local from_date="$1"
            if _is_gnu_date; then
                LC_ALL=C date -d "$from_date" +"%B %Y"
            else
                LC_ALL=C date -jf '%Y-%m-%d' "$from_date" +"%B %Y" 2>/dev/null || echo "${from_date:0:7}"
            fi
            ;;
    esac
}

# raw_bullets <commits> → commit messages, one per line, for modes bullets/all
raw_bullets() {
    local mode="${ARG_MODE:-$DEFAULT_MODE}"
    [[ "$mode" != "bullets" && "$mode" != "all" ]] && return
    [[ -z "$1" ]] && return
    printf '%s\n' "$1" | cut -f2
}

# --- Commit details (body, changed files) for JSON output ---

# jq program turning a GitHub API commit list into TSV, merges excluded.
# Fields: hash, subject, date[, author], body (body is @tsv-escaped)
_gh_commit_jq() {
    local fields='.sha[0:7], (.commit.message | split("\n")[0]), (.commit.author.date | split("T")[0])'
    [[ "${1:-}" == "team" ]] && fields+=', (.author.login // .commit.author.name)'
    printf '.[] | select((.parents | length) < 2) | [%s, (.commit.message | split("\\n")[1:] | join("\\n"))] | @tsv' "$fields"
}

# _split_details <n> : stdin = TSV whose field n+1 is the escaped body.
# Records bodies in DETAILS_FILE and prints the first n fields.
_split_details() {
    local n="$1" raw
    raw=$(cat)
    [[ -z "$raw" ]] && return 0
    if [[ -n "$DETAILS_FILE" ]]; then
        printf '%s\n' "$raw" | jq -R -c --argjson n "$n" '
            split("\t") | {
                hash: .[0],
                body: ((.[$n] // "")
                    | gsub("\\\\(?<c>[tnr\\\\])"; if .c == "t" then "\t" elif .c == "n" then "\n" elif .c == "r" then "" else "\\" end)
                    | sub("^\\s+"; "") | sub("\\s+$"; ""))
            }' >> "$DETAILS_FILE" 2>/dev/null || true
    fi
    printf '%s\n' "$raw" | cut -f1-"$n"
}

# _collect_local_details <git log args...> : records body + numstat per commit
_collect_local_details() {
    [[ -n "$DETAILS_FILE" ]] || return 0
    git -C "$LOCAL_REPO_DIR" log "$@" --numstat --format='%x1e%h%x1f%b%x1f' 2>/dev/null | jq -R -s -c '
        split("\u001e") | .[1:][] | split("\u001f") as $p
        | {
            hash: $p[0],
            body: ($p[1] | sub("^\\s+"; "") | sub("\\s+$"; "")),
            files: [($p[2] // "") | split("\n")[] | split("\t") | select(length >= 3)
                | {path: (.[2:] | join("\t")), additions: (.[0] | tonumber? // 0), deletions: (.[1] | tonumber? // 0)}]
        }
        | .additions = ([.files[].additions] | add // 0)
        | .deletions = ([.files[].deletions] | add // 0)' >> "$DETAILS_FILE" 2>/dev/null || true
}

# _commits_json <tsv> → JSON array of commits, enriched with recorded details
_commits_json() {
    printf '%s\n' "$1" | jq -R -s --slurpfile d "${DETAILS_FILE:-/dev/null}" '
        ($d | map({key: .hash, value: del(.hash)}) | from_entries) as $m
        | split("\n") | map(select(length > 0) | split("\t") as $f
            | {hash: $f[0], message: $f[1], date: $f[2]} + ($m[$f[0]] // {}))'
}

# _change_stats_json <tsv> → {lines_added, lines_deleted, files_changed} or null
_change_stats_json() {
    printf '%s\n' "$1" | cut -f1 | jq -R -s -c --slurpfile d "${DETAILS_FILE:-/dev/null}" '
        ($d | map(select(.files != null) | {key: .hash, value: .}) | from_entries) as $m
        | [split("\n")[] | select(length > 0) | $m[.] | select(. != null)] as $c
        | if ($c | length) == 0 then null else {
            lines_added: ([$c[].additions] | add),
            lines_deleted: ([$c[].deletions] | add),
            files_changed: ([$c[].files[].path] | unique | length)
        } end'
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

_is_excluded_author() {
    local author="$1" pattern lower_author lower_pattern
    lower_author=$(printf '%s' "$author" | tr '[:upper:]' '[:lower:]')
    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue
        lower_pattern=$(printf '%s' "$pattern" | tr '[:upper:]' '[:lower:]')
        # shellcheck disable=SC2053  # glob matching is intended
        [[ "$lower_author" == $lower_pattern ]] && return 0
    done <<< "$ARG_EXCLUDE_AUTHORS"
    return 1
}

# filter_noise : stdin = commit TSV (author in field 4 when present).
# Drops bot authors, release commits and --exclude-author matches.
filter_noise() {
    local line subject author kept="" skipped=0
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        author=""
        IFS=$'\t' read -r _ subject _ author <<< "$line"
        if [[ "$ARG_ALL_COMMITS" == false ]] && { _is_release_commit "$subject" || { [[ -n "$author" ]] && _is_bot_author "$author"; }; }; then
            skipped=$((skipped + 1))
            continue
        fi
        if [[ -n "$author" && -n "$ARG_EXCLUDE_AUTHORS" ]] && _is_excluded_author "$author"; then
            skipped=$((skipped + 1))
            continue
        fi
        kept+="${line}"$'\n'
    done
    if [[ $skipped -gt 0 ]]; then
        info "Skipped $skipped bot/release/excluded commit(s) (use --all-commits to keep bots and releases)"
    fi
    printf '%s' "$kept"
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

    local d
    for d in "$ARG_SINCE" "$ARG_UNTIL"; do
        [[ -z "$d" || "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "Invalid date: $d (expected: YYYY-MM-DD)"
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

    case "$period" in
        all)
            SINCE=""
            UNTIL=""
            PERIOD_LABEL="All time"
            ;;
        current|current-month|"")
            SINCE=$(portable_date first_of_month 0)
            UNTIL=$(portable_date first_of_next_month)
            PERIOD_LABEL=$(portable_date month_label 0)
            ;;
        last|last-month)
            SINCE=$(portable_date first_of_month -1)
            UNTIL=$(portable_date first_of_month 0)
            PERIOD_LABEL=$(portable_date month_label -1)
            ;;
        current-week)
            if _is_gnu_date; then
                SINCE=$(date -d "last monday" +%Y-%m-%dT00:00:00 2>/dev/null || date -d "monday" +%Y-%m-%dT00:00:00)
                UNTIL=$(date -d "next monday" +%Y-%m-%dT00:00:00)
            else
                local dow
                dow=$(date +%u)
                local days_since_mon=$(( dow - 1 ))
                SINCE=$(LC_ALL=C date -v-"${days_since_mon}"d -v0H -v0M -v0S +%Y-%m-%dT%H:%M:%S)
                local days_until_next_mon=$(( 7 - days_since_mon ))
                UNTIL=$(LC_ALL=C date -v+"${days_until_next_mon}"d -v0H -v0M -v0S +%Y-%m-%dT%H:%M:%S)
            fi
            PERIOD_LABEL="Current week"
            ;;
        last-week)
            if _is_gnu_date; then
                UNTIL=$(date -d "last monday" +%Y-%m-%dT00:00:00 2>/dev/null || date -d "monday" +%Y-%m-%dT00:00:00)
                SINCE=$(date -d "$UNTIL -7 days" +%Y-%m-%dT00:00:00)
            else
                local dow
                dow=$(date +%u)
                local days_since_mon=$(( dow - 1 ))
                UNTIL=$(LC_ALL=C date -v-"${days_since_mon}"d -v0H -v0M -v0S +%Y-%m-%dT%H:%M:%S)
                SINCE=$(LC_ALL=C date -v-"${days_since_mon}"d -v-7d -v0H -v0M -v0S +%Y-%m-%dT%H:%M:%S)
            fi
            PERIOD_LABEL="Last week"
            ;;
        current-year)
            if _is_gnu_date; then
                SINCE=$(date -d "$(date +%Y)-01-01" +%Y-%m-%dT00:00:00)
                UNTIL=$(date -d "$(($(date +%Y) + 1))-01-01" +%Y-%m-%dT00:00:00)
            else
                local year
                year=$(date +%Y)
                SINCE="${year}-01-01T00:00:00"
                UNTIL="$((year + 1))-01-01T00:00:00"
            fi
            PERIOD_LABEL="$(date +%Y)"
            ;;
        last-year)
            if _is_gnu_date; then
                local last_y=$(( $(date +%Y) - 1 ))
                SINCE=$(date -d "${last_y}-01-01" +%Y-%m-%dT00:00:00)
                UNTIL=$(date -d "$(date +%Y)-01-01" +%Y-%m-%dT00:00:00)
            else
                local last_y=$(( $(date +%Y) - 1 ))
                SINCE="${last_y}-01-01T00:00:00"
                UNTIL="$(date +%Y)-01-01T00:00:00"
            fi
            PERIOD_LABEL="${last_y}"
            ;;
        [0-9]|[0-9][0-9])
            local n="$period"
            SINCE=$(portable_date first_of_month "-${n}")
            UNTIL=$(portable_date first_of_next_month)
            local start_label end_label
            start_label=$(portable_date month_label "-${n}")
            end_label=$(portable_date month_label 0)
            PERIOD_LABEL="${start_label} - ${end_label}"
            ;;
        [0-9][0-9][0-9][0-9]-[0-9][0-9])
            local year="${period%%-*}"
            local month="${period##*-}"
            SINCE="${year}-${month}-01T00:00:00"
            local next_month=$((10#$month + 1))
            local next_year="$year"
            if [[ $next_month -gt 12 ]]; then
                next_month=1
                next_year=$((year + 1))
            fi
            UNTIL=$(printf '%s-%02d-01T00:00:00' "$next_year" "$next_month")
            PERIOD_LABEL=$(portable_date month_label_from "${year}-${month}-01")
            ;;
        [0-9][0-9][0-9][0-9])
            SINCE="${period}-01-01T00:00:00"
            UNTIL="$((period + 1))-01-01T00:00:00"
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

    REPO_MODE="remote"

    # GitHub URL
    if [[ "$repo" == https://github.com/* ]]; then
        REPO_FULL=$(echo "$repo" | sed -E 's#^https://github\.com/##; s/\.git$//; s#/$##')
        REPO_NAME="${REPO_FULL##*/}"
        REPO_WEB_URL="https://github.com/${REPO_FULL}"
        info "Repo: $REPO_FULL"
        return
    fi

    # SSH URL
    if [[ "$repo" == git@github.com:* ]]; then
        REPO_FULL=$(echo "$repo" | sed -E 's#^git@github\.com:##; s/\.git$//')
        REPO_NAME="${REPO_FULL##*/}"
        REPO_WEB_URL="https://github.com/${REPO_FULL}"
        info "Repo: $REPO_FULL"
        return
    fi

    # owner/repo
    if [[ "$repo" == */* ]]; then
        REPO_FULL="$repo"
        REPO_NAME="${REPO_FULL##*/}"
        REPO_WEB_URL="https://github.com/${REPO_FULL}"
        info "Repo: $REPO_FULL"
        return
    fi

    # repo name only — prefix with username
    REPO_FULL="${USER_NAME}/${repo}"
    REPO_NAME="$repo"
    REPO_WEB_URL="https://github.com/${REPO_FULL}"
    info "Repo: $REPO_FULL (using user: $USER_NAME)"
}

detect_default_branch() {
    if [[ "$ARG_ALL_BRANCHES" == true ]]; then
        BRANCH="__all__"
        info "Branch: all branches"
        return
    fi

    if [[ -n "$ARG_BRANCH" ]]; then
        BRANCH="$ARG_BRANCH"
        info "Branch: $BRANCH"
        return
    fi

    if [[ "$REPO_MODE" == "local" ]]; then
        BRANCH=$(git -C "$LOCAL_REPO_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's#refs/remotes/origin/##' || true)
        [[ -z "$BRANCH" ]] && BRANCH=$(git -C "$LOCAL_REPO_DIR" branch --show-current 2>/dev/null || true)
        [[ -z "$BRANCH" ]] && BRANCH="HEAD"
    else
        BRANCH=$(gh api "repos/${REPO_FULL}" --jq '.default_branch' 2>/dev/null || echo "main")
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
        if ! command -v gh &>/dev/null && ! command -v curl &>/dev/null; then
            die "gh or curl is required for remote repos"
        fi
        check_gh_auth
    fi
}

# ==============================================================================
# Fetch commits
# ==============================================================================

# Fetch commits from all branches via gh api, deduplicate by hash
# Args: $1 = extra query params (e.g. "author=foo")
# Returns: hash\tmessage\tdate (3 fields)
_fetch_all_branches_gh() {
    local extra_params="${1:-}"
    local branches
    branches=$(gh api "repos/${REPO_FULL}/branches" --paginate --jq '.[].name' 2>/dev/null) || true
    [[ -z "$branches" ]] && return

    local all_commits="" seen_hashes=""
    while IFS= read -r branch_name; do
        [[ -z "$branch_name" ]] && continue
        local api_url="repos/${REPO_FULL}/commits?sha=${branch_name}&per_page=100"
        [[ -n "$extra_params" ]] && api_url+="&${extra_params}"
        [[ -n "$SINCE" ]] && api_url+="&since=${SINCE}Z"
        [[ -n "$UNTIL" ]] && api_url+="&until=${UNTIL}Z"
        local branch_commits
        branch_commits=$(gh api "$api_url" --paginate \
            --jq "$(_gh_commit_jq)" 2>/dev/null | _split_details 3 || true)
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local hash="${line%%	*}"
            if [[ ":${seen_hashes}:" != *":${hash}:"* ]]; then
                seen_hashes="${seen_hashes}:${hash}"
                if [[ -n "$all_commits" ]]; then
                    all_commits="${all_commits}"$'\n'"${line}"
                else
                    all_commits="$line"
                fi
            fi
        done <<< "$branch_commits"
    done <<< "$branches"
    echo "$all_commits"
}

# Fetch all commits from all branches for team mode (4 fields: hash\tmsg\tdate\tauthor)
_fetch_all_branches_gh_team() {
    local branches
    branches=$(gh api "repos/${REPO_FULL}/branches" --paginate --jq '.[].name' 2>/dev/null) || true
    [[ -z "$branches" ]] && return

    local all_commits="" seen_hashes=""
    while IFS= read -r branch_name; do
        [[ -z "$branch_name" ]] && continue
        local api_url="repos/${REPO_FULL}/commits?sha=${branch_name}&per_page=100"
        [[ -n "$SINCE" ]] && api_url+="&since=${SINCE}Z"
        [[ -n "$UNTIL" ]] && api_url+="&until=${UNTIL}Z"
        local branch_commits
        branch_commits=$(gh api "$api_url" --paginate \
            --jq "$(_gh_commit_jq team)" 2>/dev/null | _split_details 4 || true)
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local hash="${line%%	*}"
            if [[ ":${seen_hashes}:" != *":${hash}:"* ]]; then
                seen_hashes="${seen_hashes}:${hash}"
                if [[ -n "$all_commits" ]]; then
                    all_commits="${all_commits}"$'\n'"${line}"
                else
                    all_commits="$line"
                fi
            fi
        done <<< "$branch_commits"
    done <<< "$branches"
    echo "$all_commits"
}

fetch_commits() {
    local commits=""

    if [[ "$REPO_MODE" == "local" ]]; then
        info "Fetching commits (local)..."
        local dir="$LOCAL_REPO_DIR"
        local git_args=()
        if [[ "$ARG_ALL_BRANCHES" == true ]]; then
            git_args+=(--all)
        else
            git_args+=("$BRANCH")
        fi
        git_args+=(--author="$USER_NAME" --format='%h%x09%s%x09%as' --no-merges)
        [[ -n "$SINCE" ]] && git_args+=(--since="$SINCE")
        [[ -n "$UNTIL" ]] && git_args+=(--until="$UNTIL")
        commits=$(git -C "$dir" log "${git_args[@]}" 2>/dev/null || true)
        _collect_local_details "${git_args[@]}"
    elif command -v gh &>/dev/null; then
        info "Fetching commits (gh api)..."
        if [[ "$ARG_ALL_BRANCHES" == true ]]; then
            commits=$(_fetch_all_branches_gh "author=${USER_NAME}")
        else
            local api_url="repos/${REPO_FULL}/commits?sha=${BRANCH}&author=${USER_NAME}&per_page=100"
            [[ -n "$SINCE" ]] && api_url+="&since=${SINCE}Z"
            [[ -n "$UNTIL" ]] && api_url+="&until=${UNTIL}Z"
            local api_err=""
            commits=$(gh api "$api_url" --paginate \
                --jq "$(_gh_commit_jq)" 2>&1) || api_err="$commits"
            if [[ -n "$api_err" ]]; then
                case "$api_err" in
                    *"404"*) die "Repository not found: ${REPO_FULL}" ;;
                    *"403"*) die "Access denied (rate limit or permissions): ${REPO_FULL}" ;;
                    *) die "API error: ${api_err}" ;;
                esac
            fi
            commits=$(printf '%s\n' "$commits" | _split_details 3)
        fi
    elif command -v curl &>/dev/null; then
        info "Fetching commits (curl)..."
        command -v jq &>/dev/null || die "jq is required when using curl fallback"
        local url="https://api.github.com/repos/${REPO_FULL}/commits?sha=${BRANCH}&author=${USER_NAME}&per_page=100"
        [[ -n "$SINCE" ]] && url+="&since=${SINCE}Z"
        [[ -n "$UNTIL" ]] && url+="&until=${UNTIL}Z"
        local tmpheaders
        tmpheaders=$(mktemp)
        while [[ -n "$url" ]]; do
            local page_json
            page_json=$(curl -s -D "$tmpheaders" "$url")
            local page_commits
            page_commits=$(echo "$page_json" | jq -r "$(_gh_commit_jq)" 2>/dev/null | _split_details 3 || true)
            if [[ -n "$page_commits" ]]; then
                if [[ -n "$commits" ]]; then
                    commits="${commits}"$'\n'"${page_commits}"
                else
                    commits="$page_commits"
                fi
            fi
            # Parse Link header for next page
            local next_url
            next_url=$(sed -n 's/.*<\([^>]*\)>; *rel="next".*/\1/p' "$tmpheaders" | tr -d '\r') || true
            url="$next_url"
        done
        rm -f "$tmpheaders"
    else
        die "No method available to fetch commits"
    fi

    commits=$(printf '%s\n' "$commits" | filter_noise)

    if [[ -z "$commits" ]]; then
        warn "No commits found for $USER_NAME on $REPO_FULL ($PERIOD_LABEL)"
        echo ""
        return
    fi

    local count
    count=$(echo "$commits" | wc -l | tr -d ' ')
    info "Found $count commit(s)"

    echo "$commits"
}

# Returns: hash\tmessage\tdate\tauthor (4 fields)
fetch_team_commits() {
    local commits=""

    if [[ "$REPO_MODE" == "local" ]]; then
        info "Fetching all commits (local, team mode)..."
        local dir="$LOCAL_REPO_DIR"
        local git_args=()
        if [[ "$ARG_ALL_BRANCHES" == true ]]; then
            git_args+=(--all)
        else
            git_args+=("$BRANCH")
        fi
        git_args+=(--format='%h%x09%s%x09%as%x09%aN' --no-merges)
        [[ -n "$SINCE" ]] && git_args+=(--since="$SINCE")
        [[ -n "$UNTIL" ]] && git_args+=(--until="$UNTIL")
        commits=$(git -C "$dir" log "${git_args[@]}" 2>/dev/null || true)
        _collect_local_details "${git_args[@]}"
    elif command -v gh &>/dev/null; then
        info "Fetching all commits (gh api, team mode)..."
        if [[ "$ARG_ALL_BRANCHES" == true ]]; then
            commits=$(_fetch_all_branches_gh_team)
        else
            local api_url="repos/${REPO_FULL}/commits?sha=${BRANCH}&per_page=100"
            [[ -n "$SINCE" ]] && api_url+="&since=${SINCE}Z"
            [[ -n "$UNTIL" ]] && api_url+="&until=${UNTIL}Z"
            local api_err=""
            commits=$(gh api "$api_url" --paginate \
                --jq "$(_gh_commit_jq team)" 2>&1) || api_err="$commits"
            if [[ -n "$api_err" ]]; then
                case "$api_err" in
                    *"404"*) die "Repository not found: ${REPO_FULL}" ;;
                    *"403"*) die "Access denied (rate limit or permissions): ${REPO_FULL}" ;;
                    *) die "API error: ${api_err}" ;;
                esac
            fi
            commits=$(printf '%s\n' "$commits" | _split_details 4)
        fi
    elif command -v curl &>/dev/null; then
        info "Fetching all commits (curl, team mode)..."
        command -v jq &>/dev/null || die "jq is required when using curl fallback"
        local url="https://api.github.com/repos/${REPO_FULL}/commits?sha=${BRANCH}&per_page=100"
        [[ -n "$SINCE" ]] && url+="&since=${SINCE}Z"
        [[ -n "$UNTIL" ]] && url+="&until=${UNTIL}Z"
        local tmpheaders
        tmpheaders=$(mktemp)
        while [[ -n "$url" ]]; do
            local page_json
            page_json=$(curl -s -D "$tmpheaders" "$url")
            local page_commits
            page_commits=$(echo "$page_json" | jq -r "$(_gh_commit_jq team)" 2>/dev/null | _split_details 4 || true)
            if [[ -n "$page_commits" ]]; then
                if [[ -n "$commits" ]]; then
                    commits="${commits}"$'\n'"${page_commits}"
                else
                    commits="$page_commits"
                fi
            fi
            local next_url
            next_url=$(sed -n 's/.*<\([^>]*\)>; *rel="next".*/\1/p' "$tmpheaders" | tr -d '\r') || true
            url="$next_url"
        done
        rm -f "$tmpheaders"
    else
        die "No method available to fetch commits"
    fi

    commits=$(printf '%s\n' "$commits" | filter_noise)

    if [[ -z "$commits" ]]; then
        warn "No commits found on $REPO_FULL ($PERIOD_LABEL)"
        echo ""
        return
    fi

    local count
    count=$(echo "$commits" | wc -l | tr -d ' ')
    local author_count
    author_count=$(echo "$commits" | cut -f4 | sort -u | wc -l | tr -d ' ')
    info "Found $count commit(s) from $author_count contributor(s)"

    echo "$commits"
}

# ==============================================================================
# Stats
# ==============================================================================

compute_stats() {
    local commits="$1"
    [[ -z "$commits" ]] && return

    local total
    total=$(echo "$commits" | wc -l | tr -d ' ')

    local dates
    dates=$(echo "$commits" | cut -f3 | sort)
    local first_date last_date
    first_date=$(echo "$dates" | head -1)
    last_date=$(echo "$dates" | tail -1)

    # Most active day
    local busiest_line
    busiest_line=$(echo "$dates" | sort | uniq -c | sort -rn | head -1)
    local busiest_count busiest_day
    busiest_count=$(echo "$busiest_line" | awk '{print $1}')
    busiest_day=$(echo "$busiest_line" | awk '{print $2}')

    # Active days & average
    local active_days avg_per_day
    active_days=$(echo "$dates" | sort -u | wc -l | tr -d ' ')
    if [[ "$active_days" -gt 0 ]]; then
        avg_per_day=$(LANG=C LC_ALL=C awk "BEGIN {printf \"%.1f\", $total / $active_days}")
    else
        avg_per_day="0.0"
    fi

    # Busiest weekday (Tomohiko Sakamoto's algorithm, pure awk)
    local busiest_weekday
    busiest_weekday=$(echo "$dates" | awk '{
        split($0, a, "-")
        y = a[1]+0; m = a[2]+0; d = a[3]+0
        split("0 3 2 5 0 3 5 1 4 6 2 4", t, " ")
        if (m < 3) y--
        dow = (y + int(y/4) - int(y/100) + int(y/400) + t[m] + d) % 7
        counts[dow]++
    }
    END {
        split("Sunday Monday Tuesday Wednesday Thursday Friday Saturday", names, " ")
        max_val = 0; best = 0
        for (i = 0; i <= 6; i++) {
            if (counts[i]+0 > max_val) { max_val = counts[i]; best = i }
        }
        print names[best+1]
    }')

    # Longest streak (consecutive days with commits)
    local longest_streak
    longest_streak=$(echo "$dates" | sort -u | awk '{
        split($0, a, "-")
        y = a[1]+0; m = a[2]+0; d = a[3]+0
        # days since epoch (approx, good enough for consecutive check)
        jdn = d + int((153*(m + 12*int((14-m)/12) - 3)+2)/5) + 365*(y + 4800 - int((14-m)/12)) + int((y + 4800 - int((14-m)/12))/4) - int((y + 4800 - int((14-m)/12))/100) + int((y + 4800 - int((14-m)/12))/400) - 32045
        if (NR == 1) { streak = 1; max_streak = 1; prev = jdn; next }
        if (jdn == prev + 1) { streak++ } else { streak = 1 }
        if (streak > max_streak) max_streak = streak
        prev = jdn
    }
    END { print max_streak+0 }')

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s' "$total" "$first_date" "$last_date" "$busiest_day" "$busiest_count" "$active_days" "$avg_per_day" "$busiest_weekday" "$longest_streak"
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
            echo "$bullets" | while IFS= read -r line; do
                [[ -n "$line" ]] && echo "- ${line}"
            done
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
                echo "| ${date} | ${commit_ref} | ${msg} |"
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
            echo "$bullets" | while IFS= read -r line; do
                [[ -n "$line" ]] && printf '  • %s\n' "$line"
            done
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
    local summary="$2"
    local mode="$3"
    local bullets="$4"
    local stats="$5"

    local total first_date last_date busiest_day busiest_count active_days avg_per_day busiest_weekday longest_streak
    if [[ -n "$stats" ]]; then
        IFS='|' read -r total first_date last_date busiest_day busiest_count active_days avg_per_day busiest_weekday longest_streak <<< "$stats"
    else
        total=0 first_date="" last_date="" busiest_day="" busiest_count=0 active_days=0 avg_per_day="0.0" busiest_weekday="" longest_streak=0
    fi

    local json
    json=$(jq -n \
        --arg repo "$REPO_FULL" \
        --arg repo_name "$REPO_NAME" \
        --arg period "$PERIOD_LABEL" \
        --arg since "$SINCE" \
        --arg until "$UNTIL" \
        --arg user "$USER_NAME" \
        --argjson total "${total:-0}" \
        --arg first_date "${first_date:-}" \
        --arg last_date "${last_date:-}" \
        --arg busiest_day "${busiest_day:-}" \
        --argjson busiest_count "${busiest_count:-0}" \
        --argjson active_days "${active_days:-0}" \
        --argjson avg_per_day "${avg_per_day:-0.0}" \
        --arg busiest_weekday "${busiest_weekday:-}" \
        --argjson longest_streak "${longest_streak:-0}" \
        '{
            repo: $repo,
            repo_name: $repo_name,
            period: $period,
            since: $since,
            until: $until,
            user: $user,
            stats: {
                total_commits: $total,
                active_days: $active_days,
                avg_per_day: $avg_per_day,
                longest_streak: $longest_streak,
                first_date: $first_date,
                last_date: $last_date,
                busiest_day: $busiest_day,
                busiest_day_commits: $busiest_count,
                busiest_weekday: $busiest_weekday
            }
        }')

    if [[ -n "$commits" ]]; then
        json=$(echo "$json" | jq --argjson ch "$(_change_stats_json "$commits")" 'if $ch then .stats += $ch else . end')
    fi

    if [[ ("$mode" == "summary" || "$mode" == "all") && -n "$summary" ]]; then
        json=$(echo "$json" | jq --arg s "$summary" '. + {summary: $s}')
    fi

    if [[ ("$mode" == "bullets" || "$mode" == "all") && -n "$bullets" ]]; then
        local bullets_arr
        bullets_arr=$(echo "$bullets" | jq -R -s 'split("\n") | map(select(length > 0))')
        json=$(echo "$json" | jq --argjson b "$bullets_arr" '. + {bullets: $b}')
    fi

    if [[ ("$mode" == "commits" || "$mode" == "all") && -n "$commits" ]]; then
        local commits_arr
        commits_arr=$(_commits_json "$commits")
        json=$(echo "$json" | jq --argjson c "$commits_arr" '. + {commits: $c}')
    fi

    echo "$json"
}

# ==============================================================================
# Team mode output
# ==============================================================================

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
        ac=$(echo "$all_commits" | awk -F'\t' -v a="$author" '$4==a' | cut -f1-3)
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
                echo "$ac_bullets" | while IFS= read -r line; do
                    [[ -n "$line" ]] && printf '    • %s\n' "$line"
                done
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
        echo "| ${rank} | ${author} | ${cnt} | ${pct}% |"
        rank=$((rank + 1))
    done
    echo ""

    # Per-author sections
    while IFS= read -r author; do
        [[ -z "$author" ]] && continue
        local ac
        ac=$(echo "$all_commits" | awk -F'\t' -v a="$author" '$4==a' | cut -f1-3)
        local ac_count
        ac_count=$(echo "$ac" | wc -l | tr -d ' ')

        echo "## ${author} (${ac_count} commits)"
        echo ""

        # Per-author stats
        local ac_stats
        ac_stats=$(compute_stats "$ac")
        local a_total a_first a_last a_busiest_day a_busiest_count a_active_days a_avg a_weekday a_streak
        IFS='|' read -r a_total a_first a_last a_busiest_day a_busiest_count a_active_days a_avg a_weekday a_streak <<< "$ac_stats"
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
                echo "$ac_bullets" | while IFS= read -r line; do
                    [[ -n "$line" ]] && echo "- ${line}"
                done
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
                    echo "| ${date} | ${commit_ref} | ${msg} |"
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

    local global_3f
    global_3f=$(echo "$all_commits" | cut -f1-3)
    local global_stats
    global_stats=$(compute_stats "$global_3f")
    local total first_date last_date busiest_day busiest_count active_days avg_per_day busiest_weekday longest_streak
    IFS='|' read -r total first_date last_date busiest_day busiest_count active_days avg_per_day busiest_weekday longest_streak <<< "$global_stats"

    local authors
    authors=$(echo "$all_commits" | cut -f4 | sort | uniq -c | sort -rn | sed -E 's/^ *[0-9]+ //')
    local num_authors
    num_authors=$(echo "$authors" | wc -l | tr -d ' ')

    local json
    json=$(jq -n \
        --arg repo "$REPO_FULL" \
        --arg repo_name "$REPO_NAME" \
        --arg period "$PERIOD_LABEL" \
        --arg since "$SINCE" \
        --arg until "$UNTIL" \
        --arg branch "$branch_label" \
        --argjson total "${total:-0}" \
        --argjson num_authors "$num_authors" \
        --argjson active_days "${active_days:-0}" \
        --argjson avg_per_day "${avg_per_day:-0.0}" \
        --argjson longest_streak "${longest_streak:-0}" \
        --arg first_date "${first_date:-}" \
        --arg last_date "${last_date:-}" \
        --arg busiest_day "${busiest_day:-}" \
        --argjson busiest_count "${busiest_count:-0}" \
        --arg busiest_weekday "${busiest_weekday:-}" \
        '{
            repo: $repo,
            repo_name: $repo_name,
            period: $period,
            since: $since,
            until: $until,
            branch: $branch,
            team: true,
            global_stats: {
                total_commits: $total,
                contributors: $num_authors,
                active_days: $active_days,
                avg_per_day: $avg_per_day,
                longest_streak: $longest_streak,
                first_date: $first_date,
                last_date: $last_date,
                busiest_day: $busiest_day,
                busiest_day_commits: $busiest_count,
                busiest_weekday: $busiest_weekday
            },
            contributors: []
        }')
    json=$(echo "$json" | jq --argjson ch "$(_change_stats_json "$global_3f")" 'if $ch then .global_stats += $ch else . end')

    while IFS= read -r author; do
        [[ -z "$author" ]] && continue
        local ac
        ac=$(echo "$all_commits" | awk -F'\t' -v a="$author" '$4==a' | cut -f1-3)
        local ac_stats
        ac_stats=$(compute_stats "$ac")
        local a_total a_first a_last a_busiest_day a_busiest_count a_active_days a_avg a_weekday a_streak
        IFS='|' read -r a_total a_first a_last a_busiest_day a_busiest_count a_active_days a_avg a_weekday a_streak <<< "$ac_stats"

        # Raw content (summaries are written by the git-recap agent skill)
        local ac_summary="" ac_bullets=""
        USER_NAME="$author"
        ac_bullets=$(raw_bullets "$ac")

        local contributor_json
        contributor_json=$(jq -n \
            --arg user "$author" \
            --argjson total "${a_total:-0}" \
            --argjson active_days "${a_active_days:-0}" \
            --argjson avg_per_day "${a_avg:-0.0}" \
            --argjson longest_streak "${a_streak:-0}" \
            --arg first_date "${a_first:-}" \
            --arg last_date "${a_last:-}" \
            --arg busiest_day "${a_busiest_day:-}" \
            --argjson busiest_count "${a_busiest_count:-0}" \
            --arg busiest_weekday "${a_weekday:-}" \
            '{
                user: $user,
                stats: {
                    total_commits: $total,
                    active_days: $active_days,
                    avg_per_day: $avg_per_day,
                    longest_streak: $longest_streak,
                    first_date: $first_date,
                    last_date: $last_date,
                    busiest_day: $busiest_day,
                    busiest_day_commits: $busiest_count,
                    busiest_weekday: $busiest_weekday
                }
            }')

        contributor_json=$(echo "$contributor_json" | jq --argjson ch "$(_change_stats_json "$ac")" 'if $ch then .stats += $ch else . end')

        if [[ ("$mode" == "summary" || "$mode" == "all") && -n "$ac_summary" ]]; then
            contributor_json=$(echo "$contributor_json" | jq --arg s "$ac_summary" '. + {summary: $s}')
        fi

        if [[ ("$mode" == "bullets" || "$mode" == "all") && -n "$ac_bullets" ]]; then
            local bullets_arr
            bullets_arr=$(echo "$ac_bullets" | jq -R -s 'split("\n") | map(select(length > 0))')
            contributor_json=$(echo "$contributor_json" | jq --argjson b "$bullets_arr" '. + {bullets: $b}')
        fi

        if [[ ("$mode" == "commits" || "$mode" == "all") && -n "$ac" ]]; then
            local commits_arr
            commits_arr=$(_commits_json "$ac")
            contributor_json=$(echo "$contributor_json" | jq --argjson c "$commits_arr" '. + {commits: $c}')
        fi

        json=$(echo "$json" | jq --argjson c "$contributor_json" '.contributors += [$c]')
    done <<< "$authors"

    echo "$json"
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

    validate_args

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

    # Resolve format from config if not set via CLI
    if [[ -z "$ARG_FORMAT" && -n "${GIT_RECAP_FORMAT:-}" ]]; then
        ARG_FORMAT="$GIT_RECAP_FORMAT"
    fi

    # Resolve repo
    resolve_repo

    # Check deps
    check_dependencies

    # Detect branch
    detect_default_branch

    # Compute period
    compute_period

    # JSON output carries commit bodies (and changed files for local repos)
    if [[ "${ARG_FORMAT:-$DEFAULT_FORMAT}" == "json" ]]; then
        DETAILS_FILE=$(mktemp)
    fi

    # === Team mode ===
    if [[ "$ARG_TEAM" == true ]]; then
        local all_commits
        all_commits=$(fetch_team_commits)

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
