## Setup Commands
To enable a github workflow to publish collectors to your GCP project you will enable Workload Identity Federation (avoiding long lived static JSON keys).

    1 # 1. Variables (Update these for your project)
    2 export PROJECT_ID="your-project-id"
    3 export REPO="your-org/defenda-collectas" # e.g. "jeffbryner/defenda-collectas"
    4
    5 # 2. Create the Workload Identity Pool
    6 gcloud iam workload-identity-pools create "github-pool" \
    7   --project="${PROJECT_ID}" \
    8   --location="global" \
    9   --display-name="GitHub Actions Pool"
   10
   11 # 3. Create the OIDC Provider
   12 gcloud iam workload-identity-pools providers create-oidc "github-provider" \
   13   --project="${PROJECT_ID}" \
   14   --location="global" \
   15   --workload-identity-pool="github-pool" \
   16   --display-name="GitHub Actions Provider" \
   17   --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
   18   --issuer-uri="https://token.actions.githubusercontent.com"
   19
   20 # 4. Create the Service Account for Deployment
   21 gcloud iam service-accounts create "github-deployer" --project="${PROJECT_ID}"
   22
   23 # 5. Grant permissions to the Service Account (minimal example)
   24 # You'll also need roles/run.admin, roles/artifactregistry.writer, etc.
   25 gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
   26   --role="roles/editor" \
   27   --member="serviceAccount:github-deployer@${PROJECT_ID}.iam.gserviceaccount.com"
   28
   29 # 6. Allow GitHub to impersonate the Service Account
   30 PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format="value(projectNumber)")
   31
   32 gcloud iam service-accounts add-iam-policy-binding "github-deployer@${PROJECT_ID}.iam.gserviceaccount.com" \
   33   --project="${PROJECT_ID}" \
   34   --role="roles/iam.workloadIdentityUser" \
   35   --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github-pool/attribute.repository/${REPO}"
   36
   37 # 7. Get the Provider ID (Copy this into GitHub Secret 'GCP_WIF_PROVIDER')
   38 gcloud iam workload-identity-pools providers describe "github-provider" \
   39   --project="${PROJECT_ID}" \
   40   --location="global" \
   41   --workload-identity-pool="github-pool" \
   42   --format="value(name)"

  3. Final GitHub Configuration
  In your GitHub repo settings, add these three secrets:
   1. GCP_PROJECT_ID: Your Project ID.
   2. GCP_WIF_PROVIDER: The output of command #7 (e.g., projects/12345/locations/global/workloadIdentityPools/github-pool/providers/github-provider).
   3. GCP_WIF_SERVICE_ACCOUNT: github-deployer@your-project-id.iam.gserviceaccount.com.

  This setup is far more secure because it never uses a static JSON key. GitHub authenticates directly to GCP using an OIDC token that is only valid for that specific workflow run in your specific repository.

