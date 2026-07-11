## Setup Commands
To enable a github workflow to publish collectors to your GCP project you will enable Workload Identity Federation (avoiding long lived static JSON keys).

```shell
 # 1. Variables (Update these for your project)
 export PROJECT_ID="your-project-id"
 export REPO="your-org/defenda-collectas" # e.g. "jeffbryner/defenda-collectas"
 export LOCATION="us-central1" # or your preferred location

 # 2. Create the Workload Identity Pool
 gcloud iam workload-identity-pools create "github-pool" \
   --project="${PROJECT_ID}" \
   --location="global" \
   --display-name="GitHub Actions Pool"

 # 3. Create the OIDC Provider
 gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --project="${PROJECT_ID}" \
  --location="global" \
  --workload-identity-pool="github-pool" \
  --display-name="GitHub Actions Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-condition="assertion.repository == '${REPO}'"

 # 4. Create the Service Account for Deployment
 gcloud iam service-accounts create "github-deployer" --project="${PROJECT_ID}"

 # Create the artifact registry repository
gcloud artifacts repositories create "collectors" \
  --repository-format=docker \
  --location="${LOCATION}" \
  --project="${PROJECT_ID}"

 # 5. Grant permissions to the Service Account

 gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
   --role="roles/editor" \
   --member="serviceAccount:github-deployer@${PROJECT_ID}.iam.gserviceaccount.com"
 # Grant other services explicitly
 gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --role="roles/artifactregistry.admin" \
    --member="serviceAccount:github-deployer@${PROJECT_ID}.iam.gserviceaccount.com"   

 gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --role="roles/run.admin" \
    --member="serviceAccount:github-deployer@${PROJECT_ID}.iam.gserviceaccount.com"   

 gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --role="roles/pubsub.admin" \
    --member="serviceAccount:github-deployer@${PROJECT_ID}.iam.gserviceaccount.com"   

 gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --role="roles/storage.objectAdmin" \
    --member="serviceAccount:github-deployer@${PROJECT_ID}.iam.gserviceaccount.com"   

 gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --role="roles/parametermanager.admin" \
    --member="serviceAccount:github-deployer@${PROJECT_ID}.iam.gserviceaccount.com"

 gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --role="roles/secretmanager.admin" \
    --member="serviceAccount:github-deployer@${PROJECT_ID}.iam.gserviceaccount.com"

 gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --role="roles/iam.serviceAccountAdmin" \
    --member="serviceAccount:github-deployer@${PROJECT_ID}.iam.gserviceaccount.com"

# parameter store has coarse permissions, can only be set at the project
# allow our github deployer to set perms
 gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --role="roles/iam.securityAdmin" \
    --member="serviceAccount:github-deployer@${PROJECT_ID}.iam.gserviceaccount.com"


 # 6. Allow GitHub to impersonate the Service Account
 PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
 
  gcloud iam service-accounts add-iam-policy-binding "github-deployer@${PROJECT_ID}.iam.gserviceaccount.com" \
   --project="${PROJECT_ID}" \
   --role="roles/iam.workloadIdentityUser" \
   --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/attribute.repository/${REPO}"

 # 7. Get the Provider ID (Copy this into GitHub Secret 'GCP_WIF_PROVIDER')
 gcloud iam workload-identity-pools providers describe "github-provider" \
   --project="${PROJECT_ID}" \
   --location="global" \
   --workload-identity-pool="github-pool" \
   --format="value(name)"

# 8. Enable optional apis (depending on the collectors you need)
# google workspace uses the admin api, parameter manager, and secret manager
 gcloud services enable admin.googleapis.com --project="${PROJECT_ID}"   
 gcloud services enable parametermanager.googleapis.com --project="${PROJECT_ID}"   
 gcloud services enable secretmanager.googleapis.com --project="${PROJECT_ID}"   

```

## GCP audit log sink (optional, recommended)

The Terraform in this repo can create a Cloud Logging sink that routes GCP
Admin Activity audit logs into the `defenda-event-ingest` topic. With an
organization ID set, the sink is org-level and aggregated (`include_children`),
covering every current and future project; with no org it falls back to a
sink on the platform project only.

Creating an org-level sink requires the deployer service account to hold
`roles/logging.configWriter` on the organization (project-level roles are not
enough):

```shell
 export ORG_ID="your-org-id" # gcloud organizations list

 gcloud organizations add-iam-policy-binding "${ORG_ID}" \
   --role="roles/logging.configWriter" \
   --member="serviceAccount:github-deployer@${PROJECT_ID}.iam.gserviceaccount.com"

 # Pre-provision the org-level Cloud Logging service agent. Org sinks write
 # as the shared agent service-org-${ORG_ID}@gcp-sa-logging.iam.gserviceaccount.com,
 # which GCP creates lazily — without this step the first terraform apply
 # fails granting pubsub.publisher with "service account does not exist".
 gcloud beta services identity create \
   --service=logging.googleapis.com \
   --organization="${ORG_ID}"
```

Note this is an org-level grant to a CI-impersonable identity: it allows
managing log sinks org-wide (it does not allow reading or deleting log
entries). Sink create/update/delete operations are themselves Admin Activity
events, so once the sink is flowing, tampering with it is visible in the
platform's own event stream.

## Data Access audit logs (optional, recommended)

**One-off, run by a human. Not terraform, not CI.**

Without this, service-account impersonation (`GenerateAccessToken`) and secret
retrieval (`AccessSecretVersion`) generate **no logs at all** — Data Access audit
logs are off by default in GCP. Every credential-access hunt then returns empty,
which looks exactly like a quiet environment. This is a *collection* gap wearing a
detection gap's costume.

```shell
 export ORG_ID="your-org-id"

 # dry run -- shows what would change, writes nothing
 python scripts/enable_data_access_logs.py --org-id "${ORG_ID}"

 # commit it
 python scripts/enable_data_access_logs.py --org-id "${ORG_ID}" --apply
```

Terraform then routes them (`route_data_access_logs`, on by default). Routing logs
that aren't being generated is harmless — the sink filter simply matches nothing
until you run the script.

### Why this one isn't in terraform

Unlike the sink grant above — which narrowly says *"can manage log sinks"* —
audit configs live **inside the org's IAM policy**. Changing them requires
`resourcemanager.organizations.setIamPolicy`, which is org-admin. There is no
narrow role. Granting that to the `terraform apply -auto-approve` deployer would
mean anyone who can land a commit, compromise a third-party Action, or poison a
workflow dependency can own the organization.

It's also the wrong capability to automate on principle: **control over audit
logging is the ability to switch off the telemetry defendA runs on.** Disabling
audit logs is a catalogued attack technique
(`stratus gcp.defense-evasion.disable-audit-logs`). A security platform should not
hand that to a push-triggered pipeline. And `google_*_iam_audit_config` is
*authoritative* — a state loss or a stray `terraform destroy` could remove audit
logging org-wide.

So Data Access logging is a **prerequisite the operator enables once**, like
enabling the Workspace Admin API for that collector. This also keeps defendA
deployable into orgs where you don't have — and shouldn't ask for — org-admin.

The script does a read-modify-write on the org IAM policy (there is no `gcloud`
command for audit configs), so it is careful about it: additive merge only, never
removes an existing service/logType/exemption, passes the `etag` back for
optimistic concurrency, and hard-aborts if role bindings differ by so much as a
byte between read and write.

### Drift is caught by detection, not by state

Since terraform isn't enforcing this, something has to notice if it gets turned
off:

```shell
 # exits non-zero if Data Access logging has drifted -- safe for cron
 python scripts/enable_data_access_logs.py --org-id "${ORG_ID}" --check
```

More to the point, the platform watches itself: `defenda_hunting.feed_coverage`
shows whether `data_access` events are actually arriving, and hunt skills declare
`requires: [gcp_data_access]` so the orchestrator **skips** a hunt whose feed is
dead rather than letting it report a false all-clear.

  ### Final GitHub Configuration
  In your GitHub repo settings, add these secrets:
   1. GCP_PROJECT_ID: Your Project ID.
   2. GCP_WIF_PROVIDER: The output of command #7 (e.g., projects/12345/locations/global/workloadIdentityPools/github-pool/providers/github-provider).
   3. GCP_WIF_SERVICE_ACCOUNT: github-deployer@your-project-id.iam.gserviceaccount.com.
   4. TF_STATE_BUCKET: the bucket name created from your defenda platform deployment
   5. GCP_ORG_ID (optional): your organization ID, enables the org-level audit log sink; leave unset for a project-level sink

  This setup is far more secure because it never uses a static JSON key. GitHub authenticates directly to GCP using an OIDC token that is only valid for that specific workflow run in your specific repository.

