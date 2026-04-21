# Contributing

Thanks for taking the time to contribute. This is a small single-maintainer project, so the process is lightweight but the expectations are clear.

**Security vulnerabilities are NOT for issues or PRs.** Report them privately per [SECURITY.md](SECURITY.md).

## Quickstart for contributors

```bash
# 1. Fork and clone
git clone git@github.com:<your-fork>/traefik-nginx-provisioning-scripts.git
cd traefik-nginx-provisioning-scripts

# 2. Install pre-commit hooks (prevents trivial CI failures)
pip install pre-commit
pre-commit install

# 3. Work on a branch
git checkout -b feat/your-change

# 4. Make your changes; pre-commit runs on `git commit`
#    Or run on demand:
pre-commit run --all-files

# 5. Smoke test your scripts
bash -n srv/portal/bin/*.sh
./srv/portal/bin/list-sites.sh

# 6. Push and open a PR against main
```

## What gets checked automatically

Pre-commit hooks (local, configured in `.pre-commit-config.yaml`):

- **gitleaks** — refuses to commit private keys, API tokens, credentials.
- **shellcheck** — catches unquoted expansions, non-portable bash, real bugs.
- **trailing-whitespace, end-of-file-fixer, check-yaml, check-merge-conflict** — basic hygiene.
- **check-executables-have-shebangs / check-shebang-scripts-are-executable** — consistency between file mode and `#!` line.

GitHub Actions CI (`.github/workflows/ci.yml`) re-runs the same gitleaks + shellcheck checks, plus:

- **`bash -n`** across all scripts on **both** ubuntu-latest (bash 5.x) and macos-latest (bash 3.2.57). This matrix catches bash-4-only constructs — a regression vector we've hit before.

CI must be green before a PR can merge.

## Project conventions

These are not enforceable by tooling but will come up in review.

### Bash

- **`set -euo pipefail`** at the top of every executable script. Use `|| true` explicitly if a non-zero exit is genuinely OK.
- **Portable to bash 3.2.** macOS still ships bash 3.2.57. Avoid `${var,,}` (use `tr '[:upper:]' '[:lower:]'`), `${!prefix@}`, and associative-array features that aren't in 3.2.
- **Use the shared library.** `srv/portal/bin/_lib.sh` provides `log_info`/`log_ok`/`log_warn`/`log_error`/`log_skip`/`die`, `write_atomic`, `validate_fqdn`, `acquire_portal_lock`, and `nginx_reload`. Don't inline equivalents.
- **Atomic writes.** Generated files go through `write_atomic`. Don't revert to `cat > $TARGET <<EOF` — an interrupted write is worse than no write.
- **`$PORTAL_DIR` for non-script paths.** `_lib.sh` exports `PORTAL_DIR`; scripts reference it for `nginx/`, `traefik/`, compose files, logs, locks. Keep `$SCRIPT_DIR` (the `bin/` directory) for invoking sibling scripts.

### Commits

- One logical change per commit. Interactive rebase to clean up your branch before the PR if you accumulated WIP commits.
- Commit messages: short imperative title (`menu.sh: add --probe-host flag`), blank line, wrapped body explaining *why*. Bullet lists in the body are fine.
- If your change is coupled to a specific issue or prior commit, reference it in the body.

### Docs

- Every user-facing change should update at least one of: `ARCHITECTURE.md`, `SCRIPTS_GUIDE.md`, `APP_DEVELOPMENT_PROMPT.md`, `APP_MIGRATION_PROMPT.md`, or inline script comments. Docs are first-class.
- Script help text (`-h` / `--help`) is a user interface; keep it in sync with behavior.

## What I'll merge

| Change type | Expected path |
|---|---|
| Bug fix (clear test case) | Direct PR, one or two reviewers |
| New feature (backwards-compatible) | Open an issue first to confirm fit, then PR |
| Refactor | Welcome, but bundle with a functional change so the diff is motivated |
| Breaking change | Rare — open an issue before writing code |
| Docs improvement | Direct PR, low ceremony |

## What I probably won't merge

- Changes that break bash 3.2 compatibility without a strong justification.
- New runtime dependencies (Python, Node, Ruby) for the shell toolkit. This is deliberately a bash + Docker project.
- Expansions in scope: additional orchestrators (k8s, swarm, nomad), log aggregators, monitoring stacks. These are out of scope — see `ARCHITECTURE.md §13`.
- Changes that weaken the security posture (disabling read-only containers, dropping middlewares, widening CORS/CSP) without an accompanying threat-model discussion.
- Anything that removes the audit log.

## Reporting issues (non-security)

Public issues are fine for:

- Bugs with reproducible test cases.
- Documentation errors.
- Feature requests with enough context to discuss scope.

Please include:

- Your environment (OS, bash version, Docker version).
- The command you ran and the full output.
- What you expected to happen.

**Security issues:** see [SECURITY.md](SECURITY.md) for private disclosure.

## Questions

Open an issue with the `question` label, or email the maintainer directly.
