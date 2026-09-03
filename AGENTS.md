# Repository guide

## Working agreement

- Keep `script.sh` portable across the Bash versions used by macOS and Ubuntu CI.
- Treat stdout as generated recap data; send diagnostics and progress to stderr.
- Parse configuration as data. Preserve the existing rule that `~/.git-recaprc` is never sourced.
- Keep CLI providers read-only and non-interactive. Codex calls use `codex exec --ephemeral` with a read-only sandbox.

## Verification

- Run `bash -n script.sh test-git-recap.sh` after shell changes.
- Run `shellcheck script.sh test-git-recap.sh` before committing.
- Run `bash test-git-recap.sh`; new behavior and bug fixes require a regression test through the CLI when possible.
- Keep remote/API-dependent tests tolerant of unavailable credentials, while local repository and provider-adapter tests remain deterministic.

## Release

- Use Conventional Commit subjects. `feat:` releases a minor version and `fix:` releases a patch through semantic-release on `main`.
- Leave version changes to `.version-hook.sh` and the release workflow.
