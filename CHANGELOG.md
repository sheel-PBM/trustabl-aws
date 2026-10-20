# Changelog

All notable changes to the Trustabl AWS plugin are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [Unreleased]

### Security

- The wrapper no longer runs a downloaded `trustabl` binary when `checksums.txt` is missing or does not match. That used to print a warning and continue.
- `VERSION` must be a single release tag. A value with `/` or `..` is rejected so the download URL stays on `trustabl/trustabl`.
- `GITHUB_TOKEN` is passed to curl through a mode-600 config file, so `DEBUG=true` does not write it into the build log.
- Scan outputs are written by rename, so a symlink in the workspace is replaced instead of followed.
- The release archive is unpacked in a private temp directory, not `.trustabl-bin` inside the project.

## [0.1.0] — 2026-06-17

### Added

- Initial release: a shared `trustabl` scanner for AWS CI/CD.
- **AWS CodePipeline** support via a CodeBuild `buildspec.yml`.
- **Amazon CodeCatalyst** support via a native workflow action.
- Downloads the upstream `trustabl` release binary (sha256-verified against the
  release `checksums.txt`), scans the source, prints a colored readiness report,
  emits `trustabl.json` + `trustabl.sarif`, and gates the build on
  `RISK_SCORE_THRESHOLD` / `SEVERITY_THRESHOLD`.
