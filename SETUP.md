## Setup Commands
To enable a github workflow to publish collectors to your GCP project you will enable Workload Identity Federation (avoiding long lived static JSON keys).

```shell
 # 1. Variables (Update these for your project)
 export PROJECT_ID="your-project-id"
 export REPO="your-org/defenda-collectas" # e.g. "jeffbryner/defenda-collectas"

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

 # 5. Grant permissions to the Service Account

 gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
   --role="roles/editor" \
   --member="serviceAccount:github-deployer@${PROJECT_ID}.iam.gserviceaccount.com"
# 2. Grant the Artifact Registry Writer role explicitly
 gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --role="roles/artifactregistry.writer" \
    --member="serviceAccount:github-deployer@${PROJECT_ID}.iam.gserviceaccount.com"   

 gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --role="roles/run.admin" \
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

```

  ### Final GitHub Configuration
  In your GitHub repo settings, add these three secrets:
   1. GCP_PROJECT_ID: Your Project ID.
   2. GCP_WIF_PROVIDER: The output of command #7 (e.g., projects/12345/locations/global/workloadIdentityPools/github-pool/providers/github-provider).
   3. GCP_WIF_SERVICE_ACCOUNT: github-deployer@your-project-id.iam.gserviceaccount.com.

  This setup is far more secure because it never uses a static JSON key. GitHub authenticates directly to GCP using an OIDC token that is only valid for that specific workflow run in your specific repository.

