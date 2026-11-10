---
name: git-recap
description: Generate a work recap from git commits — a written summary plus clean bullet points, for one person or a whole team, over a period (this month, last week, a year...). Use when the user asks for a recap, report, changelog-style summary, or "what did I/we do" over a period on a local or GitHub repository.
---

# git-recap

The `git-recap` CLI collects commits and stats deterministically and never calls an AI model. **You** write the summary and bullet points, then hand back the final recap.

## 1. Find the CLI

Use `git-recap` if it is on the `PATH`. Otherwise use the copy bundled with this skill: `bash <skill-dir>/scripts/git-recap.sh`. Requirements: `git` and `jq`, plus an authenticated `gh` for remote GitHub repositories.

## 2. Map the request to flags

| Request | Flag |
|---------|------|
| Repository (default: current directory `.`) | `<repo>`: local path, `owner/repo`, GitHub URL, SSH URL |
| Period (default `current-month`) | `-p current-month\|last-month\|current-week\|last-week\|current-year\|last-year\|all\|<N months>\|YYYY-MM\|YYYY` |
| Specific author | `-u <user>` (auto-detected otherwise) |
| Whole team, grouped by author | `--team` |
| Branch / all branches | `-b <branch>` / `--all-branches` |

Writing options come from the request, not from the CLI:

- **Language**: the user's language, or the one they ask for (default English).
- **Voice**: `neutral` by default. Use `nominal` by default for French team recaps, `I` when they want first person, `we` when they want team voice.
- **Output format**: `markdown` by default in chat, or `text` / `json` when asked.

## 3. Collect the data

Run the CLI read-only and never modify the repository. stdout is the data; stderr carries diagnostics such as the detected user, branch and period.

```bash
git-recap -f json -m all -p <period> [-u <user>] [--team] [-b <branch>|--all-branches] <repo>
```

- In single-user mode, the JSON has `repo`, `period`, `since`, `until`, `user`, `stats`, `bullets[]` (raw messages) and `commits[]` (`hash`, `message`, `date`).
- In team mode, it has `global_stats` plus `contributors[]`, each with `user`, `stats`, `bullets[]` and `commits[]`.
- If `commits` / `contributors` is empty, say that no commits were found for the period and stop. Never invent commits.

## 4. Write the content

**Summary**: 3–5 sentences suitable for a report. Synthesize by themes (features, bug fixes, refactoring, documentation, infrastructure, etc.) in a professional tone. Do not list individual commits; give a high-level overview of what was accomplished. In team mode, write one overall team summary for a project manager (major achievements, overall direction) and one summary per contributor.

**Bullet points**: rewrite the commit messages as clean, readable bullets.
- One bullet per commit, preserving the order of the commit messages.
- Do not group, merge or deduplicate entries: every commit must appear.
- Rephrase in clear, professional language.
- Remove conventional commit prefixes (`feat:`, `fix:`, `chore:`, etc.).
- No headers or categories, just the items.

**Voice**:
- `I`: first-person singular, presenting the work as the author's own accomplishments.
- `we`: first-person plural, presenting the work as team accomplishments.
- `neutral`: noun-based impersonal style. Each item starts with an action noun ("Implementation of the home page", "Optimization of build times", "Setup of CI/CD pipeline"). Never use first-person pronouns.
- `nominal`: French noun-based style ("Mise en place de la page d'accueil", "Optimisation des temps de build", "Intégration des retours designer"). Never use *je*, *nous*, *j'ai*. Keep it concise and suitable for a project status report.

## 5. Render the output

Reuse the CLI's own layout so stats tables and commit links stay identical:

- **markdown / text**: run the same command with `-f markdown` or `-f text`. In that output:
  - Insert a `## Summary` section (text: `--- Summary ---`) right after the stats section.
  - In team mode, insert `## Team Summary` (text: `--- Team Summary ---`) after the overview, and a per-contributor `### Summary` (text: `  Summary:`) before each contributor's changes.
  - Replace each raw item of the `Changes` lists with your rewritten bullet, keeping the same order and count.
- **json**: take the JSON from step 3. Add `summary` and replace `bullets` with your bullets. In team mode, add a top-level `team_summary` and a `summary` per contributor.

If the user asked for a file, write the final recap there. Otherwise show it in the reply.
