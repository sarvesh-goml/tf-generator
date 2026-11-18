# GoNinja Quality Gates

**Principle: fast by default, strict where it matters.** We block on new problems and fixable risk.
Existing debt and unfixable CVEs are reported and tracked, but they do not stop delivery.

## What blocks a merge or a release

| Where | Check | Blocks when | Time budget |
|---|---|---|---|
| Commit | Ruff lint + format | Lint error that can't be auto-fixed | < 2 s |
| Commit | Gitleaks | Any secret in staged lines | < 1 s |
| Commit | Hygiene hooks | Merge markers, keys, files > 500 KB, broken YAML/JSON | < 1 s |
| Push | Semgrep | Any finding from `p/python` | < 30 s |
| PR | Hooks re-run | Anything above (catches `--no-verify`) | ~1 min |
| PR | Gitleaks | Secret in any commit of the PR | < 1 min |
| PR | Semgrep | New findings vs. base branch | ~2 min |
| PR | pip-audit | Known vulnerable dependency | < 1 min |
| PR | SonarQube | Quality gate fails on new code | ~5 min |
| PR | hadolint + Trivy config | Dockerfile warning, High/Critical misconfig | ~1 min |
| PR | Trivy image | High/Critical CVE **with a fix available** | ~3 min |
| Release | Cosign verify | Image not signed by this repo's pipeline | < 1 min |
| Staging | ZAP baseline | Rules marked FAIL in `.zap/rules.tsv` | ~3 min |
| Staging | Schemathesis | API returns a 5xx | ~3 min |
| Production | Manual approval | Reviewer has not approved | — |
| Nightly | Full gitleaks, pip-audit, Trivy on `:main`, ZAP full scan | Report only; failure notifies owners | — |

## SonarQube quality gate (new code only)

- 0 new bugs and 0 new vulnerabilities
- All new security hotspots reviewed
- Coverage on new code ≥ 70% (raise to 80% after one quarter)
- Duplication on new code ≤ 3%
- Maintainability rating on new code: A

## Suppressing a finding

Suppressions are allowed. Silent suppressions are not.

- Inline: `# noqa: S603  reason: input is a constant list` or `# nosemgrep: rule-id  reason: ...`
- CVEs: one line in `.trivyignore` with **reason, owner, expiry date**
- Every suppression file is covered by CODEOWNERS and needs DevOps review
- Bypassing hooks with `--no-verify` is allowed for emergencies. CI still runs everything.

## Fix SLAs for reported (non-blocking) findings

| Severity | Fix within |
|---|---|
| Critical | 7 days |
| High | 30 days |
| Medium | Next planned sprint |
| Low | Best effort |

## How we measure success (reported monthly)

- Issues on new code per PR (SonarQube): should fall
- Quality gate first-time pass rate: should rise
- Median PR CI time: must stay under 10 minutes
- Secrets caught before push vs. after push
- Open High/Critical CVEs in production images
