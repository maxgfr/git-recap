# git-recap

Commit recap generator: stats, bullet points and commit lists from git history, with AI-written summaries through an agent skill.

- **CLI** (`git-recap`): deterministic data such as commits, stats, raw bullets in text, markdown or JSON. It never calls an AI model.
- **Agent skill** (`skills/git-recap`): your coding agent (Claude Code, Codex, Cursor, …) runs the CLI, then writes the summary and bullet points with its own model and renders the final recap.

## Installation

### Agent skill

```bash
npx skills add maxgfr/git-recap
```

The skill bundles its own copy of the CLI, so no other install is needed. Then ask your agent:

- "Recap my commits this month on this repo"
- "Team recap of maxgfr/subtool for last month, in French, as markdown in recap.md"
- "What did I ship in 2025? First person."
- "Standup for yesterday" / "Weekly report" / "Release changelog for last month" / "Client activity report for January"

The skill knows four ready-made styles: standup, weekly report, release changelog and client/activity report. It also uses commit bodies and changed files to write better summaries than commit subjects alone allow.

Language (`en`, `fr`, …) and voice (`I`, `we`, `neutral` such as "Implementation of…", or `nominal` such as "Mise en place de…") come from your request.

### CLI: Homebrew

```bash
brew install maxgfr/tap/git-recap
```

### CLI: manual

```bash
curl -fsSL https://raw.githubusercontent.com/maxgfr/git-recap/main/script.sh -o /usr/local/bin/git-recap
chmod +x /usr/local/bin/git-recap
```

## Requirements

- `git`
- `gh` (GitHub CLI, authenticated, for remote GitHub repositories)
- `jq` (required for `-f json` and `curl` fallback)

Without `gh`, remote repositories are read through `curl` and the public GitHub API. Set `GH_TOKEN` (or `GITHUB_TOKEN`) to raise the rate limit from 60 to 5000 requests an hour and to read private repositories.

## Usage

```
git-recap [OPTIONS] <repo>

Arguments:
  <repo>              GitHub URL, owner/repo, repo name, SSH URL, or local path (.)

Options:
  -u, --user <user>       GitHub username (auto-detected via gh)
  -p, --period <period>   Period (default: current-month). Values:
                           current-month, last-month, current-week, last-week,
                           current-year, last-year, all, <N>, YYYY-MM, YYYY
  -m, --mode <mode>       Mode: summary, commits, bullets, all (default: all)
                          (bullets are raw commit messages; summaries come from the skill)
  -f, --format <format>   Format: text, markdown, json (default: text)
  -o, --output <file>     Write output to file
  -b, --branch <branch>   Branch (default: auto-detected)
  --since <YYYY-MM-DD>    Start date (inclusive), instead of -p
  --until <YYYY-MM-DD>    End date (inclusive), instead of -p
  --team                  Team mode: all contributors, grouped by author
  --all-branches          Fetch commits from all branches
  --exclude-author <glob> Skip matching authors in team mode (repeatable, case-insensitive)
  --all-commits           Keep bot authors and release commits (skipped by default)
  --init                  Initialize configuration
  -h, --help              Show this help
  -v, --version           Show version
```

### Periods

| Period | Description |
|--------|-------------|
| `current-month` | Current month (default) |
| `last-month` | Previous month |
| `current-week` | Current week (Monday to Sunday) |
| `last-week` | Previous week |
| `current-year` | Current year |
| `last-year` | Previous year |
| `all` | All commits ever |
| `<N>` | The current month and the N previous months (`-p 3` in November: August to November) |
| `YYYY-MM` | Specific month (e.g., `2026-01`) |
| `YYYY` | Specific year (e.g., `2025`) |

For any other range, use `--since` and/or `--until` (inclusive dates), e.g. `--since 2026-01-05 --until 2026-01-16` for a sprint.

Weeks run Monday to Sunday. Invalid periods and dates (`-p 2026-13`, `--since 2025-02-30`) are rejected before anything is fetched.

### Filtering

Merge commits, bot authors (`*[bot]`, `*-bot`, such as `dependabot[bot]` or `semantic-release-bot`) and release commits (`chore(release): …`, bare version numbers) are skipped by default. The number of skipped commits is reported on stderr. Use `--all-commits` to keep them, and `--exclude-author "<name or glob>"` to leave specific people out of a team recap (a literal name such as `dependabot[bot]` works too).

For local repositories, `-u` is matched against author names and emails as a plain substring; for GitHub repositories it is a GitHub login or email. `--all-branches` reads local branches, remote-tracking branches and tags (not the stash).

### Team Mode

Generate a recap for all contributors, grouped by author:

```bash
# Team recap on default branch
git-recap --team maxgfr/subtool

# Team recap, all branches, markdown output
git-recap --team --all-branches -f markdown -o recap.md maxgfr/subtool

# Team recap on a specific branch
git-recap --team -b develop maxgfr/subtool
```

## Examples

```bash
# Current month recap
git-recap maxgfr/subtool

# Last month, markdown output
git-recap -p last-month -f markdown -o recap.md maxgfr/subtool

# Current week recap
git-recap -p current-week maxgfr/subtool

# All commits ever
git-recap -p all maxgfr/subtool

# Full year 2025
git-recap -p 2025 maxgfr/subtool

# Custom date range
git-recap --since 2026-01-05 --until 2026-01-16 .

# Specific month, commits only
git-recap -p 2026-01 -m commits maxgfr/subtool

# JSON output
git-recap -f json -m commits maxgfr/subtool | jq .

# Team mode
git-recap --team maxgfr/subtool

# From various URL formats
git-recap https://github.com/maxgfr/subtool
git-recap git@github.com:maxgfr/subtool.git

# Local repo
git-recap .

# Also works as a git subcommand
git recap maxgfr/subtool
```

## Output Formats

### Text (default)

```
=== Monthly Recap - subtool - March 2026 ===

--- Stats ---

  Total commits:   34
  Active days:     6
  Avg per day:     5.7
  Longest streak:  4 day(s)
  First commit:    2026-03-06
  Last commit:     2026-03-13
  Busiest day:     2026-03-08 (14 commits)
  Busiest weekday: Sunday

--- Changes ---

  • fix: translate text-only
  ...

--- Commits ---

  2026-03-13
    7354b0c  fix: translate text-only
  ...
```

### Markdown

Stats table, bullet list, and commit table. Hashes link to GitHub when the repository has a GitHub remote. A `|` inside a table cell is written as `\|`.

### JSON

Structured output with `repo`, `period`, `since`, `until`, `stats`, `bullets[]` and `commits[]` fields. In team mode, it has `global_stats` and `contributors[]`.

Each commit has `hash`, `message`, `date` and `body`. For local repositories, it also has `files[]` (`path`, `additions`, `deletions`) with `additions`/`deletions` totals, and stats gain `lines_added`, `lines_deleted` and `files_changed`. This is what the agent skill reads. It adds `summary` (and `team_summary`) and rewrites `bullets`.

With the skill, the agent inserts a Summary section and rewritten bullets into these same layouts.

## Errors

A missing repository or branch, a rate limit, an authentication problem or a failing `git log` stops git-recap with a message on stderr and exit code 1. "No commits found" (exit 0) only means that the period really has no matching commits.

## Configuration

Run `git-recap --init` to create `~/.git-recaprc`:

```bash
GIT_RECAP_USER="maxgfr"
GIT_RECAP_FORMAT="text"
```

## Migrating from 1.x

git-recap 2.0 removes the built-in AI providers. `--provider`, `--model`, `--lang` and `--voice` now exit with an error, and `--no-ai` is accepted but does nothing. Install the agent skill (`npx skills add maxgfr/git-recap`) and ask your agent for the recap instead. Legacy `GIT_RECAP_PROVIDER/MODEL/LANG/VOICE` lines in `~/.git-recaprc` are ignored.

## License

MIT
