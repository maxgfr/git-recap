# git-recap

Commit recap generator — AI-powered summaries, bullet points, and commit lists.

Supports multiple AI providers: **Claude** (CLI & API), **OpenAI**, **Mistral**, **Gemini**.

## Installation

### Homebrew

```bash
brew install maxgfr/tap/git-recap
```

### Manual

```bash
curl -fsSL https://raw.githubusercontent.com/maxgfr/git-recap/main/git-recap -o /usr/local/bin/git-recap
chmod +x /usr/local/bin/git-recap
```

## Requirements

- `git`
- `gh` (GitHub CLI, authenticated)
- One of the AI providers (optional):
  - `claude` CLI for Claude (default)
  - `ANTHROPIC_API_KEY` env var for Claude API (without CLI)
  - `OPENAI_API_KEY` env var for OpenAI/ChatGPT
  - `MISTRAL_API_KEY` env var for Mistral
  - `GEMINI_API_KEY` env var for Gemini
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
  -f, --format <format>   Format: text, markdown, json (default: text)
  -o, --output <file>     Write output to file
  -b, --branch <branch>   Branch (default: auto-detected)
  --provider <provider>   AI provider: claude, claude-api, openai, mistral, gemini (default: claude)
  --model <model>         AI model override (see defaults below)
  --lang <lang>           Language for AI output: en, fr, es, de, ... (default: en)
  --voice <voice>         Narrative voice: I or we (default: I)
  --no-ai                 Skip AI generation (summary/bullets)
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

### AI Providers & Default Models

| Provider | Flag | Default Model | Requires |
|----------|------|---------------|----------|
| Claude (CLI) | `--provider claude` | `haiku` | `claude` CLI |
| Claude (API) | `--provider claude-api` | `claude-haiku-4-5-20251001` | `ANTHROPIC_API_KEY` |
| OpenAI | `--provider openai` | `gpt-4o-mini` | `OPENAI_API_KEY` |
| Mistral | `--provider mistral` | `mistral-small-latest` | `MISTRAL_API_KEY` |
| Gemini | `--provider gemini` | `gemini-2.0-flash` | `GEMINI_API_KEY` |

Override the model with `--model`:

```bash
git-recap --provider claude --model sonnet maxgfr/subtool
git-recap --provider claude-api --model claude-sonnet-4-6 maxgfr/subtool
git-recap --provider openai --model gpt-4o maxgfr/subtool
git-recap --provider gemini --model gemini-1.5-pro maxgfr/subtool
```

### Language & Voice

Control the language and narrative voice of AI-generated content:

```bash
# French output, first person
git-recap --lang fr maxgfr/subtool

# English, team voice ("we implemented...", "we fixed...")
git-recap --lang en --voice we maxgfr/subtool

# French, first person singular ("j'ai implémenté...", "j'ai corrigé...")
git-recap --lang fr --voice I maxgfr/subtool
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

# Use Claude API (without CLI)
git-recap --provider claude-api maxgfr/subtool

# Use Mistral AI
git-recap --provider mistral maxgfr/subtool

# Use Gemini with a specific model
git-recap --provider gemini --model gemini-1.5-pro maxgfr/subtool

# JSON output
git-recap -f json -m commits maxgfr/subtool | jq .

# No AI, just raw data
git-recap --no-ai -m all maxgfr/subtool

# French recap, first person
git-recap --lang fr --voice I maxgfr/subtool

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

--- Summary ---
[AI-generated summary]

--- Changes ---
  * [AI-generated bullet points]

--- Commits ---
  7354b0c - fix: translate text-only (2026-03-13)
  ...
```

### Markdown

Stats table, AI summary, bullet list, and commit table with clickable hashes linking to GitHub.

### JSON

Structured output with `repo`, `period`, `stats`, `summary`, `bullets[]`, and `commits[]` fields.

## Configuration

Run `git-recap --init` to create `~/.git-recaprc`:

```bash
GIT_RECAP_USER="maxgfr"
GIT_RECAP_PROVIDER="claude"
GIT_RECAP_MODEL=""
GIT_RECAP_FORMAT="text"
GIT_RECAP_LANG="en"
GIT_RECAP_VOICE="I"
```

## License

MIT
