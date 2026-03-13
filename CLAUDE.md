# git-recap — Monthly commit recap CLI

## Project Overview

Single bash script (`git-recap`, ~1100 lines) that generates monthly commit recaps with optional AI-powered summaries and bullet points. Supports multiple AI providers.

## Architecture

- **One file**: `git-recap` — everything is in this script
- **Config**: `~/.git-recaprc` (parsed securely with regex, no `source`)
- **Tests**: `test-git-recap.sh` (unit + integration, ~80 tests)

## Key Subsystems

### AI Providers

- `claude` (default) — uses `claude` CLI, default model `haiku`
- `claude-api` — Anthropic Messages API via curl, default model `claude-haiku-4-5-20251001`, needs `ANTHROPIC_API_KEY`
- `openai` — OpenAI API via curl, default model `gpt-4o-mini`, needs `OPENAI_API_KEY`
- `mistral` — Mistral API via curl (OpenAI-compatible), default model `mistral-small-latest`, needs `MISTRAL_API_KEY`
- `gemini` — Google Gemini API via curl, default model `gemini-2.0-flash`, needs `GEMINI_API_KEY`

Shared helpers: `_call_openai_compatible()` (openai + mistral), `_call_anthropic()`, `_call_gemini()`, `_json_escape()` (jq or python3).

### Commit Sources

- Local git repo (`git log`)
- GitHub API via `gh api --paginate`
- GitHub API via `curl` with Link header pagination (fallback)

### Output Formats

- `text` — plain text with unicode bullets
- `markdown` — tables with clickable commit links
- `json` — structured output via `jq`

### Portable Date

`portable_date()` detects GNU vs BSD `date` and provides: `first_of_month`, `first_of_next_month`, `month_label`, `month_label_from`.

## CLI

- `--provider <claude|claude-api|openai|mistral|gemini>` — AI provider
- `--model <model>` — override default model per provider
- `--no-ai` — skip AI entirely, raw commit messages as bullets
- `-f <text|markdown|json>` — output format
- `-m <summary|commits|bullets|all>` — what to include
- `-p <current|last|N|YYYY-MM>` — period
- Repo: owner/repo, HTTPS URL, SSH URL, local path (`.`)

## CI/CD

- `.github/workflows/test.yml` — tests + shellcheck on macOS + Ubuntu
- `.github/workflows/release.yml` — semantic-release (bumps VERSION)
- `.releaserc` + `.version-hook.sh` — version management
- Homebrew tap auto-updated via `homebrew-tap/update-git-recap.yml`

## Conventions

- All output/logs via stderr (`>&2`), only data on stdout
- Colors: ANSI codes via `_color()`/`_reset()`, only when stderr is a TTY
- Helpers: `info()`, `warn()`, `error()`, `die()`
- Config parsed securely with regex (no `source`)
- Dependencies: `git`, `gh` or `curl`, `jq` (for json/curl), `claude` CLI (optional)
- `set -euo pipefail` — strict mode
- Trap `EXIT INT TERM HUP` for spinner cleanup

## GitHub

- Repo: `maxgfr/git-recap`
- Homebrew: `maxgfr/tap/git-recap`
