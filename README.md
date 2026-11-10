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
  --team                  Team mode: all contributors, grouped by author
  --all-branches          Fetch commits from all branches
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
| `<N>` | Last N months |
| `YYYY-MM` | Specific month (e.g., `2026-01`) |
| `YYYY` | Specific year (e.g., `2025`) |

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
  Total commits: 34
  First commit:  2026-03-06
  Last commit:   2026-03-13
  Busiest day:   2026-03-08 (14 commits)

--- Changes ---
  • fix: translate text-only

--- Commits ---
  7354b0c - fix: translate text-only (2026-03-13)
  ...
```

### Markdown

Stats table, bullet list, and commit table. Hashes link to GitHub when the repository has a GitHub remote.

### JSON

Structured output with `repo`, `period`, `since`, `until`, `stats`, `bullets[]` and `commits[]` fields. In team mode, it has `global_stats` and `contributors[]`. This is what the agent skill reads. It adds `summary` (and `team_summary`) and rewrites `bullets`.

With the skill, the agent inserts a Summary section and rewritten bullets into these same layouts.

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
