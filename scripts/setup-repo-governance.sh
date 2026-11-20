#!/usr/bin/env bash
#
# One-time GitHub settings the golden pipeline relies on, applied to every
# SpendWise repository with the gh CLI (Git Bash on Windows works):
#
#   - environments dev, sit (automatic), uat (your approval) and prod (your
#     approval, main only) in every deployable repository
#   - a "main protection" ruleset everywhere: pull request required, linear
#     history, no force push, no deletion, CodeQL high-or-higher blocks merge
#   - Change Request labels in spendwise-platform
#   - secrets: PACKAGES_READ_TOKEN, SONAR_TOKEN, CHANGE_MGMT_TOKEN, each set for
#     Actions and, where Dependabot pull requests need it, for Dependabot
#
# The three token values are read from the terminal (not echoed) and never
# written to disk. Re-running is safe: everything is upserted.
#
# Usage:  gh auth login
#         ./scripts/setup-repo-governance.sh
set -euo pipefail

OWNER=PrathameshMax
CR_REPO=spendwise-platform

JAVA_SERVICES=(
  spendwise-discovery-server
  spendwise-config-server
  spendwise-api-gateway
  spendwise-user-service
  spendwise-transaction-service
  spendwise-budget-service
  spendwise-notification-service
  spendwise-analytics-service
)
DEPLOYABLE=("${JAVA_SERVICES[@]}" spendwise-web)
ALL=("${DEPLOYABLE[@]}" spendwise-shared spendwise-config spendwise-platform spendwise-ci)

read -rsp "PACKAGES_READ_TOKEN (classic, read:packages): " PACKAGES_READ_TOKEN; echo
read -rsp "SONAR_TOKEN (sonarcloud.io > My Account > Security): " SONAR_TOKEN; echo
read -rsp "CHANGE_MGMT_TOKEN (fine-grained, ${CR_REPO} only, Issues: read and write): " CHANGE_MGMT_TOKEN; echo

REVIEWER_ID=$(gh api user --jq .id)
echo "Approver for uat and prod: $(gh api user --jq .login) (id ${REVIEWER_ID})"

set_secret() {
  local repo=$1 app=$2 name=$3 value=$4
  gh secret set "$name" --app "$app" --repo "${OWNER}/${repo}" --body "$value"
  echo "  secret ${name} (${app})"
}

upsert_environment() {
  local repo=$1 env=$2 body=$3
  gh api --method PUT "repos/${OWNER}/${repo}/environments/${env}" --input - <<< "$body" > /dev/null
  echo "  environment ${env}"
}

main_only_policy() {
  local repo=$1 env=$2
  local existing
  existing=$(gh api "repos/${OWNER}/${repo}/environments/${env}/deployment-branch-policies" \
               --jq '.branch_policies[] | select(.name == "main") | .id')
  if [ -z "$existing" ]; then
    gh api --method POST "repos/${OWNER}/${repo}/environments/${env}/deployment-branch-policies" \
      -f name=main -f type=branch > /dev/null
  fi
}

upsert_label() {
  local name=$1 color=$2 description=$3
  gh label create "$name" --repo "${OWNER}/${CR_REPO}" --color "$color" --description "$description" --force > /dev/null
  echo "  label ${name}"
}

apply_ruleset() {
  local repo=$1
  local id body
  id=$(gh api "repos/${OWNER}/${repo}/rulesets" --jq '.[] | select(.name == "main protection") | .id')
  body=$(cat <<'JSON'
{
  "name": "main protection",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    { "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true
      } },
    { "type": "code_scanning",
      "parameters": {
        "code_scanning_tools": [
          { "tool": "CodeQL", "security_alerts_threshold": "high_or_higher", "alerts_threshold": "errors" }
        ]
      } }
  ]
}
JSON
)
  if [ -n "$id" ]; then
    gh api --method PUT "repos/${OWNER}/${repo}/rulesets/${id}" --input - <<< "$body" > /dev/null
  else
    gh api --method POST "repos/${OWNER}/${repo}/rulesets" --input - <<< "$body" > /dev/null
  fi
  echo "  ruleset main protection"
}

APPROVAL="{\"reviewers\":[{\"type\":\"User\",\"id\":${REVIEWER_ID}}],\"prevent_self_review\":false}"
PROD="{\"reviewers\":[{\"type\":\"User\",\"id\":${REVIEWER_ID}}],\"prevent_self_review\":false,\"deployment_branch_policy\":{\"protected_branches\":false,\"custom_branch_policies\":true}}"

for repo in "${DEPLOYABLE[@]}"; do
  echo "${repo}"
  upsert_environment "$repo" dev '{}'
  upsert_environment "$repo" sit '{}'
  upsert_environment "$repo" uat "$APPROVAL"
  upsert_environment "$repo" prod "$PROD"
  main_only_policy "$repo" prod
  set_secret "$repo" actions SONAR_TOKEN "$SONAR_TOKEN"
  set_secret "$repo" dependabot SONAR_TOKEN "$SONAR_TOKEN"
  set_secret "$repo" actions CHANGE_MGMT_TOKEN "$CHANGE_MGMT_TOKEN"
done

for repo in "${JAVA_SERVICES[@]}"; do
  echo "${repo}"
  set_secret "$repo" actions PACKAGES_READ_TOKEN "$PACKAGES_READ_TOKEN"
  set_secret "$repo" dependabot PACKAGES_READ_TOKEN "$PACKAGES_READ_TOKEN"
done

echo spendwise-shared
set_secret spendwise-shared actions SONAR_TOKEN "$SONAR_TOKEN"
set_secret spendwise-shared dependabot SONAR_TOKEN "$SONAR_TOKEN"

echo "${CR_REPO}"
set_secret "$CR_REPO" actions PACKAGES_READ_TOKEN "$PACKAGES_READ_TOKEN"
upsert_label change-request 1D76DB "Change Request for a production release"
upsert_label approved 0E8A16 "Change approved (CAB); the release workflow may run"
upsert_label rejected B60205 "Change rejected"
upsert_label implemented 5319E7 "Released to production"
upsert_label failed D93F0B "Production release did not complete"
upsert_label dast B60205 "DAST findings"

for repo in "${ALL[@]}"; do
  echo "${repo}"
  apply_ruleset "$repo"
done

cat <<'NOTE'

Done. After the first pipeline run on a pull request, add the required status
checks to each "main protection" ruleset (Settings > Rules > Rulesets > main
protection > Require status checks to pass). The check names appear in the
picker once they have run, e.g. for a Java service:

  pipeline / secret-scan / gitleaks
  pipeline / sast / codeql (java-kotlin)
  pipeline / build, unit tests, coverage, quality gate
  pipeline / integration tests
  pipeline / dependency SBOM and vulnerability scan
  pipeline / container / build, scan, sign
  pipeline / container / helm chart
NOTE
