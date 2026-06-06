# Suite Deployment & Onboarding Playbook

The one doc a new dev reads before touching deploys. Covers how the suite is
wired, how to ship one app at a time to ECS Fargate, how migrations and
observability work, and the hard-won rules that prevent self-inflicted outages.

---

## 1. What you're deploying

Three apps, each a backend + an SPA frontend, plus one worker:

| App | Backend (Fargate) | Port | Frontend (S3+CloudFront SPA) | Role |
|-----|-------------------|------|------------------------------|------|
| **wrapper** | `wrapper-web` | 3000 | `app.<domain>` | **Source of truth** — tenants, onboarding, identity (Cognito), credits |
| **crm** (b2b-crm) | `crm-web` | 4000 | `crm.<domain>` | CRM; consumes wrapper events |
| **fa** (finance-accounting) | `fa-web` + `fa-consumer` | 3002 | `accounting.<domain>` | Accounting; consumes wrapper + business events |

**Two message buses (SNS → SQS, with DLQs):**
- **Platform bus** — wrapper publishes `tenant.onboarded`, `role.*`, `user.*`,
  `credit.*`, `configuration.updated` to CRM/FA.
- **Business bus** — CRM/FA publish domain events (`entity.created`, …) via the
  shared `@zopkit/platform-sdk` `SnsPublisher`.

**Why you can deploy one app at a time:** every publish is **outbox-first** and
delivered through SQS. Wrapper can emit `tenant.onboarded` before CRM/FA even
exist — the queue buffers it (DLQ backs it up) and the consumer drains it when it
comes up. Deploy in dependency order: **wrapper → crm → fa**.

Backends run their **SQS consumers + outbox poller in-process** (only FA split out
`fa-consumer`). Postgres is **Supabase** (external). Permission caches are Valkey
(optional; fall back to an in-process Map when `REDIS_ENABLED` is off).

---

## 2. Prerequisites

- **Tools:** Docker, AWS CLI v2 (logged in / SSO), Terraform ≥ 1.5, Node 20, `pnpm`, `git`, `jq`.
- **AWS access** to the target account with ECR push, ECS, and Terraform-state permissions.
- **The three repos** cloned as siblings: `wrapper/`, `b2b-crm/`, `finance-accounting/`.
- **`@aws` note:** Fargate runs **x86**. If you're on Apple Silicon you MUST build
  with `--platform linux/amd64` (the deploy script does this for you).

---

## 3. Infrastructure (Terraform) — `deploy/ecs/terraform`

All infra is defined here: VPC, ECS Fargate cluster (Container Insights on), ECR,
ALB + ACM/Route53, SNS/SQS + DLQs, Secrets Manager, Cognito, S3 + CloudFront
(frontends), ElastiCache Valkey. Naming is `${project}-${environment}` →
`local.name_prefix` (e.g. `zopkit-prod`).

### One-time foundation provisioning
```bash
cd deploy/ecs/terraform
terraform init
cp terraform.tfvars.example terraform.tfvars   # fill in: region, domain, project, environment
terraform plan -out tf.plan
terraform apply tf.plan
```
**Startup cost levers (set in `terraform.tfvars`):**
- `single_nat_gateway = true` — one NAT, not per-AZ.
- Keep `desired_count = 1`; leave Valkey unused for v1 (in-process cache is correct at 1 task).
- `crm-web` / `fa-web` / `fa-consumer` stay **pinned to 1** (autoscaling off) — see §7.

Then populate **Secrets Manager** per app: `DATABASE_URL`, Cognito vars,
`SENTRY_DSN`, SNS topic ARNs, AWS messaging creds, `REDIS_ENABLED=false`.

### Per-service image tags
`services.tf` resolves each service's image as
`…:${lookup(var.service_image_tags, <service>, var.image_tag)}`. The deploy
script writes the chosen SHA into **`image-tags.auto.tfvars.json`** (committed —
it's the record of what's live) so you can roll out one app without rebuilding
the others.

---

## 4. Deploying an app — the 6-step unit

Use the script (one command per app). First time only:
```bash
cd deploy/ecs
cp deploy.env.example deploy.env      # fill in (gitignored): account, region, name_prefix, repo paths, subnets, SG, health URLs
```

Then:
```bash
./deploy-service.sh wrapper-web            # tag defaults to the repo's git short SHA
# ./deploy-service.sh wrapper-web 1a2b3c4  # or pin an explicit SHA
```

The script does, for that one service:
1. **build** — `docker build --platform linux/amd64 --target production`
2. **push** — to ECR with an **immutable git-SHA tag** (never `:latest`)
3. **migrate** — DB migrations as a one-off Fargate task (web services only; see §5)
4. **release** — record the tag + `terraform apply -target` just this service
5. **wait** — block on `ecs wait services-stable`
6. **smoke** — `GET /health` until 200

**Rollout order (first deploy):** `wrapper-web` → wrapper frontend → `crm-web` →
crm frontend → `fa-web` + `fa-consumer` → fa frontend.

### Frontends (SPA → S3 + CloudFront)
Built **with prod envs baked in** (Vite inlines them at build time):
```bash
VITE_API_BASE_URL=https://api.<domain> VITE_SENTRY_DSN=<fe-dsn> pnpm --filter wrapper-frontend build
aws s3 sync frontend/dist s3://<name_prefix>-wrapper-fe --delete
aws cloudfront create-invalidation --distribution-id <id> --paths "/*"
```

---

## 5. Migrations

- **Baseline model:** migrations are squashed to a prod-faithful `0000_baseline.sql`
  (a `pg_dump` of production) + incremental files, guarded by a **CI schema-drift
  gate**. A fresh DB applies the baseline then the increments cleanly.
- **In the container, run the COMPILED runner:**
  `node dist/db/run-migrations.js` — **not** `pnpm db:migrate` (which needs `tsx`,
  a devDependency absent from the prod image). The deploy script already uses the
  compiled command for `wrapper-web`.
- **Run as a one-off task BEFORE the new code serves** (the script does this), so a
  bad migration can't crashloop the service. Use **expand/contract** for schema
  changes (add column in release N, drop in N+1 — never drop in the same release
  as the code that stops using it).
- **Pre-deploy check (run locally):**
  ```bash
  cd backend
  node scripts/db/check-journal.mjs    # journal consistency
  npx vitest run                       # unit  (236 tests)
  npx vitest run --config vitest.integration.config.ts   # spins fresh PG, APPLIES ALL MIGRATIONS, runs integration (≈249)
  ```
  The integration suite proves the baseline applies on an empty DB — green here = safe to deploy.

---

## 6. Observability & verification

Stack: **Sentry (Mode A: `@sentry/node` owns the OTel provider) + OpenTelemetry**,
across all 6 services. After a deploy, verify:
- **Sentry** (org `zopkit-cg`): the service shows the request trace and **no startup errors**.
- **Health:** `GET https://api.<domain>/health` → 200; ALB target group healthy.
- **An event flows:** onboard a test tenant → confirm `tenant.onboarded` lands in SNS→SQS.

**What's instrumented (and was hardened):**
- **Distributed tracing end to end:** sync FE→BE *and* async **SNS→SQS** (publisher
  injects `sentry-trace`/`baggage`/`traceparent` into message attributes; consumers
  extract → continue the trace). Proven live: a `credit.allocated` trace spanning
  wrapper-frontend → wrapper-backend (`publish`) → crm-backend (`consume`).
- **Producer spans** (`op: queue.publish`) wrap every publish so background/cron
  publishes always have a valid trace to inject. Fan-out (`*ToSuite`) wrapped in a
  parent span so background fan-outs stay on one trace.
- **Job spans:** `credit-expiry.tick`, `outbox-replay.tick`, `outbox-poller.tick`.
- **AWS SDK semantic spans** (`@opentelemetry/instrumentation-aws-sdk`): `SNS Publish`,
  `SQS ReceiveMessage/DeleteMessage`, `S3`. Idle empty-poll receive transactions are
  dropped via `beforeSendTransaction` (message_count 0).
- **DSNs** live in Secrets Manager per service; frontends bake `VITE_SENTRY_DSN` at build.

> Telemetry is a **no-op** until `SENTRY_DSN` (backend) / `VITE_SENTRY_DSN` (frontend)
> is set, and a service only emits once it's actually running.

---

## 7. The rules that prevent outages (read this twice)

1. **Immutable tags only.** Deploy git-SHA tags, never `:latest`. Rollback =
   `./deploy-service.sh <service> <previous-sha>`.
2. **`crm-web`, `fa-web`, `fa-consumer` stay at 1 task (autoscaling OFF).** Their
   outbox pollers/crons are **not leader-gated**; a 2nd task = duplicate event
   processing. `wrapper-web` MAY autoscale — its pollers use `pg_try_advisory_lock`
   (leader-safe). Don't flip this without gating the others.
3. **Migrate with `node dist/db/run-migrations.js`**, not `pnpm db:migrate`, in-container.
4. **Build for `linux/amd64`** (Fargate is x86; matters on Apple Silicon).
5. **Don't upgrade deps/runtime right before a deploy.** Ship tested code; the stack
   intentionally diverges (Fastify 4/4/5, drizzle versions) — converge later, not at launch.
6. **Tenant isolation is sacred.** This is a financial multi-tenant system; a
   cross-tenant leak can end the company. A known escalation was fixed — keep the
   guard and add tests when you touch authz.
7. **`stopTimeout` + graceful drain:** ensure tasks get time on SIGTERM to
   `Sentry.flush()`, stop the poller, and finish in-flight SQS handlers — else you
   drop messages/telemetry on every deploy. *(Set this in the task def if not already.)*
8. **Secrets in Secrets Manager only** — never in env files or images.

---

## 8. Cost right-sizing (startup defaults)

`single_nat_gateway=true`; Fargate 0.25–0.5 vCPU; `desired_count=1`; Valkey
deferred (in-process cache); frontends on S3+CloudFront (not Fargate); Container
Insights on (small cost, keep it).

---

## 9. Minimum "launch-safe" checklist (before real/paying traffic)

Not enterprise SRE — the few cheap things that prevent silent data/money loss:
- [ ] `stopTimeout` + graceful drain set
- [ ] DB connection-pool sizes pinned per task (Supabase has hit "Max client connections")
- [ ] Supabase backups/PITR on + you've clicked restore once
- [ ] ~5 alarms → Slack: service has 0 running tasks, 5xx spike, **DLQ not-empty**
      (exists), SQS age-of-oldest-message, DB connections high
- [ ] Sentry alerts email a real person
- [ ] You know the rollback command
- [ ] `check-journal` + unit + integration suites green (§5)

Defer until growth/real incidents: SLOs, dashboards, tail-sampling collector,
synthetic/uptime, PagerDuty on-call, load testing, WAF, exhaustive isolation suite.

---

## 10. Quick reference

```bash
# pre-deploy gate (from backend/)
node scripts/db/check-journal.mjs && npx vitest run && \
  npx vitest run --config vitest.integration.config.ts

# deploy one app (from deploy/ecs/)
./deploy-service.sh wrapper-web

# rollback
./deploy-service.sh wrapper-web <previous-sha>

# what's currently live
cat deploy/ecs/terraform/image-tags.auto.tfvars.json
```

Service names: `wrapper-web` `crm-web` `fa-web` `fa-consumer` ·
Cluster: `${name_prefix}` · ECS service: `${name_prefix}-<service>`
