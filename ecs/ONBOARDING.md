# Putting an app on the suite deploy pipeline

The pipeline is the six steps in `deploy-service.sh` and `.github/workflows/deploy.yml`:
**build → push → release (terraform) → migrate → wait → smoke**, driven by one entry
per service in [`services.json`](./services.json).

Onboarding splits cleanly in two. **Part A is done by the app's own team** and is the
only part that can block. **Part B is done in this repo.**

Worked example throughout: `entertainment-erp-web`, which is next in line.

---

## Part A — what the app team must change

### A1. Tag images with the git SHA, not a moving tag

This is the prerequisite. Everything else in Part A is optional; this is not.

```diff
- IMAGE=$ECR_REGISTRY/entertainment-erp-backend:staging
+ IMAGE=$ECR_REGISTRY/entertainment-erp-backend:$(git rev-parse --short HEAD)
```

A moving tag breaks three separate mechanisms:

| Mechanism | Why it breaks |
|---|---|
| **Rollback** | "redeploy an older SHA" has nothing to point at |
| **Build skip-guard** | the pipeline skips build+push when the tag already exists in ECR. `:staging` always exists, but means something different each time — so it would skip building a genuinely new commit |
| **Deployed-tag record** | terraform reads `/zopkit/<env>/deployed-tag/<service>` from SSM to decide which image to run. It would read `staging` forever and never be able to tell what is actually deployed |

That third one is not hypothetical. A stale tag record silently rolled staging CRM
back four commits in June 2026, and left prod wrapper two revisions behind in
September.

### A2. Make the ECR repository immutable

```bash
aws ecr put-image-tag-mutability \
  --repository-name entertainment-erp-backend \
  --image-tag-mutability IMMUTABLE
```

Do this **after** A1, not before — while a moving `:staging` tag is still in use, an
immutable repo rejects the next push.

Immutability is what makes a rollback trustworthy: the image you roll back to is
bit-for-bit the one that was tested. It also stops the untagged-image litter that a
moving tag produces (`entertainment-erp-backend` currently holds 9 images, 8 of them
untagged — one orphaned per re-push).

### A3. Know your in-container migration command

The pipeline runs migrations as a one-off Fargate task **inside the app's own image**,
so the command has to work there — which is usually *not* the package script.

`server/package.json` has `db:migrate: tsx src/scripts/migrate.ts`, but `tsx` is a
**devDependency** and the Dockerfile has a `prod-deps` stage, so it will not exist in
the production image. Use the compiled entry point, mirroring `start`:

```
start:       node dist/server/src/index.js
migrate_cmd: node dist/server/src/scripts/migrate.js
```

Both CRM and lens hit this exact trap. If in doubt, run
`docker run --rm --entrypoint sh <image> -c 'ls dist/server/src/scripts'` and look.

### A4. Optional — trigger deploys from your own repo

Not required. Once Part B is done, anyone can release the service from the wrapper
repo's **Actions → deploy → Run workflow**. To deploy on push instead, add a caller
workflow that builds, pushes, and hands off; ask in this repo for the current
snippet, and your repo gets added to `github_deploy_repos` for OIDC (no static keys).

---

## Part B — adoption in this repo

For a service that **already runs** (as ERP does), this is an *adopt*, not a create.
Everything below already exists in AWS and must be imported.

1. `local.apps` entry — drives the task role, secret, DNS and (optionally) a Cognito
   client. Set `cognito_client = false` unless the app authenticates against the
   shared pool.
2. `local.app_secret_keys` entry — read the key names off the **live** secret so the
   placeholder document matches its real shape.
3. `local.service_env` entry — mirror the live task definition's environment, or the
   adopt silently drops variables the app needs.
4. `local.services` entry.
5. Add the repo to `github_deploy_repos` in `ci-oidc.tf`.
6. Seed the deployed tag *before* planning, or the plan hard-errors on the missing
   SSM parameter:
   `aws ssm put-parameter --name /zopkit/staging/deployed-tag/<service> --value <sha> --type String`
7. **Grant the shared execution role access to the app's secret, and apply that
   first, on its own.** The adopted task definition switches to
   `zopkit-staging-task-execution`; if that role cannot read the secret, the new
   tasks fail to start.
8. Import everything else in **one pass using `import` blocks**. One-at-a-time
   `terraform import` deadlocks here: each import evaluates the whole config and
   trips over the next not-yet-imported map key.
9. Manifest entry in `services.json`.

### Traps worth knowing before you start

- **Import the secret *version*, not just the secret.** Miss it and the apply writes
  a fresh version full of `REPLACE_ME` and makes it `AWSCURRENT` — the app loses its
  real credentials.
- **Check the planned task definition before applying.** Diff secrets, env, image and
  port against the live one. A clean adopt changes none of them.
- **Target-group names** default to `<prefix>-<service>` truncated to 32 chars. If the
  live group is named differently, set `target_group_name` so it is adopted rather
  than *replaced* — a replacement swings live traffic.
- **Verify build inputs against the branch that actually ships**, not a local
  checkout. Academy's onboarding was written from a `main` checkout when it deploys
  from `dev`, where the Dockerfile is at a completely different path.

---

## ERP: everything already verified

| Field | Value | Source |
|---|---|---|
| repo | `ZOPKIT-CODE/Entertainment-erp` | git remote |
| dockerfile / context | `server/Dockerfile` / `.` | its header: "Build context: repo root" |
| target | `production` | final stage |
| port | 8080 | `EXPOSE`, matches the live task def |
| health | `/health` | live target group |
| migrate_cmd | `node dist/server/src/scripts/migrate.js` | see A3 |
| ECR | `entertainment-erp-backend` | live task def |
| target group | `zopkit-staging-entertainment-erp` | matches the module's 32-char truncation — **no override needed** |
| hosts | `entertainment-api.zopkit.com` (110), `entertainment.zopkit.com` (111) | ALB rules — one service, two hostnames, use `extra_host_headers` |

**One schema addition needed.** ERP answers on a *prod* hostname while running on the
*staging* ALB (`entertainment-api.staging.zopkit.com` 404s), so its smoke URL cannot be
composed from `<api_subdomain>.<root_domain><health_path>`. `services.json` needs an
optional `health_url` that overrides composition. Worth confirming that prod-hostname-
on-staging arrangement is deliberate while you are in there.

**Current state:** deployed entirely by hand through the `Deployment-Manager` IAM
user (static access keys), service created 2026-09-05.
Unlike academy, ERP has **no deploy workflow of its own**, so there is no competing
pipeline to retire. That makes it the cleanest of the remaining apps to onboard.
