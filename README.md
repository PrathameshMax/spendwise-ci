# spendwise-ci

The golden pipeline for every SpendWise repository. Service repositories do not
define their own build stages: their `ci.yml` and `release.yml` are short callers
of the reusable workflows here, so a new control (a scanner, a gate, a signing
step) is added once and every service picks it up on its next run.

## End to end

```
pull request ─> gates (no publish)

main ─> secret scan ┐
        CodeQL      │
        build, unit tests, coverage, SonarCloud quality gate
        integration tests (Testcontainers)
        dependency SBOM scan ┘
          └─> Dockerfile lint ─> image build ─> image scan ─> image policy ─> SBOM
                ─> push ─> sign ─> attest ─> Helm chart (lint, validate, package, push, sign)
                  └─> dev ─> sit ─(approval)─> uat                         [promote.yml]

nightly ─> DAST (OWASP ZAP) against the uat images                  [spendwise-platform]

Change Request issue (approved) ─> release.yml (manual, from main)
  ─> CR gate ─> uat artifact check ─> version + release notes (draft)
  ─(approval)─> CR gate again ─> deploy to prod ─> publish release ─> close CR
```

## Workflows

| Workflow | Used by | What it does |
|---|---|---|
| `java-service.yml` | 8 Spring Boot services, `spendwise-shared` | Gates in parallel, then the image and chart |
| `node-app.yml` | `spendwise-web` | Same for npm |
| `secret-scan.yml` | every repository | gitleaks over the commits a change introduces |
| `codeql.yml` | the two above | CodeQL SAST, `security-extended` queries |
| `container-image.yml` | the two above | Image and Helm chart stages |
| `promote.yml` | service `ci.yml` on `main` | dev → sit → uat by digest |
| `release.yml` | service `release.yml` | Change Request gate, release notes, prod |
| `self-check.yml` | this repository | actionlint, SHA-pinning rule, secret scan |

## Stages and gates

| Stage | Tool | Fails when |
|---|---|---|
| Secret detection | gitleaks 8.30.1 | Any secret in the commits being added |
| SAST | CodeQL | A finding with security-severity ≥ 7.0 |
| Build + unit tests | Maven, Surefire | Compilation or a test fails |
| Coverage | JaCoCo 0.8.14 | Line coverage below `coverage-min` |
| Code quality | SonarCloud | The quality gate fails (new-code coverage, duplication, bugs, smells, hotspots) |
| Integration tests | Surefire + Testcontainers | Any `*IT` test fails |
| SCA | CycloneDX SBOM → Trivy | A fixable HIGH/CRITICAL CVE in a shipped dependency |
| Dockerfile lint | hadolint | An error-level rule |
| Image scan | Trivy (vuln + secret) | A fixable HIGH/CRITICAL CVE, or a secret in a layer |
| Image policy | `docker inspect` | Runs as root, or no HEALTHCHECK |
| Publish, sign, attest | buildx, cosign, GitHub attestations | — (main only) |
| Helm chart | helm lint, kubeconform, Trivy config | Lint error, invalid object, HIGH/CRITICAL misconfiguration |
| Chart publish | helm push (OCI to GHCR), cosign | — (main only; image pinned by digest) |
| Promote dev, sit, uat | cosign verify, imagetools | Signature does not verify; uat approval rejected |
| DAST | OWASP ZAP (spendwise-platform, nightly) | A High risk alert (Medium optional) |
| Change Request gate | `release.yml` | CR not approved, wrong service or commit, outside the window |
| Prod | cosign verify, imagetools, GitHub Release | uat holds a different image; prod approval rejected |

## Releasing to production

1. Merge to `main`. The pipeline promotes the build to dev and sit, then waits
   for your uat approval.
2. After UAT, open **Change Request** in spendwise-platform → Issues → New issue.
   Fill in the service, the commit from the "promote to uat" summary, the
   window (UTC), the plans and the evidence (latest DAST run, SonarCloud).
3. Approve it by adding the `approved` label (reject with `rejected`).
4. In the service repository: Actions → release → Run workflow, from `main`,
   with the CR number and the version bump.
5. Approve the `prod` environment. The release is published, the image gets
   the `prod` and `vX.Y.Z` tags, and the CR is commented, labelled
   `implemented` and closed.

## Supply-chain rules

- Every third-party action is pinned to a full commit SHA (version in a comment).
  `self-check.yml` rejects a tag or branch reference. Dependabot keeps the SHAs current.
- Binaries downloaded by a `run:` step are pinned by version and SHA-256; Helm is
  installed with `checksum-policy: required`.
- Every job starts with `harden-runner` in audit mode, so outbound network calls
  are recorded for each run.
- Every job declares its own least-privilege `permissions:`; the workflow default is `{}`.

## Exceptions

| Exception | Where | Rule |
|---|---|---|
| gitleaks false positive | `.gitleaksignore` in the repository | One fingerprint per line, from the job log |
| Accepted CVE | `.trivyignore.yaml` in the repository | Must carry `expired_at` and a statement |
| ZAP rule not applicable | `.zap/rules.tsv` in spendwise-platform | Rule id, IGNORE, and the reason |

```yaml
vulnerabilities:
  - id: CVE-2026-00000
    statement: Not reachable, the vulnerable parser is never called. Risk accepted until the upstream fix ships.
    expired_at: 2027-01-31
```

An expired entry stops suppressing, so the build fails again on that date.

## Versioning

Callers use `@v1`. A change here is released by moving the `v1` tag after
`self-check` passes on `main`:

```bash
git tag -f v1 && git push -f origin v1
```

A breaking change to inputs or outputs becomes `v2`; services move one at a time.

## One-time setup

1. **SonarCloud**: sign in at sonarcloud.io with GitHub, create the organization
   `prathameshmax`, import the 10 repositories (8 services, web, shared), and in
   each project turn off Administration → Analysis Method → Automatic Analysis
   (CI analysis replaces it). Create a token under My Account → Security.
2. **Tokens**: a classic token with `read:packages` (PACKAGES_READ_TOKEN), and a
   fine-grained token for spendwise-platform only with Issues read/write
   (CHANGE_MGMT_TOKEN).
3. Run `scripts/setup-repo-governance.sh`: environments, rulesets, CR labels and
   all secrets.
