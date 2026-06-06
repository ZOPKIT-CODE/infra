# Zopkit Suite — ECS Fargate Terraform Stack

A self-contained **ECS Fargate** deployment of the Zopkit suite (wrapper / CRM /
FA backends). It is an alternative compute layer to the EKS stack at
`/Users/zopkit/Downloads/wrapper/deploy/terraform` — same AWS-native services,
no Kubernetes.

- **Compute:** ECS Fargate + one shared internet-facing ALB + per-app task roles
  + native Secrets Manager injection + Terraform-managed Route53 alias records.
- **No** EKS, Helm, Kubernetes/Helm providers, External Secrets Operator,
  external-dns, AWS Load Balancer Controller, or IRSA/OIDC.
- **Reused VERBATIM from the EKS stack** (Cognito, SNS+SQS, S3+CloudFront, ECR,
  Secrets Manager, optional SES inbound). The EKS stack is **never modified** —
  it stays intact for a future migration back to Kubernetes if desired.

The four Fargate services:

| Service       | Image           | CPU/Mem  | Port | ALB host (`<root>`)        | Stickiness | Scaling          | Health check                   |
|---------------|-----------------|----------|------|----------------------------|------------|------------------|--------------------------------|
| `wrapper-web` | `wrapper-backend` | 512/1024 | 3000 | `api.<root>` + `*.<root>`  | ON (`/ws`) | autoscale 1→3    | `/health`                      |
| `crm-web`     | `crm-backend`     | 512/1024 | 4000 | `crm-api.<root>`           | OFF        | **pinned 1**     | `/health`                      |
| `fa-web`      | `fa-backend`      | 512/1024 | 3002 | `accounting-api.<root>`    | OFF        | **pinned 1**     | `/api/health/health/live`      |
| `fa-consumer` | `fa-backend`      | 256/512  | —    | — (worker, no ALB)         | —          | desired 1        | — (ECS-level only)             |

`crm-web` and `fa-web` are pinned to one task because their SNS outbox pollers
are **not leader-gated** (scaling out double-publishes business events). Only
`wrapper-web` (Postgres advisory-lock leader election) autoscales.
`fa-consumer` runs the idempotent accounting SQS consumer via a command
override and shares the `fa` task role + `fa` env/secrets with `fa-web`.

---

## Prerequisites

- Terraform >= 1.6, AWS provider ~> 5.60.
- AWS credentials with rights to create VPC / ECS / ALB / IAM / Route53 / ACM /
  Cognito / SNS / SQS / S3 / CloudFront / ECR / Secrets Manager / ElastiCache.
- The Route53 public hosted zone for `root_domain` must already exist (or set
  `create_route53_zone = true` and delegate NS at your registrar).
- Docker (for building + pushing app images to ECR).
- `aws` CLI v2 (for image push, `update-service`, and one-off migration tasks).

---

## Step 0 — Copy the 6 shared files from the EKS stack (REQUIRED)

This stack **reuses the AWS-native service definitions verbatim**. They are NOT
checked in here — copy them from the EKS stack before the first `init`. The
`Makefile` automates it:

```bash
make copy-shared
```

which copies these files unchanged from
`/Users/zopkit/Downloads/wrapper/deploy/terraform` into this directory:

```
cognito.tf  messaging.tf  s3.tf  cloudfront.tf  ecr.tf  secrets.tf
```

These consume only locals defined in this stack's `locals.tf`
(`name_prefix`, `account_id`, `partition`, `apps`, `fqdn`, `frontends`,
`s3_buckets`, `sns_topics`, `sqs_queues`) plus `secrets.tf`'s own
`local.app_secret_keys`. Do not edit them after copying. Re-run `make copy-shared`
whenever the EKS originals change.

> **`ses_inbound.tf` is intentionally not copied** — CRM inbound email is optional
> and off by default (`enable_ses_inbound=false`), and its eager `filemd5()` needs a
> deeper relative path from this stack. If you later enable SES inbound, copy it and
> set its handler path to `../../../../b2b-crm/infra/lambda/ses-inbound-handler`.

---

## Step 1 — Init / plan / apply (single apply, no two-phase bootstrap)

Unlike the EKS stack (which needed a two-phase apply for the ESO
`ClusterSecretStore`), this stack applies in **one shot** — there is no
in-cluster bootstrap.

```bash
# pick an isolated workspace per environment
terraform workspace new staging   # first time
terraform workspace select staging

terraform init
terraform plan  -var-file=terraform.staging.tfvars
terraform apply -var-file=terraform.staging.tfvars
```

The Makefile wraps the same:

```bash
make init
make plan    TFVARS=terraform.staging.tfvars
make apply   TFVARS=terraform.staging.tfvars
```

First apply creates the VPC, ALB, ECS cluster + 4 services, task/execution
roles, log groups, Route53 alias records (API hosts + `*.<root>` wildcard ->
ALB; frontends -> CloudFront), Cognito, SNS/SQS, S3/CloudFront, ECR, Valkey, and
the **placeholder** Secrets Manager secrets. Tasks will fail to become healthy
until you (a) push real images and (b) populate the secrets — see below.

---

## Step 2 — Populate Secrets Manager (BEFORE the tasks can become healthy)

Terraform creates each app secret at `zopkit/<environment>/<app>` with every key
set to `REPLACE_ME` (and `ignore_changes = [secret_string]`, so Terraform never
clobbers your real values). The Valkey secret (`.../valkey`) is populated by
Terraform automatically.

Populate the placeholders out-of-band, e.g.:

```bash
aws secretsmanager put-secret-value \
  --secret-id zopkit/staging/wrapper \
  --secret-string file://wrapper.secrets.json
# repeat for zopkit/staging/crm and zopkit/staging/fa
```

How injection works (no ESO):
- The task **execution role** has `secretsmanager:GetSecretValue` on the app +
  Valkey secrets and resolves each `secrets[].valueFrom` (`<arn>:<KEY>::`) at
  task launch, materializing them as plain env vars inside the container.
- **Dedup is enforced in `locals.tf`:** a key that already appears in a service's
  `environment` block is removed from its `secrets` block (ECS rejects a key in
  both). E.g. `fa`'s `CORS_ORIGINS` and `REDIS_ENABLED` are env vars, so they are
  NOT injected from Secrets Manager.
- Valkey: only `REDIS_URL` + `REDIS_PASSWORD` are injected from the Valkey
  secret; `REDIS_ENABLED` is a plain env var for every app.

**Cross-app shared secrets must match.** Some keys are shared trust material
between apps (e.g. wrapper `SHARED_APP_JWT_SECRET`; crm `FA_JWT_SECRET` /
`WRAPPER_SERVICE_TOKEN`; fa `WRAPPER_API_KEY` / `WRAPPER_FETCH_TOKEN`). Set the
matching halves consistently across `zopkit/<env>/{wrapper,crm,fa}` or inter-app
auth will fail. This is identical to the EKS stack's secret contract.

---

## Step 3 — Build + push images to ECR (same flow as the EKS stack)

ECR repos `wrapper-backend`, `crm-backend`, `fa-backend` are created by `ecr.tf`.
Authenticate, build, tag, and push:

```bash
make login-ecr                 # docker login to the account ECR registry
make build-wrapper             # docker build -t wrapper-backend ...
make push-wrapper TAG=latest   # tag + push to <acct>.dkr.ecr.<region>.amazonaws.com/wrapper-backend:<TAG>
# repeat: build-crm / push-crm, build-fa / push-fa
```

`fa-consumer` reuses the `fa-backend` image — no separate build. The task def
just overrides the command to
`["node","dist/scripts/accounting-sqs-consumer-runner.js"]`.

`image_tag` in tfvars is only the seed tag baked into the task definitions on
`apply`. In CI you typically push by git SHA and roll out with
`update-service --force-new-deployment` (Step 5) rather than re-running apply.

---

## Step 4 — Run DB migrations (operator-side, NOT on container start)

**Migrations never run on container start** — the task definitions use each
image's default entrypoint (web) or the consumer command (worker). Run
migrations yourself before/with a deploy, per the existing runbook:

```bash
# from each backend repo, against the env's DATABASE_URL:
pnpm db:migrate            # wrapper / crm / fa each have their own migrate script
```

Optionally run them as a one-off Fargate task instead of from a laptop. Example
(COMMENTED — adapt the task-def family, subnets, SG, and command to your repo's
migrate entrypoint before using):

```bash
# aws ecs run-task \
#   --cluster zopkit-staging \
#   --launch-type FARGATE \
#   --task-definition zopkit-staging-wrapper-web \
#   --network-configuration 'awsvpcConfiguration={subnets=[subnet-aaa,subnet-bbb],securityGroups=[sg-tasks],assignPublicIp=ENABLED}' \
#   --overrides '{"containerOverrides":[{"name":"wrapper-web","command":["pnpm","db:migrate"]}]}'
```

Do **not** block app start on migrations; run them deliberately, then deploy.

---

## Step 5 — Roll out / redeploy a service

After pushing a new image (same tag) or changing a secret value, force a fresh
deployment so ECS pulls the new image / re-reads secrets:

```bash
make deploy-wrapper-web     # aws ecs update-service ... --force-new-deployment
make deploy-crm-web
make deploy-fa-web
make deploy-fa-consumer
```

ECS does a rolling replacement (the web services drain via the ALB target group;
deregistration delay 30s). For a brand-new image tag baked into the task def,
re-run `terraform apply` instead (it registers a new task-definition revision).

---

## Step 6 — Smoke tests

```bash
curl -fsS https://api.staging.zopkit.com/health                       # wrapper-web
curl -fsS https://crm-api.staging.zopkit.com/health                   # crm-web
curl -fsS https://accounting-api.staging.zopkit.com/api/health/health/live  # fa-web
```

For `fa-consumer` (no ALB), check ECS service health and CloudWatch logs:

```bash
aws ecs describe-services --cluster zopkit-staging --services zopkit-staging-fa-consumer \
  --query 'services[0].{running:runningCount,desired:desiredCount}'
aws logs tail /ecs/zopkit-staging/fa-consumer --follow
```

Frontends (CloudFront) come up once you upload the SPA bundles to the
`*-fe` S3 buckets (`app.<root>` / `crm.<root>` / `accounting.<root>`).

---

## Cost tips

- **Scale to (near) zero when idle:** set a service's desired count to 0 to stop
  paying for its Fargate task, e.g.
  `aws ecs update-service --cluster zopkit-staging --service zopkit-staging-fa-consumer --desired-count 0`.
  (`wrapper-web` autoscaling has `ignore_changes = [desired_count]`, so manual
  scaling sticks until autoscaling acts.) Or `terraform destroy` between test
  sessions — Supabase databases and ECR images persist.
- **NAT-less by default:** `fargate_assign_public_ip = true` puts tasks in public
  subnets with public IPs, so **no NAT gateway is created** (`network.tf` flips
  `enable_nat_gateway` off). Flip to `false` (and rely on `single_nat_gateway`)
  only for a prod-private posture.
- Short log retention (`log_retention_days = 7`) and a single `cache.t4g.micro`
  Valkey keep fixed costs low.

---

## File layout

```
versions.tf providers.tf variables.tf locals.tf      # core config
vpc.tf alb.tf iam.tf ecs.tf observability.tf          # ECS compute layer (VPC file is vpc.tf)
route53_acm.tf elasticache.tf outputs.tf              # adapted from EKS
cognito.tf messaging.tf s3.tf cloudfront.tf \         # COPIED VERBATIM (Step 0)
  ecr.tf secrets.tf
modules/ecs-service/                                  # reusable Fargate service module
terraform.staging.tfvars terraform.tfvars.example     # inputs
Makefile README.md
```

The EKS stack at `/Users/zopkit/Downloads/wrapper/deploy/terraform` is **not
touched** by anything here.
