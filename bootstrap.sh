#!/usr/bin/env bash

## Terraform doesn't exist on corp laptops, which leads to the circular dependency
## you need a workstation to run Terraform, but you need Terraform to set up the workstation.

set -e -u -o pipefail

CONFIG_FILE="gcp"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "Error: Configuration file '$CONFIG_FILE' not found."
    echo "Please create it and add your PROJECT_ID."
    exit 1
fi

# --- Validate Configuration ---
if [[ -z "${PROJECT_ID:-}" ]]; then
    echo "Error: PROJECT_ID is not set in '$CONFIG_FILE'."
    echo "Please add 'PROJECT_ID=\"your-gcp-project-id\"' to the file."
    exit 1
fi

# ===================================================================
#          CONFIGURATION
# ===================================================================
REGION="europe-north1"
NETWORK_NAME="ws-net-${REGION}"
ROUTER_NAME="ws-router-${REGION}"
NAT_NAME="ws-nat-${REGION}"
CLUSTER_NAME="cluster"
REPO_NAME="workstation-image"
WORKSTATION_SA_NAME="workstation-sa"
BUILD_SA_NAME="cloud-build-sa"
WORKSTATION_CONFIG_NAME="base-config"
MACHINE_TYPE="e2-standard-8"
POOL_SIZE=1
CONTAINER_IMAGE_NAME="workstation-image"
CONTAINER_IMAGE_TAG="latest"
WORKSTATION_NAME="my-workstation"

# ===================================================================
#          DERIVED VARIABLES
# ===================================================================
WORKSTATION_SA_EMAIL="${WORKSTATION_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
BUILD_SA_EMAIL="${BUILD_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
SOURCE_BUCKET_NAME="${PROJECT_ID}-cloudbuild-sources"
LOGS_BUCKET_NAME="${PROJECT_ID}-cloudbuild-logs"
FULL_IMAGE_PATH="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPO_NAME}/${CONTAINER_IMAGE_NAME}:${CONTAINER_IMAGE_TAG}"

# ===================================================================
#                      HELPER FUNCTIONS
# ===================================================================
enable_apis() {
    echo "--- Enabling required APIs ---"
    gcloud services enable \
        compute.googleapis.com \
        artifactregistry.googleapis.com \
        workstations.googleapis.com \
        cloudbuild.googleapis.com \
        iam.googleapis.com \
        storage.googleapis.com \
        aiplatform.googleapis.com \
        --project="$PROJECT_ID"
}

create_service_accounts() {
    echo "--- Ensuring service accounts exist ---"
    if ! gcloud iam service-accounts describe "$WORKSTATION_SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
        gcloud iam service-accounts create "$WORKSTATION_SA_NAME" --display-name="Service Account for Cloud Workstations" --project="$PROJECT_ID"
    else
        echo "Workstation SA '$WORKSTATION_SA_NAME' already exists."
    fi

    if ! gcloud iam service-accounts describe "$BUILD_SA_EMAIL" --project="$PROJECT_ID" &>/dev/null; then
        gcloud iam service-accounts create "$BUILD_SA_NAME" --display-name="Dedicated Service Account for Cloud Build" --project="$PROJECT_ID"
    else
        echo "Build SA '$BUILD_SA_NAME' already exists."
    fi
}

create_buckets() {
    echo "--- Ensuring Cloud Storage buckets exist ---"
    if ! gcloud storage buckets describe "gs://${SOURCE_BUCKET_NAME}" --project="$PROJECT_ID" &>/dev/null; then
        gcloud storage buckets create "gs://${SOURCE_BUCKET_NAME}" --location="$REGION" --project="$PROJECT_ID"
    else
        echo "Source bucket 'gs://${SOURCE_BUCKET_NAME}' already exists."
    fi

    if ! gcloud storage buckets describe "gs://${LOGS_BUCKET_NAME}" --project="$PROJECT_ID" &>/dev/null; then
        gcloud storage buckets create "gs://${LOGS_BUCKET_NAME}" --location="$REGION" --project="$PROJECT_ID"
    else
        echo "Logs bucket 'gs://${LOGS_BUCKET_NAME}' already exists."
    fi
}

create_repository() {
     echo "--- Ensuring Artifact Registry exists ---"
    if ! gcloud artifacts repositories describe "$REPO_NAME" --location="$REGION" --project="$PROJECT_ID" &>/dev/null; then
        gcloud artifacts repositories create "$REPO_NAME" --repository-format=docker --location="$REGION" --description="Workstation image repository" --project="$PROJECT_ID"
    else
        echo "Artifact Registry repo '$REPO_NAME' already exists."
    fi
}

setup_iam() {
    echo "--- Applying IAM policies ---"

    echo "Applying Artifact Registry policies..."
    gcloud artifacts repositories add-iam-policy-binding "$REPO_NAME" --location="$REGION" --member="serviceAccount:$WORKSTATION_SA_EMAIL" --role="roles/artifactregistry.reader" --project="$PROJECT_ID"
    gcloud artifacts repositories add-iam-policy-binding "$REPO_NAME" --location="$REGION" --member="serviceAccount:$BUILD_SA_EMAIL" --role="roles/artifactregistry.writer" --project="$PROJECT_ID"

    echo "Applying Cloud Storage policies..."
    gcloud storage buckets add-iam-policy-binding "gs://${SOURCE_BUCKET_NAME}" --member="serviceAccount:$BUILD_SA_EMAIL" --role="roles/storage.objectUser" --project="$PROJECT_ID"
    gcloud storage buckets add-iam-policy-binding "gs://${LOGS_BUCKET_NAME}" --member="serviceAccount:$BUILD_SA_EMAIL" --role="roles/storage.admin" --project="$PROJECT_ID"

    echo "Applying Project-level policies..."
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$BUILD_SA_EMAIL" --role="roles/logging.logWriter"
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$BUILD_SA_EMAIL" --role="roles/workstations.admin"
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$WORKSTATION_SA_EMAIL" --role="roles/aiplatform.user"
}

create_networking() {
    echo "--- Ensuring networking resources exist ---"
    # Network
    if ! gcloud compute networks describe "$NETWORK_NAME" --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute networks create "$NETWORK_NAME" --subnet-mode=auto --mtu=1460 --bgp-routing-mode=regional --project="$PROJECT_ID"
    else
        echo "Network '$NETWORK_NAME' already exists."
    fi
    # Firewall
    if ! gcloud compute firewall-rules describe "allow-ssh-ingress-from-iap" --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute firewall-rules create "allow-ssh-ingress-from-iap" --direction=INGRESS --priority=1000 --network="$NETWORK_NAME" --action=ALLOW --rules=tcp:22 --source-ranges=35.235.240.0/20 --project="$PROJECT_ID"
    else
        echo "Firewall rule 'allow-ssh-ingress-from-iap' already exists."
    fi
    # Router
    if ! gcloud compute routers describe "$ROUTER_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute routers create "$ROUTER_NAME" --region="$REGION" --network="$NETWORK_NAME" --project="$PROJECT_ID"
    else
        echo "Router '$ROUTER_NAME' already exists."
    fi
    # NAT
    if ! gcloud compute routers nats describe "$NAT_NAME" --router="$ROUTER_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
        gcloud compute routers nats create "$NAT_NAME" --router="$ROUTER_NAME" --region="$REGION" --auto-allocate-nat-external-ips --nat-all-subnet-ip-ranges --project="$PROJECT_ID"
    else
        echo "NAT '$NAT_NAME' already exists."
    fi
}

submit_build() {
    echo "--- Building container image: $FULL_IMAGE_PATH ---"
    gcloud builds submit . \
        --region="$REGION" \
        --tag "$FULL_IMAGE_PATH" \
        --service-account="projects/${PROJECT_ID}/serviceAccounts/$BUILD_SA_EMAIL" \
        --gcs-source-staging-dir="gs://${SOURCE_BUCKET_NAME}/source" \
        --gcs-log-dir="gs://${LOGS_BUCKET_NAME}/logs" \
        --project="$PROJECT_ID"
}

create_workstation_resources() {
    echo "--- Ensuring workstation resources exist ---"

    # Cluster
    if ! gcloud workstations clusters describe "$CLUSTER_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
        gcloud workstations clusters create "$CLUSTER_NAME" \
            --region="$REGION" \
            --network="projects/$PROJECT_ID/global/networks/$NETWORK_NAME" \
            --subnetwork="projects/$PROJECT_ID/regions/$REGION/subnetworks/$NETWORK_NAME" \
            --project="$PROJECT_ID"
    else
        echo "Workstation cluster '$CLUSTER_NAME' already exists."
    fi

    # Configuration
    if ! gcloud workstations configs describe "$WORKSTATION_CONFIG_NAME" --cluster="$CLUSTER_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
        gcloud workstations configs create "$WORKSTATION_CONFIG_NAME" \
            --cluster="$CLUSTER_NAME" \
            --region="$REGION" \
            --machine-type="$MACHINE_TYPE" \
            --pool-size="$POOL_SIZE" \
            --shielded-secure-boot \
            --shielded-vtpm \
            --shielded-integrity-monitoring \
            --container-custom-image="$FULL_IMAGE_PATH" \
            --service-account="$WORKSTATION_SA_EMAIL" \
            --service-account-scopes=https://www.googleapis.com/auth/cloud-platform \
            --disable-public-ip-addresses \
            --project="$PROJECT_ID"
    else
        echo "Workstation config '$WORKSTATION_CONFIG_NAME' already exists."
    fi

    # Workstation Instance
    if ! gcloud workstations describe "$WORKSTATION_NAME" --config="$WORKSTATION_CONFIG_NAME" --cluster="$CLUSTER_NAME" --region="$REGION" --project="$PROJECT_ID" &>/dev/null; then
        gcloud workstations create "$WORKSTATION_NAME" --config="$WORKSTATION_CONFIG_NAME" --cluster="$CLUSTER_NAME" --region="$REGION" --project="$PROJECT_ID"
    else
        echo "Workstation instance '$WORKSTATION_NAME' already exists."
    fi
}

# ===================================================================
#                      MAIN EXECUTION
# ===================================================================
main() {
    # Check for required tools
    if ! command -v gcloud &> /dev/null; then
        echo "gcloud command could not be found. Please install the Google Cloud SDK."
        exit 1
    fi

    enable_apis
    create_service_accounts
    create_buckets
    create_repository
    setup_iam
    create_networking
    submit_build
    create_workstation_resources

    echo "--- Script finished successfully! ---"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
