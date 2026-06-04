# Zopkit Suite — Deployment Runbook

Infrastructure-as-code (Terraform + Helm) that deploys the **Zopkit suite** —
`wrapper`, `crm`, and `finance-accounting` (`fa`) — onto **AWS EKS** behind a
single shared **ALB**, fronted by **CloudFront** for the SPAs, with **Cognito**
for auth and **Supabase Postgres** as the external system of record.

> **Audience:** operators. This is the apply-order, secrets, image-build,
> Helm-render, and scaling-caveats runbook. The Terraform `outputs.tf`,
> `terraform.tfvars.example`, and the per-app Helm `values-*.yaml` are the
> authoritative wiring; this doc explains how to drive them.

---

## Overview

```
                                  ┌──────────────────────────────────────────┐
   Route53 (zopkit.com)           │                  AWS EKS                  │
   ├─ app.zopkit.com ───────┐     │   ns: zopkit-prod                         │
   ├─ crm.zopkit.com ────┐  │     │  ┌──────────┐ ┌──────────┐ ┌──────────┐  │
   ├─ accounting…  ───┐  │  │     │  │ wrapper  │ │   crm    │ │   fa     │  │
   │                  ▼  ▼  ▼     │  │ web (HPA)│ │ web (x1) │ │ web (x1) │  │
   │            ┌───────────────┐ │  └────┬─────┘ └────┬─────┘ └────┬─────┘  │
   │            │  CloudFront   │ │       │            │      ┌──────┴─────┐  │
   │            │  (3 SPA dists)│ │       │            │      │ fa-consumer│  │
   │            └──────┬────────┘ │       │            │      │  (worker)  │  │
   │                   │ OAC      │       └─── shared ──┴──────┴────────────┘  │
   │            ┌──────▼────────┐ │            ALB (group: zopkit-suite)       │
   │            │ S3 fe buckets │ │              ▲ internet-facing             │
   │            └───────────────┘ └──────────────┼─────────────────────────────┘
   │                                             │
   ├─ api.zopkit.com  ───────────────────────────┤  (managed by external-dns
   ├─ *.zopkit.com (tenant vanity) ──────────────┤   from the Ingress objects)
   ├─ crm-api.zopkit.com ────────────────────────┤
   └─ accounting-api.zopkit.com ─────────────────┘

  Messaging:  wrapper ──SNS──▶ (inter-app-events / inter-app-broadcast) ──▶ SQS
              crm/fa  ──EventBridge (business-events) ──rules──▶ SQS
  Cache:      ElastiCache Valkey (rediss://, AUTH) — perm/auth cache coherence
  Storage:    S3 (claim-check, logos, attachments, receipts, ses-inbound, fe-*)
  Auth:       Cognito user pool + per-app clients (SRP/PKCE)
  Data:       Supabase Postgres (EXTERNAL — not provisioned here)
```

Two messaging substrates:

1. **Platform bus (SNS):** `wrapper` publishes to `…-inter-app-events` (targeted
   via the `targetApplication` message attribute) and `…-inter-app-broadcast`
   (fanout). Each consumer queue subscribes to both; targeted subscriptions carry
   a `filter_policy`.
2. **Business bus (EventBridge):** `crm` and `fa` publish domain events to the
   `…-business-events` bus; rules route them to per-app SQS queues.

All SQS consumers run **in-process inside Fastify** (no Lambda), except FA's
accounting consumer which is a **separate worker process** (see Helm `workers`).

---

## Prerequisites

| Tool      | Version    | Notes                                            |
|-----------|------------|--------------------------------------------------|
| terraform | **>= 1.6** | Required for the provider/module versions pinned in `versions.tf`. |
| helm      | **>= 3.12**| Chart is Helm 3.                                  |
| kubectl   | matches `kubernetes_version` (±1 minor) | For post-apply ops. |
| aws cli   | **>= 2.x** | Used for `eks update-kubeconfig`, ECR login, `s3 sync`. |
| docker    | any recent | Builds the three backend images (linux/amd64).   |
| jq        | any        | Extracts `app_wiring` JSON.                       |
| yq        | **>= 4.x** (mikefarah) | Merges Terraform output onto the Helm values (`scripts/render-values.sh`). |

Also required **before** apply:

- **Route53 hosted zone** for `var.root_domain` (`zopkit.com`). Either let
  Terraform create it (`create_route53_zone = true`) or point at an existing one
  (`false` → looked up by name). The two ACM certs are DNS-validated against this
  zone, so the zone's nameservers must be live at the registrar for validation to
  complete.
- **Supabase projects** (one per app) provisioned out-of-band. Their
  `DATABASE_URL`s go into the per-app Secrets Manager secrets — **PgBouncer /
  transaction-pooler endpoints strongly recommended** (see Scaling Caveats).
- **SES domain identity verification + MX records** — only if you keep CRM SES
  inbound (`ses_inbound.tf`). If unused, delete that file before apply.
- **A Temporal endpoint** — only if you enable FA's Temporal workers. FA's
  *aggregate* health (`/api/health/health`) hard-requires Temporal; the
  liveness/readiness probes deliberately do **not** (see Scaling Caveats).

---

## Apply order

The Kubernetes and Helm providers authenticate against the EKS cluster, so the
cluster must exist before Terraform can plan anything that touches it. Apply in
two (occasionally three) phases.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # then edit values

# 1) Init
terraform init

# 2) Bootstrap: stand up VPC + EKS so the kubernetes/helm providers can connect.
#    (Equivalent target: see the Makefile `bootstrap` target.)
terraform apply -target=module.vpc -target=module.eks

# 3) Apply the rest: ECR, messaging, cache, Cognito, S3/CloudFront, IAM/IRSA,
#    Secrets Manager, Route53/ACM, observability, and the cluster addons
#    (aws-load-balancer-controller, external-dns, external-secrets, metrics-server).
#    enable_cluster_secret_store stays false here (its CRDs don't exist yet).
terraform apply

# 4) Enable the ESO ClusterSecretStore now that external-secrets + its CRDs exist.
terraform apply -var enable_cluster_secret_store=true
```

> **ESO ClusterSecretStore — phased apply.** `addons.tf` declares a
> `kubernetes_manifest` `ClusterSecretStore` (`aws-secretsmanager`). A
> `kubernetes_manifest` is validated against its CRD **at plan time**, but the
> External Secrets CRDs are installed by the `external-secrets` Helm release in
> step 3. So the manifest is gated behind `var.enable_cluster_secret_store`
> (default **false**): keep it false for steps 1–3, then run step 4 with it
> **true** once ESO is installed. `terraform plan`/`apply` is clean at every step.

After phase 3:

```bash
# Wire kubectl to the new cluster (also printed as `terraform output configure_kubectl`).
aws eks update-kubeconfig --name "$(terraform output -raw cluster_name)" \
  --region "$(terraform output -raw region)"
```

---

## Fill secrets (do this BEFORE deploying any app)

Terraform creates **placeholder** Secrets Manager secrets — each key is set to
`REPLACE_ME` and `lifecycle.ignore_changes = [secret_string]` keeps Terraform
from clobbering your real values on later applies. The **External Secrets
Operator** syncs each secret into a Kubernetes `Secret` that the Deployment
mounts via `envFrom`. **Pods that start before the secret is populated will
crash-loop**, so populate first.

Secrets (one JSON document per app, plus the Valkey secret created by
`elasticache.tf`):

| Secret name              | Owner   | Notes                                  |
|--------------------------|---------|----------------------------------------|
| `zopkit/prod/wrapper`    | wrapper | DB URLs, JWT/session secrets, Stripe/Razorpay, Brevo/SMTP, OpenAI, Sentry, Supabase keys. |
| `zopkit/prod/crm`        | crm     | DB URL, JWTs, wrapper/FA service tokens, Brevo, SES webhook secret, Anthropic, Google/MS/Slack/Cloudinary integration creds. |
| `zopkit/prod/fa`         | fa      | DB URL, JWT/refresh secrets, wrapper API/fetch tokens, internal/SSE/bootstrap secrets, tax/tenant encryption keys, Anthropic, FX API, SMTP, Temporal key, CORS. |
| `…-valkey` (by ARN)      | infra   | Auto-populated by Terraform (`REDIS_URL`, `REDIS_PASSWORD`, TLS) — **do not edit**. |

> **AWS credentials are intentionally NOT in these secrets** — pods get AWS
> access via **IRSA** (the per-app IAM role annotated on the ServiceAccount).

Populate by merging real values onto the placeholder JSON, e.g.:

```bash
# Pull, edit locally, push back. (Use your secret manager / vault of choice.)
aws secretsmanager get-secret-value --secret-id zopkit/prod/wrapper \
  --query SecretString --output text > wrapper.secret.json
$EDITOR wrapper.secret.json          # replace every REPLACE_ME
aws secretsmanager put-secret-value --secret-id zopkit/prod/wrapper \
  --secret-string file://wrapper.secret.json
shred -u wrapper.secret.json         # don't leave plaintext secrets on disk
```

ESO re-syncs on its `refreshInterval` (1h). To force an immediate refresh after
populating, delete the synced k8s Secret (ESO recreates it) or annotate the
`ExternalSecret` with `force-sync`.

---

## Build & push images

The three backend images come from three different repos. ECR repo URLs are in
`terraform output -json ecr_repository_urls` (keyed by repo name).

| App     | Backend dir              | ECR repo key     |
|---------|--------------------------|------------------|
| wrapper | `../backend`             | `wrapper-backend`|
| crm     | `../../b2b-crm/server`   | `crm-backend`    |
| fa      | `../../finance-accounting` | `fa-backend`   |

> ECR repos are `IMMUTABLE` — you cannot overwrite a tag. Use the git SHA (the
> CI workflow uses `$GITHUB_SHA`) or another unique tag per build.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=$(terraform -chdir=terraform output -raw region)
TAG=$(git rev-parse --short HEAD)   # or any unique tag

# Authenticate Docker to ECR
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

# Resolve repo URLs
WRAPPER_URL=$(terraform -chdir=terraform output -json ecr_repository_urls | jq -r '."wrapper-backend"')
CRM_URL=$(terraform     -chdir=terraform output -json ecr_repository_urls | jq -r '."crm-backend"')
FA_URL=$(terraform      -chdir=terraform output -json ecr_repository_urls | jq -r '."fa-backend"')

# Build + push (amd64 to match the node group). `make build-wrapper push-wrapper` wraps this.
docker build --platform linux/amd64 -t "$WRAPPER_URL:$TAG" ../backend           && docker push "$WRAPPER_URL:$TAG"
docker build --platform linux/amd64 -t "$CRM_URL:$TAG"     ../../b2b-crm/server  && docker push "$CRM_URL:$TAG"
docker build --platform linux/amd64 -t "$FA_URL:$TAG"      ../../finance-accounting && docker push "$FA_URL:$TAG"
```

See the `Makefile` for `login-ecr`, `build-%`, and `push-%` targets that do the
same with the `app→dir` map baked in.

---

## Render Helm values

The chart is a single generic chart (`helm/zopkit-backend`) parameterized by the
per-app `values-<app>.yaml`. The fields that depend on Terraform — image repo,
the non-secret env map, the IRSA role ARN, the ExternalSecret remote ref, and the
ingress host + ALB cert ARN — are injected from `terraform output -json
app_wiring`.

`app_wiring` shape (per app):

```jsonc
{
  "wrapper": {
    "image": "<acct>.dkr.ecr.<region>.amazonaws.com/wrapper-backend",
    "port": 3000,
    "api_host": "api.zopkit.com",
    "frontend_host": "app.zopkit.com",
    "irsa_role_arn": "arn:aws:iam::…:role/…wrapper",
    "secret_arn": "arn:aws:secretsmanager:…:secret:zopkit/prod/wrapper-…",
    "env": { "NODE_ENV": "production", "AWS_REGION": "…", "COGNITO_*": "…", … }
  }
}
```

Render with the helper script (uses `jq` to extract and `yq` to merge onto the
committed `values-<app>.yaml`, producing `values-<app>.generated.yaml`):

```bash
./scripts/render-values.sh wrapper "$TAG"
./scripts/render-values.sh crm     "$TAG"
./scripts/render-values.sh fa      "$TAG"
```

Equivalent manual jq snippet (what the script automates) for the load-bearing
fields:

```bash
W=$(terraform -chdir=terraform output -json app_wiring)
echo "$W" | jq -r '.wrapper.image'          # -> image.repository
echo "$W" | jq    '.wrapper.env'            # -> env  (whole non-secret map)
echo "$W" | jq -r '.wrapper.irsa_role_arn'  # -> serviceAccount.roleArn
echo "$W" | jq -r '.wrapper.api_host'       # -> ingress.host
terraform -chdir=terraform output -json | jq -r '.app_secret_arns.value.wrapper'  # -> externalSecret.remoteRef.key (or use the name zopkit/prod/wrapper)
```

The ALB `ingress.certArn` comes from the **primary-region** wildcard cert
(`local.acm_cert_arn`); CloudFront uses the separate us-east-1 cert. The render
script wires `ingress.certArn` from the appropriate output.

---

## Deploy

```bash
# Use the rendered values (or the committed values-<app>.yaml + --set overrides).
helm upgrade --install wrapper ./helm/zopkit-backend \
  -f helm/zopkit-backend/values-wrapper.generated.yaml -n zopkit-prod

helm upgrade --install crm ./helm/zopkit-backend \
  -f helm/zopkit-backend/values-crm.generated.yaml -n zopkit-prod

helm upgrade --install fa ./helm/zopkit-backend \
  -f helm/zopkit-backend/values-fa.generated.yaml -n zopkit-prod
```

The `Makefile` `deploy-%` / `deploy-all` targets wrap these. All three Ingresses
share `group.name: zopkit-suite`, so the AWS Load Balancer Controller folds them
onto **one** ALB; external-dns then publishes `api`, `crm-api`,
`accounting-api`, and the wrapper `*.zopkit.com` wildcard from those Ingress
objects.

Sanity checks:

```bash
kubectl -n zopkit-prod get deploy,pods,svc,ingress,externalsecret
kubectl -n zopkit-prod get externalsecret -o wide      # SecretSynced=Ready?
kubectl -n zopkit-prod logs deploy/wrapper -f          # health gating
```

---

## Frontends (SPAs)

Each app ships a Vite SPA served from a private S3 bucket via CloudFront (OAC).
Build with the right `VITE_*` envs (Cognito client id, API host, etc.), sync to
the bucket, then invalidate CloudFront.

```bash
S3=$(terraform -chdir=terraform output -json s3_bucket_names | jq -r '.fe_wrapper')
DIST=$(terraform -chdir=terraform output -json cloudfront_domains | jq -r '.wrapper')

# Build each SPA with its VITE_ envs (API host, Cognito client/domain, etc.):
#   wrapper -> ../frontend ;  crm/fa frontends live in their respective repos.
npm --prefix ../frontend run build

aws s3 sync ../frontend/dist "s3://$S3" --delete
# Invalidate by distribution ID (look it up from the domain via `aws cloudfront list-distributions`):
aws cloudfront create-invalidation --distribution-id <DIST_ID> --paths '/*'
```

DNS split:

- `app.zopkit.com`, `crm.zopkit.com`, `accounting.zopkit.com` → **CloudFront**,
  created by **Terraform** (`route53_acm.tf` alias records).
- `api.zopkit.com`, `crm-api.zopkit.com`, `accounting-api.zopkit.com`, and the
  wrapper `*.zopkit.com` wildcard → **the ALB**, published by **external-dns**
  from the Helm Ingress objects. Terraform does **not** create these.

CloudFront returns `index.html` (HTTP 200) for 403/404 so client-side routing
works.

---

## SCALING CAVEATS (read before touching replicas/HPA)

These are encoded in the per-app `values-*.yaml` and `locals.tf` — **honor them.**

- **wrapper — scales + HPA OK.** Background jobs use Postgres `pg_try_advisory_lock`
  (leader-safe), so the web Deployment may scale (HPA min 3 / max 10). It **requires**:
  - **Valkey** for cache coherence — the permission/auth caches invalidate
    fleet-wide via Valkey; without it, scaled pods serve stale `ctx.permissions`.
  - **ALB stickiness** for `/ws` — the WebSocket registry is **pod-local**, so
    sticky sessions (`stickiness.enabled=true`, 24h cookie) are set on the
    wrapper Ingress (`ingress.websocket: true`).
- **CRM — PINNED `replicaCount: 1`, HPA disabled.** `crmOutboxPoller` starts on
  every pod with **no leader election** and its `getUnpublished()` lacks
  `FOR UPDATE SKIP LOCKED`, so N pods **double-publish** to EventBridge.
  **DO NOT enable HPA** until the poller is leader-gated (advisory lock) or split
  into a single-replica worker Deployment.
- **FA — PINNED `replicaCount: 1`, HPA disabled.** `faOutboxPoller` *plus*
  several unguarded `setInterval` cron managers (subscription/credit expiry, sync
  monitors, prune jobs) run on every web pod with no leader election → duplicate
  publishes and duplicate sweeps under scale-out. **DO NOT enable HPA** for FA web
  until all of those are leader-gated. **CI must never pass
  `--set autoscaling.enabled=true` to crm or fa.**
- **FA SQS consumer — separate, idempotent, may scale.** Deployed as a Helm
  `worker` (`node dist/scripts/accounting-sqs-consumer-runner.js`). It is
  idempotent via `processed_mq_events` and owns the `sqs-accounting` heartbeat, so
  it is safe to run >1 replica — kept at 1 to start.
- **PgBouncer strongly recommended.** Each pod opens ~65 Postgres connections.
  `N` pods × 65 will exhaust Supabase's connection limit fast — point every
  `DATABASE_URL` at a pooled / transaction-pooler endpoint, especially once
  wrapper scales out.

---

## Temporal (FA)

FA's **aggregate** health (`/api/health/health`) hard-requires a reachable
Temporal endpoint, which is why the FA probes use the **narrow**
`/api/health/health/live` and `/api/health/health/ready` paths instead — FA web
stays healthy without Temporal.

To run Temporal-backed flows: provision Temporal (Cloud or self-hosted), put the
endpoint/creds in `zopkit/prod/fa` (e.g. `TEMPORAL_API_KEY`), set
`TEMPORAL_ENABLED=true`, and **uncomment the `temporal-worker` /
`orchestration-worker` entries in `values-fa.yaml`** (they are separate
Deployments via the chart's `workers` list). Each is idempotent / leader-safe.

---

## Teardown order

Reverse of apply. Remove Kubernetes-managed AWS resources (the ALB and
external-dns records) **before** destroying the cluster, or Terraform will fail
to delete the VPC (orphaned ELB + ENIs).

```bash
# 1) Uninstall the apps (drops the Ingress -> ALB + external-dns DNS records).
helm -n zopkit-prod uninstall fa crm wrapper

# 2) Uninstall the addons (LB controller, external-dns, external-secrets, metrics-server)
#    OR let Terraform destroy them — but the LB controller must run long enough to
#    reconcile the ALB deletion from step 1. Wait until the ALB is gone:
aws elbv2 describe-load-balancers --query "LoadBalancers[?contains(LoadBalancerName, 'zopkit')].LoadBalancerArn"

# 3) Empty the S3 buckets that block deletion (versioned). force_delete is set on
#    ECR; S3 buckets may need manual emptying if versioning has objects.
#    (Frontend + data buckets, then run destroy.)

# 4) Destroy everything else, then the cluster/VPC last.
terraform -chdir=terraform destroy
```

> **Data warning:** `destroy` removes ElastiCache, Cognito (user pool + all
> users), SQS/SNS/EventBridge, and the S3 buckets. Supabase Postgres is external
> and is **not** touched. Snapshot/export anything you need first. Secrets
> Manager secrets have a 7-day recovery window.

---

## Quick reference

| Need                         | Command                                                       |
|------------------------------|--------------------------------------------------------------|
| kubectl context              | `terraform -chdir=terraform output -raw configure_kubectl`    |
| ECR URLs                     | `terraform -chdir=terraform output -json ecr_repository_urls` |
| All Helm wiring              | `terraform -chdir=terraform output -json app_wiring`          |
| Cognito pool id / clients    | `terraform -chdir=terraform output cognito_user_pool_id` / `cognito_user_pool_client_ids` |
| Valkey endpoint / secret arn | `terraform -chdir=terraform output valkey_primary_endpoint` / `valkey_secret_arn` |
| Render values                | `./scripts/render-values.sh <app> <tag>`                      |
| Build + push + deploy        | `make build-<app> push-<app> deploy-<app>` (see `Makefile`)   |
