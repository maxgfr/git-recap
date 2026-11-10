---
name: git-recap
description: Generate a work recap from git commits — a written summary plus clean bullet points, for one person or a whole team, over a period (this month, last week, a year...). Use when the user asks for a recap, standup update, weekly report, release changelog, client/activity report, or "what did I/we do" over a period on a local or GitHub repository.
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
| Custom range (sprint, billing period, "since Monday"...) | `--since YYYY-MM-DD [--until YYYY-MM-DD]` (inclusive; not combined with `-p`) |
| Specific author | `-u <user>` (auto-detected otherwise) |
| Whole team, grouped by author | `--team` |
| Leave someone out of a team recap | `--exclude-author <glob>` (repeatable, case-insensitive) |
| Branch / all branches | `-b <branch>` / `--all-branches` |
| Keep bots and release commits (skipped by default) | `--all-commits` |

For relative dates ("yesterday", "since Monday"), compute the absolute dates yourself and pass `--since`/`--until`.

Writing options come from the request, not from the CLI:

- **Language**: the user's language, or the one they ask for (default English).
- **Voice**: `neutral` by default. Use `nominal` by default for French team recaps, `I` when they want first person, `we` when they want team voice.
- **Output format**: `markdown` by default in chat, or `text` / `json` when asked.

## 3. Collect the data

Run the CLI read-only and never modify the repository. stdout is the data; stderr carries diagnostics such as the detected user, branch and period.

```bash
git-recap -f json -m all -p <period> [-u <user>] [--team] [-b <branch>|--all-branches] <repo>
```

- In single-user mode, the JSON has `repo`, `period`, `since`, `until`, `user`, `stats`, `bullets[]` (raw messages) and `commits[]`.
- In team mode, it has `global_stats` plus `contributors[]`, each with `user`, `stats`, `bullets[]` and `commits[]`.
- Each commit has `hash`, `message` (subject), `date` and `body`. For local repositories it also has `files[]` (`path`, `additions`, `deletions`), `additions` and `deletions`. Stats then include `lines_added`, `lines_deleted` and `files_changed`.
- Merge commits, bot authors (`*[bot]`, `*-bot`) and release commits (`chore(release)…`, bare version numbers) are already filtered out.
- If `commits` / `contributors` is empty, say that no commits were found for the period and stop. Never invent commits.

Use the bodies and changed files to understand **why** and **where** a change happened. Do not copy them verbatim. Terse subjects like "fix: typo" or "wip" become meaningful when read with their body and files.

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

## 5. Recap styles

Default to the standard recap (summary plus one bullet per commit, rendered as in step 6). When the request matches one of these styles, use it instead. The step 4 voice and language rules still apply, and you still never invent work.

- **Standup** ("standup", "daily", "what did I do yesterday"): default period is the previous working day (Friday on a Monday), via `--since/--until`. Output: **Yesterday**, 3–6 short bullets, grouping related commits is allowed here. Then **Today** and **Blockers**, which are left for the user to fill in unless they told you. Keep it under ~120 words.
- **Weekly report** ("weekly", "this week"): `-p current-week` or `-p last-week`. Output: a 2–3 sentence overview, then bullets grouped under **Shipped**, **Fixed**, **In progress** (wip/draft/partial commits) and **Maintenance** (chore, ci, deps, docs), plus one line of key stats (commits, active days, lines changed when available).
- **Release changelog** ("changelog", "release notes"): conventional-commit sections **Features**, **Fixes**, **Performance**, **Refactoring**, **Documentation**, **Other**. Use one bullet per user-visible change (merging duplicates is allowed here), with the commit hash in parentheses. Put **Breaking changes** first when a body contains `BREAKING CHANGE`.
- **Client / activity report** ("client report", "activity report", "compte rendu d'activité", "CRA"): non-technical language for a non-developer reader. Use themes and outcomes instead of file names or commit jargon, and leave out internal chores (ci, deps, refactors). Add the active days and the date range. Default voice is `nominal` in French and `neutral` otherwise.

## 6. Render the output

Reuse the CLI's own layout so stats tables and commit links stay identical:

- **markdown / text**: run the same command with `-f markdown` or `-f text`. In that output:
  - Insert a `## Summary` section (text: `--- Summary ---`) right after the stats section.
  - In team mode, insert `## Team Summary` (text: `--- Team Summary ---`) after the overview, and a per-contributor `### Summary` (text: `  Summary:`) before each contributor's changes.
  - Replace each raw item of the `Changes` lists with your rewritten bullet, keeping the same order and count.
- **json**: take the JSON from step 3. Add `summary` and replace `bullets` with your bullets. In team mode, add a top-level `team_summary` and a `summary` per contributor.

If the user asked for a file, write the final recap there. Otherwise show it in the reply.
