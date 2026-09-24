#!/usr/bin/env bash
# Deploy one or more Apex classes via Salesforce REST/Tooling API (no Salesforce CLI, no Metadata zip).
#
# Usage:
#   ./deploy-apex-class.sh                     # deploy every non-test class under force-app/main/default/classes
#   ./deploy-apex-class.sh MyClass              # deploy a single class
#   ./deploy-apex-class.sh MyClass OtherClass   # deploy several
#
# NOTE: the OAuth username-password flow is blocked by default on Salesforce orgs
# created after Summer '23 (Setup > OAuth and OpenID Connect Settings) and cannot
# be re-enabled by an admin. This script authenticates instead with:
#
#   1. JWT Bearer Flow (preferred) - fully headless, nothing to renew by hand.
#      Requires SF_JWT_KEY_FILE (RSA private key) + SF_USERNAME, and a Connected
#      App / External Client App with "Enable JWT Bearer Flow" turned on and the
#      matching certificate uploaded (Setup > App Manager / External Client Apps
#      > <app> > OAuth Settings). See README.md for the one-time setup.
#   2. refresh_token (fallback) - a refresh token obtained once via a browser
#      Authorization Code + PKCE flow; only used if no JWT key is configured.
#
# Prerequisites: "jq" and "openssl" installed; a Connected App with OAuth scope "api".
#
# Env vars (scripts/rest/.env is auto-loaded locally; in CI set them as
# pipeline variables instead - SF_JWT_KEY_FILE as a "File" type variable):
#   SF_LOGIN_URL        (default: https://login.salesforce.com)
#   SF_CLIENT_ID        Consumer Key
#   SF_CLIENT_SECRET    Consumer Secret (only needed for the refresh_token fallback)
#   SF_USERNAME         Salesforce USERNAME (not necessarily the email) - for JWT
#   SF_JWT_KEY_FILE     Path to the RSA private key matching the uploaded cert
#   SF_REFRESH_TOKEN    Refresh token (fallback path only)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

: "${SF_LOGIN_URL:=https://login.salesforce.com}"
: "${SF_CLIENT_ID:?Set SF_CLIENT_ID (Consumer Key)}"
: "${SF_JWT_KEY_FILE:=${SCRIPT_DIR}/server.key}"

API_VERSION="v61.0"
CLASSES_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)/force-app/main/default/classes"

if [[ $# -gt 0 ]]; then
  CLASS_NAMES=("$@")
else
  # Auto-discover: every .cls under force-app that isn't a test class.
  CLASS_NAMES=()
  for f in "$CLASSES_DIR"/*.cls; do
    base="$(basename "$f" .cls)"
    [[ "$base" == *Test ]] && continue
    grep -qi '@istest' "$f" && continue
    CLASS_NAMES+=("$base")
  done
fi

if [[ ${#CLASS_NAMES[@]} -eq 0 ]]; then
  echo "No Apex classes to deploy found in $CLASSES_DIR" >&2
  exit 1
fi

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# ---- Authenticate once, reuse the token for every class below ----
if [[ -n "${SF_USERNAME:-}" && -f "$SF_JWT_KEY_FILE" ]]; then
  echo "==> Authenticating via JWT Bearer Flow..." >&2
  JWT_HEADER=$(printf '{"alg":"RS256"}' | b64url)
  JWT_EXP=$(( $(date +%s) + 300 ))
  JWT_CLAIMS=$(printf '{"iss":"%s","sub":"%s","aud":"%s","exp":%s}' \
    "$SF_CLIENT_ID" "$SF_USERNAME" "$SF_LOGIN_URL" "$JWT_EXP" | b64url)
  JWT_SIGNING_INPUT="${JWT_HEADER}.${JWT_CLAIMS}"
  JWT_SIGNATURE=$(printf '%s' "$JWT_SIGNING_INPUT" | openssl dgst -sha256 -sign "$SF_JWT_KEY_FILE" | b64url)
  JWT="${JWT_SIGNING_INPUT}.${JWT_SIGNATURE}"

  AUTH_RESPONSE=$(curl -s "${SF_LOGIN_URL}/services/oauth2/token" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
    --data-urlencode "assertion=${JWT}")
elif [[ -n "${SF_REFRESH_TOKEN:-}" ]]; then
  : "${SF_CLIENT_SECRET:?Set SF_CLIENT_SECRET (Consumer Secret)}"
  echo "==> Refreshing access token..." >&2
  AUTH_RESPONSE=$(curl -s "${SF_LOGIN_URL}/services/oauth2/token" \
    -d "grant_type=refresh_token" \
    -d "client_id=${SF_CLIENT_ID}" \
    -d "client_secret=${SF_CLIENT_SECRET}" \
    -d "refresh_token=${SF_REFRESH_TOKEN}")
else
  echo "No auth method configured: set SF_USERNAME + SF_JWT_KEY_FILE (JWT, no browser) or SF_REFRESH_TOKEN." >&2
  exit 1
fi

ACCESS_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.access_token // empty')
INSTANCE_URL=$(echo "$AUTH_RESPONSE" | jq -r '.instance_url // empty')
NEW_REFRESH_TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.refresh_token // empty')
# The "id" field looks like https://login.salesforce.com/id/<orgId>/<userId>
ORG_ID=$(echo "$AUTH_RESPONSE" | jq -r '.id // empty' | awk -F/ '{print $(NF-1)}')

if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "Authentication failed:" >&2
  echo "$AUTH_RESPONSE" >&2
  exit 1
fi

# Refresh Token Rotation is commonly enabled on the app: every refresh invalidates
# the old refresh_token and issues a new one, so it must be persisted immediately
# (locally only - in CI, update the pipeline variable through your platform's API
# if you enable rotation there).
if [[ -n "$NEW_REFRESH_TOKEN" && "$NEW_REFRESH_TOKEN" != "${SF_REFRESH_TOKEN:-}" && -f "${SCRIPT_DIR}/.env" ]]; then
  if grep -q '^SF_REFRESH_TOKEN=' "${SCRIPT_DIR}/.env"; then
    sed -i.bak "s|^SF_REFRESH_TOKEN=.*|SF_REFRESH_TOKEN=${NEW_REFRESH_TOKEN}|" "${SCRIPT_DIR}/.env"
    rm -f "${SCRIPT_DIR}/.env.bak"
  else
    printf 'SF_REFRESH_TOKEN=%s\n' "$NEW_REFRESH_TOKEN" >> "${SCRIPT_DIR}/.env"
  fi
fi

deploy_class() {
  local CLASS_NAME="$1"
  local CLASS_FILE="${CLASSES_DIR}/${CLASS_NAME}.cls"

  echo ""
  echo "===== ${CLASS_NAME} =====" >&2

  if [[ ! -f "$CLASS_FILE" ]]; then
    echo "Class file not found: $CLASS_FILE" >&2
    return 1
  fi

  echo "==> Checking if ${CLASS_NAME} already exists..." >&2
  local QUERY_RESPONSE
  QUERY_RESPONSE=$(curl -s -G "${INSTANCE_URL}/services/data/${API_VERSION}/tooling/query" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    --data-urlencode "q=SELECT Id FROM ApexClass WHERE Name='${CLASS_NAME}'")

  local EXISTING_ID
  EXISTING_ID=$(echo "$QUERY_RESPONSE" | jq -r '.records[0].Id // empty')

  if [[ -n "$EXISTING_ID" ]]; then
    # The Tooling API rejects a direct PATCH of ApexClass.Body (compilation is
    # required), so updates go through a MetadataContainer + ApexClassMember +
    # ContainerAsyncRequest, the supported way to recompile an existing class.
    echo "==> Updating existing class (Id=${EXISTING_ID}) via MetadataContainer..." >&2

    # MetadataContainer.Name is capped at 32 chars - keep it short.
    local CONTAINER_NAME="dc_$(date +%s)_$RANDOM"
    local CONTAINER_RESPONSE CONTAINER_ID
    CONTAINER_RESPONSE=$(curl -s -X POST "${INSTANCE_URL}/services/data/${API_VERSION}/tooling/sobjects/MetadataContainer" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg name "$CONTAINER_NAME" '{Name: $name}')")
    CONTAINER_ID=$(echo "$CONTAINER_RESPONSE" | jq -r 'if type == "object" then .id // empty else empty end')

    if [[ -z "$CONTAINER_ID" ]]; then
      echo "Failed to create MetadataContainer:" >&2
      echo "$CONTAINER_RESPONSE" >&2
      return 1
    fi
    # Always delete the container when this function returns, success or not -
    # Salesforce caps the number of open MetadataContainers per user, and a
    # leftover one from a previous run is exactly what breaks the next deploy.
    trap 'curl -s -X DELETE "${INSTANCE_URL}/services/data/${API_VERSION}/tooling/sobjects/MetadataContainer/${CONTAINER_ID}" -H "Authorization: Bearer ${ACCESS_TOKEN}" >/dev/null' RETURN

    local MEMBER_BODY MEMBER_RESPONSE
    MEMBER_BODY=$(jq -n --rawfile body "$CLASS_FILE" --arg containerId "$CONTAINER_ID" --arg classId "$EXISTING_ID" \
      '{MetadataContainerId: $containerId, ContentEntityId: $classId, Body: $body}')
    MEMBER_RESPONSE=$(curl -s -X POST "${INSTANCE_URL}/services/data/${API_VERSION}/tooling/sobjects/ApexClassMember" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$MEMBER_BODY")
    if [[ "$(echo "$MEMBER_RESPONSE" | jq -r '.success // false')" != "true" ]]; then
      echo "Failed to create ApexClassMember:" >&2
      echo "$MEMBER_RESPONSE" >&2
      return 1
    fi

    local REQUEST_ID
    REQUEST_ID=$(curl -s -X POST "${INSTANCE_URL}/services/data/${API_VERSION}/tooling/sobjects/ContainerAsyncRequest" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg containerId "$CONTAINER_ID" '{MetadataContainerId: $containerId, IsCheckOnly: false}')" \
      | jq -r '.id // empty')

    if [[ -z "$REQUEST_ID" ]]; then
      echo "Failed to create ContainerAsyncRequest" >&2
      return 1
    fi

    echo "==> Waiting for compile/deploy to finish..." >&2
    local STATUS_RESPONSE STATE
    for _ in $(seq 1 30); do
      STATUS_RESPONSE=$(curl -s "${INSTANCE_URL}/services/data/${API_VERSION}/tooling/sobjects/ContainerAsyncRequest/${REQUEST_ID}" \
        -H "Authorization: Bearer ${ACCESS_TOKEN}")
      STATE=$(echo "$STATUS_RESPONSE" | jq -r '.State // empty')
      if [[ "$STATE" != "Queued" ]]; then
        echo "$STATUS_RESPONSE" | jq .
        if [[ "$STATE" != "Completed" ]]; then
          echo "Deploy failed with state: $STATE" >&2
          return 1
        fi
        break
      fi
      sleep 1
    done
  else
    echo "==> Creating new class..." >&2
    local BODY_JSON CREATE_RESPONSE
    BODY_JSON=$(jq -n --rawfile body "$CLASS_FILE" --arg name "$CLASS_NAME" '{Name: $name, Body: $body}')
    CREATE_RESPONSE=$(curl -s -w '\n%{http_code}' -X POST "${INSTANCE_URL}/services/data/${API_VERSION}/tooling/sobjects/ApexClass" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$BODY_JSON")
    echo "$CREATE_RESPONSE"
    if [[ "$(echo "$CREATE_RESPONSE" | head -n1 | jq -r '.success // false')" != "true" ]]; then
      return 1
    fi
  fi
}

FAILED=0
for CLASS_NAME in "${CLASS_NAMES[@]}"; do
  deploy_class "$CLASS_NAME" || FAILED=1
done

# Written as a dotenv file so a GitLab CI job can pass these to downstream
# jobs via `artifacts: reports: dotenv:` (e.g. to publish a Software Catalog
# record) without re-authenticating or re-parsing deploy output.
{
  echo "DEPLOY_ORG_ID=${ORG_ID}"
  echo "DEPLOY_INSTANCE_URL=${INSTANCE_URL}"
  echo "DEPLOY_STATUS=$([[ $FAILED -eq 0 ]] && echo Completed || echo Failed)"
  IFS=,; echo "DEPLOY_CLASSES=${CLASS_NAMES[*]}"; unset IFS
} > "${SCRIPT_DIR}/deploy.env"

exit $FAILED
