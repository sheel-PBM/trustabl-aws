# Security

## Reporting a vulnerability

This repository is a thin AWS wrapper around the Trustabl scanner. Report a
problem in this fork to its maintainer. Please do not open a public issue that
includes a live token, a working exploit, or customer data.

The scanner binary itself is published from the upstream Trustabl release. A
defect in that binary belongs with that project, not with this wrapper.

## Audit of 20 October 2026

Reviewed commit `76d5a39` on `main` (this fork's default branch), plus every
commit reachable from this fork's branches, for secrets.

### Tools that actually ran

| Tool | Result |
|---|---|
| Claude Security | Not run. The Claude Code CLI is not installed here, and the plugin requires a Claude account. No login was attempted. |
| Codex Security (`@openai/codex-security` 0.5.0) | Installed. `cs scan` stopped with "No credentials were found." No login was attempted. |
| Cloudflare security-audit skill | The `npx skills` installer was not used. The skill was read from its repository and its six phases were followed, including a separate pass that tried to refute each candidate. |
| Google Mantis | Not run. The harness needs a Google Cloud login and a model backend. That is more setup than this environment can finish without an account. |
| ShellCheck 0.9.0 | Ran on `scan/trustabl-scan.sh`. |
| gitleaks 8.28.0 | Ran across all 44 commits on this fork. No leaks. |
| `npm audit` / `pip-audit` | Nothing to audit. This repo has no `package.json`, lockfile, or Python requirements. |

There is no web app here, so the usual checks for Supabase row-level security,
service-role keys in a browser, IDOR, CORS, security headers, signup rate
limits, XSS, SQL injection, Stripe webhook signatures, and file-upload handling
do not apply. There is no LLM call in this repo.

### Findings

Confirmed on the code that was on `main`, with a local stub in place of the
network. An independent recheck agreed with these.

**Medium — a missing checksum still ran the binary.** If `checksums.txt` could
not be downloaded, the wrapper printed a warning and ran whatever it had just
downloaded. A person who can tamper with that download, or publish a release
asset without a checksum file, gets code execution inside the build. A checksum
that does not match already stopped the run. What was missing was the "file not
there" path.

**Medium — `DEBUG=true` printed `GITHUB_TOKEN`.** The wrapper turned on shell
tracing before calling curl, and curl was given `Authorization: Bearer <token>`
as an argument. The build log then contained the token. Anyone who can read the
log and who was not supposed to see the secret can use it as a GitHub
credential. `DEBUG=false` did not print it.

**Medium — scan outputs followed symlinks.** The default files (`trustabl.json`,
`trustabl.sarif`, `trustabl.env`, `trustabl-summary.md`) are created in the
working directory. If one of those names is a symlink, the shell follows it and
overwrites the target. A repository being scanned can commit that symlink. The
next build replaces whatever it points at (for example a credential file the
build user can write) with the scan report.

**Low — `.trustabl-bin` was taken from the workspace.** The download directory
lived inside the project. If that path was a symlink, the archive and the
extracted binary were written into the other directory. This does not by itself
overwrite an arbitrary filename. It does drop the scanner binary into a
directory chosen by the tree being scanned.

**Low — a hostile `VERSION` changed the request path, and then curl refused to
save the body.** `VERSION=../../../../some/other/release/...` makes curl
normalize the URL onto a different GitHub path. The same string is used as the
local filename, so curl exits 23 ("could not open the output file") and the
binary is not executed. The build still sends the request. A normal tag such as
`v0.1.14` is unaffected. Git tags cannot contain `..`, so the default
`VERSION=latest` path is not a way to do this. Setting `VERSION` is.

### Checked and not confirmed

- **Secrets in the tree or in git history.** gitleaks found none. Nothing needs
  rotating.
- **Git hooks while labeling the branch.** `core.fsmonitor` did not run for the
  `rev-parse`, `show-ref`, and `config --get` commands this wrapper uses. The
  same setting does run for `git status`.
- **`git -C` option injection.** A `TARGET` starting with `-` is treated as a
  path, not as a git option.
- **Tar path traversal on this system's GNU tar 1.35.** Members containing `..`
  make tar exit with an error, and the wrapper already had `set -e` around
  extract. The wrapper now rejects those members itself, before extract, so it
  does not depend on the tar version.
- **A pre-seeded `trustabl` binary in the workspace** is overwritten when the
  real archive contains `trustabl` (the published `v0.1.14` archive does). It
  was executed only when the archive had no such file. The binary is now taken
  from a private temp directory and invoked by path.

### What this change fixes

- Refuse to run the binary unless `checksums.txt` lists it and the sha256
  matches. Failure is exit 2 (setup failed), not exit 1 (findings gate).
- Accept only a single release tag in `VERSION` (`v0.1.14`, `0.1.14`,
  `v1.2.3-rc.1`). `/` and `..` are rejected before any download.
- Pass `GITHUB_TOKEN` through a mode-600 curl config file so tracing does not
  print it. Tokens with whitespace, quotes, or backslashes are rejected.
- Write outputs by rename, so a symlink is replaced instead of followed.
- Unpack the release in a private temp directory and run that `trustabl` by
  path.
- The report-only recipe in the CodePipeline and CodeCatalyst docs no longer
  uses `|| true`, which also hid download and checksum failures. Exit 2 still
  fails the build. Exit 1 (a finding gate) stays advisory in that recipe.

### What is left, and why

- Customer pipelines that already copied the old `|| true` recipe will keep
  hiding setup failures until they update that one command. The behavior of a
  normal (gating) run does not depend on the doc change.
- Claude Security, Codex Security, and Mantis did not scan the tree. They need
  accounts this environment does not have. The manual review above is the
  substitute.
- No key was rotated, no git history was rewritten, and nothing outside this
  repository was changed.
