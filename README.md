# git-recap

Monthly commit recap generator — AI-powered summaries, bullet points, and commit lists.

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
- `claude` CLI (optional, for AI summaries)

## Usage

```
git-recap [OPTIONS] <repo>

Arguments:
  <repo>              GitHub URL, owner/repo, repo name, or local path (.)

Options:
  -u, --user <user>       GitHub username (auto-detected via gh)
  -p, --period <period>   Period: current, last, <N>, YYYY-MM (default: current)
  -m, --mode <mode>       Mode: summary, commits, bullets, all (default: all)
  -f, --format <format>   Format: text, markdown (default: text)
  -o, --output <file>     Write output to file
  -b, --branch <branch>   Branch (default: auto-detected)
  --provider <provider>   AI provider: claude, openai (default: claude)
  --init                  Initialize configuration
  -h, --help              Show this help
  -v, --version           Show version
```

## Examples

```bash
# Current month recap
git-recap maxgfr/subtool

# Last month, markdown output
git-recap -p last -f markdown -o recap.md maxgfr/subtool

# Specific month, commits only
git-recap -p 2026-01 -m commits maxgfr/subtool

# From a GitHub URL
git-recap https://github.com/maxgfr/subtool

# Local repo
git-recap .

# Also works as a git subcommand
git recap maxgfr/subtool
```

## Configuration

Run `git-recap --init` to create `~/.git-recaprc`:

```bash
GIT_RECAP_USER="maxgfr"
GIT_RECAP_PROVIDER="claude"
GIT_RECAP_FORMAT="text"
```

## License

MIT
