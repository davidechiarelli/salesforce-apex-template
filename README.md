# Salesforce Apex Template

SFDX project skeleton with a headless deploy pipeline (REST/Tooling API, no Salesforce CLI)
for a GitLab repo. Deploys automatically on push to the default branch.

## Contents

- `force-app/main/default/classes/` - your Apex classes and tests
- `scripts/rest/deploy-apex-class.sh` - deploys every non-test class via the Tooling API,
  authenticating with the JWT Bearer Flow (no browser, no password)
- `.gitlab-ci.yml` - runs the deploy script on every push to the default branch

## One-time setup per Salesforce org

Username-password OAuth is blocked by default on orgs created after Summer '23 and cannot
be re-enabled, so this template uses the JWT Bearer Flow instead.

1. Generate a key pair (keep `server.key` secret, never commit it):
   ```bash
   openssl req -x509 -sha256 -nodes -newkey rsa:2048 \
     -keyout server.key -out server.crt -days 3650 \
     -subj "/CN=<project name> Deploy/O=Your Org"
   ```
2. In Salesforce Setup, create a Connected App / External Client App:
   - Enable OAuth, scope `api`
   - Enable the **JWT Bearer Flow** and upload `server.crt` as its certificate
3. Find your Salesforce **Username** (Setup > Users - it is often *not* the same as
   the login email).
4. Set these as **masked/protected** CI/CD variables on the GitLab project
   (Settings > CI/CD > Variables):
   - `SF_CLIENT_ID` - the Connected App's Consumer Key
   - `SF_USERNAME` - the Salesforce Username from step 3
   - `SF_JWT_KEY_FILE` - variable type **File**, content = `server.key`

## Local development

```bash
cp scripts/rest/.env.example scripts/rest/.env
# fill in SF_CLIENT_ID, SF_USERNAME, and point SF_JWT_KEY_FILE at your server.key
./scripts/rest/deploy-apex-class.sh                 # deploy every class
./scripts/rest/deploy-apex-class.sh MyClass          # deploy a single class
```

## Software Catalog tracking (optional second stage)

After a successful deploy, `publish-catalog-record.sh` upserts a `salesforce-deployment`
Infrastructure Resource item in the Mia-Platform Software Catalog via `miactl catalog apply`,
so the deployment is visible/traceable there too. See `catalog/salesforce-deployment-itd.json`
for the Item Type Definition (publish it once, manually, before the pipeline can use it).

Console instance: `https://demo.console.gcp.mia-platform.eu/`, tenant: **Experiments**
(`b933f1ef-5b8e-4adf-a346-24a3b03d13e8`) - both already set as defaults in `.gitlab-ci.yml`.

The `salesforce-deployer` Service Account already exists in that tenant (role: `developer`,
`client_secret_basic`). Grab its Client ID/Secret from Company > IAM > Service Accounts and
set them as **masked/protected** CI/CD variables:
- `MIA_CLIENT_ID` / `MIA_CLIENT_SECRET` - credentials of `salesforce-deployer`

> Note: the SA has the `developer` company role. That should cover writing catalog items,
> but if `miactl catalog apply` fails with a permission error, check whether a more specific
> catalog-write role is needed and adjust the SA's role in Console.

Also, before the pipeline can use it: publish `catalog/salesforce-deployment-itd.json`
**once**, manually, to the Experiments tenant (Software Catalog UI, or `miactl catalog apply`
from your own machine) - the pipeline only creates/updates *items* of that type, not the type
itself.
