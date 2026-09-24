#!/usr/bin/env bash
# Publish a "salesforce-deployment" Infrastructure Resource record to the
# Mia-Platform Software Catalog after a successful Apex deploy, via miactl.
#
# Reference: https://docs.mia-platform.eu/docs/products/console/software-catalog/items-management/miactl
#
# Required env vars (set as masked/protected GitLab CI/CD variables):
#   MIA_CLIENT_ID       Service Account Client ID (miactl auth)
#   MIA_CLIENT_SECRET   Service Account Client Secret
#   MIA_COMPANY_ID      Mia-Platform tenant/company id
#   MIA_CONSOLE_ENDPOINT Base URL of the Console instance (e.g. https://console.<region>.mia-platform.eu)
#
# TODO before first real use: the exact key under "resources" for a
# custom-resource type item is not confirmed from the docs alone - verify
# with `miactl catalog get itd salesforce-deployment -c "$MIA_COMPANY_ID"`
# or a dry-run apply, and adjust RESOURCES_KEY below if needed.
set -euo pipefail

: "${MIA_CLIENT_ID:?Set MIA_CLIENT_ID}"
: "${MIA_CLIENT_SECRET:?Set MIA_CLIENT_SECRET}"
: "${MIA_COMPANY_ID:?Set MIA_COMPANY_ID}"
: "${MIA_CONSOLE_ENDPOINT:?Set MIA_CONSOLE_ENDPOINT}"

SF_ORG_ID="${1:?Usage: publish-catalog-record.sh <orgId> <orgInstanceUrl> <deployStatus> <classNamesCsv>}"
SF_ORG_INSTANCE_URL="${2:?}"
DEPLOY_STATUS="${3:?}"
CLASS_NAMES_CSV="${4:?}"

RESOURCES_KEY="salesforceDeployment"  # TODO: confirm against the ITD's resourceId

DEPLOYED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CLASSES_JSON=$(printf '%s' "$CLASS_NAMES_CSV" | tr ',' '\n' | jq -R . | jq -s .)

ITEM_ID="${CI_PROJECT_PATH_SLUG:-salesforce-apex}-deployment"

MANIFEST=$(jq -n \
  --arg orgId "$SF_ORG_ID" \
  --arg orgInstanceUrl "$SF_ORG_INSTANCE_URL" \
  --arg deployStatus "$DEPLOY_STATUS" \
  --arg deployedAt "$DEPLOYED_AT" \
  --argjson deployedClasses "$CLASSES_JSON" \
  --arg gitlabProjectPathWithNamespace "${CI_PROJECT_PATH:-}" \
  --arg gitlabProjectWebUrl "${CI_PROJECT_URL:-}" \
  --arg gitlabPipelineUrl "${CI_PIPELINE_URL:-}" \
  --arg gitlabCommitSha "${CI_COMMIT_SHA:-}" \
  --arg triggeredBy "${GITLAB_USER_LOGIN:-}" \
  --arg itemId "$ITEM_ID" \
  --arg tenantId "$MIA_COMPANY_ID" \
  --arg resourcesKey "$RESOURCES_KEY" \
  '{
    apiVersion: "software-catalog.mia-platform.eu/v1",
    kind: "item",
    name: $itemId,
    itemId: $itemId,
    tenantId: $tenantId,
    itemTypeDefinitionRef: { name: "salesforce-deployment", namespace: $tenantId },
    lifecycleStatus: "published",
    resources: {
      ($resourcesKey): {
        orgId: $orgId,
        orgInstanceUrl: $orgInstanceUrl,
        deployStatus: $deployStatus,
        deployedAt: $deployedAt,
        deployedClasses: $deployedClasses,
        gitlabProjectPathWithNamespace: $gitlabProjectPathWithNamespace,
        gitlabProjectWebUrl: $gitlabProjectWebUrl,
        gitlabPipelineUrl: $gitlabPipelineUrl,
        gitlabCommitSha: $gitlabCommitSha,
        triggeredBy: $triggeredBy,
        source: "gitlab-ci"
      }
    },
    version: { name: "${CI_PIPELINE_IID:-1}", releaseNote: "Published by pipeline $gitlabPipelineUrl" }
  }')

TMP_DIR="$(mktemp -d)"
echo "$MANIFEST" | jq . > "${TMP_DIR}/salesforce-deployment.json"

miactl context auth mia-ci --client-id "$MIA_CLIENT_ID" --client-secret "$MIA_CLIENT_SECRET"
miactl context set mia-ci --company-id "$MIA_COMPANY_ID" --endpoint "$MIA_CONSOLE_ENDPOINT" --auth-name mia-ci
miactl catalog apply -f "$TMP_DIR"

rm -rf "$TMP_DIR"
