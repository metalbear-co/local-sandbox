# Testing Spanner branching against a real Spanner instance

The emulator path (`task spanner:deploy` + `task spanner:run:local`) needs no GCP
account. This guide is for branching a **real** Cloud Spanner database: the
operator copies its schema (and rows, for `copy.mode: all`) into a local emulator
branch, authenticating as the same Google identity the app uses.

This reuses the same GCP credential detection Postgres and MySQL use for Cloud SQL.
The operator reads the consumer pod's identity and gives it to the branch sidecar.
There are two ways the pod can carry that identity, so pick the section that matches
where you run:

- **Workload Identity (GKE)** - the pod runs as a Kubernetes SA bound to a Google
  SA; the branch inherits it and needs no key file. This is the default
  `spanner:real:deploy`.
- **Key file (local minikube)** - there is no metadata server, so the pod mounts a
  downloaded SA key and `GOOGLE_APPLICATION_CREDENTIALS` points at it. Use
  `spanner:real:deploy:key`.

Do step 1 either way, then do step 2a (GKE) or step 2b (minikube).

## 1. Create the Spanner instance and database

```bash
export PROJECT_ID=your-gcp-project
gcloud config set project "$PROJECT_ID"
gcloud services enable spanner.googleapis.com

# A 100-processing-unit regional instance is the smallest billable unit and is
# plenty for a test. Delete it when you are done (step 5) to avoid charges.
gcloud spanner instances create test-branch-instance \
  --config=regional-us-central1 \
  --description="mirrord spanner branch test" \
  --processing-units=100

gcloud spanner databases create test-branch-db \
  --instance=test-branch-instance \
  --ddl="CREATE TABLE Users (Id INT64 NOT NULL, Name STRING(MAX)) PRIMARY KEY (Id); CREATE TABLE Orders (Id INT64 NOT NULL, UserId INT64, Total INT64) PRIMARY KEY (Id)"
```

Seed a few rows so `copy.mode: all` has something to copy:

```bash
for row in "Id=1,Name=alice" "Id=2,Name=bob" "Id=3,Name=carol"; do
  gcloud spanner rows insert --instance=test-branch-instance --database=test-branch-db \
    --table=Users --data="$row"
done
gcloud spanner rows insert --instance=test-branch-instance --database=test-branch-db \
  --table=Orders --data="Id=10,UserId=1,Total=500"
gcloud spanner rows insert --instance=test-branch-instance --database=test-branch-db \
  --table=Orders --data="Id=11,UserId=2,Total=250"
```

The copy only reads the source, so in both options below the Google service
account needs just `roles/spanner.databaseReader` (which covers `getDdl`,
`read`/`select` and `sessions.create`).

## 2a. GKE: bind a Workload Identity SA (no key file)

Create the Google SA, grant it read access, then bind it to the Kubernetes SA the
consumer pod runs as (`spanner-branch-sa` in the `test-mirrord` namespace by
default):

```bash
gcloud iam service-accounts create spanner-branch-test \
  --display-name="mirrord spanner branch test"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:spanner-branch-test@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/spanner.databaseReader"

# Let the Kubernetes SA impersonate the Google SA via Workload Identity.
gcloud iam service-accounts add-iam-policy-binding \
  "spanner-branch-test@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[test-mirrord/spanner-branch-sa]"
```

Then deploy. Point `kubectl` at the GKE cluster first and make sure the operator is
running there. `GCP_SA` tells the task to create and annotate the Kubernetes SA for
you (omit it if the SA already exists on the cluster):

```bash
task spanner:real:deploy \
  REAL_PROJECT="$PROJECT_ID" \
  REAL_INSTANCE=test-branch-instance \
  REAL_DATABASE=test-branch-db \
  GCP_SA="spanner-branch-test@${PROJECT_ID}.iam.gserviceaccount.com"

# Branch the real database and run the verification app locally under mirrord.
# The app prints the branch's table set and per-table row counts.
task spanner:run:local
```

## 2b. Local minikube: mount a downloaded key

There is no metadata server locally, so create a key file and mount it:

```bash
gcloud iam service-accounts create spanner-branch-test \
  --display-name="mirrord spanner branch test"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:spanner-branch-test@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/spanner.databaseReader"

# Writes the key to ./sa-key.json - the default KEY_FILE the task expects.
gcloud iam service-accounts keys create sa-key.json \
  --iam-account="spanner-branch-test@${PROJECT_ID}.iam.gserviceaccount.com"
```

Then deploy from the `local-sandbox` directory (where `sa-key.json` was written):

```bash
task operator:install    # once, if not already running

task spanner:real:deploy:key \
  REAL_PROJECT="$PROJECT_ID" \
  REAL_INSTANCE=test-branch-instance \
  REAL_DATABASE=test-branch-db \
  KEY_FILE=./sa-key.json

task spanner:run:local
```

The default mirrord config (`k8s/overlays/spanner/mirrord.json`) uses
`copy.mode: all`. For schema-only, point the run at a config with
`"copy": { "mode": "schema" }`:

```bash
task spanner:run:local MIRRORD_CONFIG=./k8s/overlays/spanner/mirrord-schema.json
```

## 3. Inspect the branch

While the session is running, the branch is a `BranchDatabase` CR and a local
emulator pod:

```bash
task spanner:status
kubectl get branchdatabase -n test-mirrord
```

## 4. Clean up

```bash
task spanner:real:clean

gcloud spanner databases delete test-branch-db --instance=test-branch-instance --quiet
gcloud spanner instances delete test-branch-instance --quiet
gcloud iam service-accounts delete \
  "spanner-branch-test@${PROJECT_ID}.iam.gserviceaccount.com" --quiet
```
