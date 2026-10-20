# Trustabl on AWS CodePipeline (via CodeBuild)

1. **Vendor** this plugin into your repo: copy `scan/` and
   `codepipeline/buildspec.yml` to your repo.
2. **Create a CodeBuild project** that uses `buildspec.yml`. Image
   `aws/codebuild/standard:7.0` (has bash, curl, jq, git, tar).
3. **Add a CodeBuild action** to a Build/Test **stage** of your pipeline, with
   the source artifact as input.
4. **Configure** via environment variables on the project/action (see the root
   README inputs table), e.g. `SEVERITY_THRESHOLD=high`.

A gate failure exits non-zero -> the CodeBuild action fails -> the pipeline
stage fails. Artifacts (`trustabl.json`, `trustabl.sarif`,
`trustabl-summary.md`) are emitted to the artifact bucket.

**Optional — Security Hub:** convert findings to ASFF and
`aws securityhub batch-import-findings` to surface them in Security Hub (needs
Security Hub enabled + IAM `securityhub:BatchImportFindings`). Not in v0.1.0.

## Quickstart — from zero (console)

**You need:** an AWS account, your code in a repo AWS can read (GitHub via a
CodeStar connection, CodeCommit, or S3), and a CodePipeline (or make one).

### 1. Vendor the plugin into your repo
Copy these two into your repo, keeping the layout, then commit + push:

```
your-repo/
├── scan/trustabl-scan.sh        # the scanner
└── codepipeline/buildspec.yml   # tells CodeBuild to run it
```

### 2. Make a CodeBuild project
Console → **CodeBuild → Create build project**:
- **Environment image:** `aws/codebuild/standard:7.0` (has bash, curl, jq, git)
- **Buildspec:** "Use a buildspec file" → path `codepipeline/buildspec.yml`
- **Service role:** let CodeBuild create one (it needs CloudWatch Logs)
- *(optional)* **Env vars:** `SEVERITY_THRESHOLD`, `RISK_SCORE_THRESHOLD`,
  `VERSION` (pin a tag), `GITHUB_TOKEN` (dodges GitHub's 60-req/hr anon limit)

### 3. Add it to your pipeline
CodePipeline → your pipeline → **Edit** → add a **Build/Test** stage →
action provider **AWS CodeBuild** → pick the project → input artifact = your
Source output.

### 4. Run it (Release change)
Each run downloads the trustabl binary (sha256-verified), scans your checkout,
prints the readiness report, uploads `trustabl.json` / `trustabl.sarif` /
`trustabl-summary.md` as artifacts, and **fails the stage if any finding is
medium-or-higher** — so the pipeline stops on unsafe agent code.

> **Want report-only (don't block the pipeline)?** trustabl fails on medium+ by
> default. To make the finding gate advisory while still failing the build when
> the download or checksum check does not succeed (exit 2), change the build
> command in your buildspec to:
> `- bash "$CODEBUILD_SRC_DIR/scan/trustabl-scan.sh" || { code=$?; if [ "$code" -eq 2 ]; then exit 2; fi; }`

### CLI (alternative to steps 2–3)
After vendoring (step 1), replace `<you>/<repo>` and `<acct>`:

```bash
# one-time: a CodeBuild service role (trust + CloudWatch Logs)
aws iam create-role --role-name trustabl-codebuild \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam put-role-policy --role-name trustabl-codebuild --policy-name logs \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],"Resource":"*"}]}'

# create the project, pointing at your repo's vendored buildspec
aws codebuild create-project --name trustabl-scan \
  --source '{"type":"GITHUB","location":"https://github.com/<you>/<repo>.git","buildspec":"codepipeline/buildspec.yml"}' \
  --artifacts '{"type":"NO_ARTIFACTS"}' \
  --environment '{"type":"LINUX_CONTAINER","image":"aws/codebuild/standard:7.0","computeType":"BUILD_GENERAL1_SMALL"}' \
  --service-role arn:aws:iam::<acct>:role/trustabl-codebuild

# run a one-off scan (gate + logs). Private repos need a one-time:
#   aws codebuild import-source-credentials --token <PAT> --server-type GITHUB --auth-type PERSONAL_ACCESS_TOKEN
aws codebuild start-build --project-name trustabl-scan
```

`NO_ARTIFACTS` = scan + gate only; use `--artifacts '{"type":"S3","location":"<bucket>","name":"trustabl-results","packaging":"ZIP"}'`
to keep `trustabl.json`/`.sarif`. Wire the project into a pipeline with
`aws codepipeline create-pipeline` (or the console, step 3).

**Notes**
- Runs on Linux CodeBuild images only (the script targets Linux/macOS).
- Full input list: see the [root README](../README.md).
