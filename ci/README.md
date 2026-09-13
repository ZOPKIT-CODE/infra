# CI/CD — auto-deploy via GitHub Actions

Reusable pipeline that mirrors `deploy/ecs/deploy-service.sh`, in CI, with **OIDC**
(no AWS keys stored in GitHub). Build → push → `terraform apply -target` → migrate →
wait stable → smoke. Wrapper also builds+deploys its SPA.

## How it's wired
```
  wrapper repo:  .github/workflows/deploy.yml   ← the real release (terraform lives here)
                 triggers: push to `main`, manual dispatch, repository_dispatch

  app repos:     .github/workflows/deploy.yml   ← copy of deploy/ci/app-deploy.template.yml
                 build + push a SHA-tagged image, then repository_dispatch here
```
Terraform and its state live in the **wrapper** repo, so the release always runs
there. App repos only build and push, then hand off.

**The shared template is [`app-deploy.template.yml`](./app-deploy.template.yml).**
Copy it into an app repo, edit the five values in the CONFIGURE block, done. It
handles OIDC, SHA tagging, the "tag already in ECR, skip the build" guard that
makes rollback work, and the hand-off.

### Why a copied file and not a `workflow_call` reusable workflow

GitHub only permits private reusable workflows to be called from within the *same
organisation*. This ecosystem spans two — `ZOPKIT-CODE/*` (wrapper, crm, fa, lens,
entertainment-erp) and `Zopkit/*` (academy, ops) — so `workflow_call` would work for
some apps and silently not others. `repository_dispatch` works for all of them.

If every app repo ever lands in one org, converting is worthwhile: it removes the
copy, the `DEPLOY_DISPATCH_TOKEN`, and the fire-and-forget problem below in one go.

### Per-service configuration lives in the manifest, not the workflow

Everything about how a service is released — ECR repo, whether it migrates, the
migration command, its health endpoint, any sibling worker — is one entry in
[`deploy/ecs/services.json`](../ecs/services.json), read by both the CI workflow and
`deploy-service.sh`. The template only needs to know what to build and where to send it.

### Known rough edge

`repository_dispatch` is fire-and-forget: the app repo's job goes green as soon as the
event is accepted, even if the release then fails. Check the wrapper run before calling
a deploy done. The template prints the link.

## Deploying
- **Auto**: push/merge to `staging` in any app repo.
- **Manual / rollback**: wrapper repo → Actions → **deploy** → Run workflow → pick the
  service + (for rollback) an existing image SHA.

## The caller workflow

Do not paste one from here — copy
[`app-deploy.template.yml`](./app-deploy.template.yml) and edit its CONFIGURE block.

That file used to be duplicated inline in this README, which is how it went stale:
the copy here still triggered on a `staging` branch that no repo uses any more, and
lacked the ECR skip-guard that makes rollback work. One copy, in one place.

Each app repo also needs a **`DEPLOY_DISPATCH_TOKEN`** secret — a fine-grained PAT (or
GitHub App token) with read/write **Actions** on `ZOPKIT-CODE/Wrapper`. The default
`GITHUB_TOKEN` cannot trigger a workflow in another repository.


## Full infra apply (`infra-apply.yml`)
`deploy.yml` only does `terraform apply -target=module.services[...]` — it updates the
ECS service/task-def and **nothing else** (not iam.tf, buckets, SNS/SQS, ALB, Cognito,
Valkey). So a non-service change (e.g. a new task-role S3 grant) **silently drifts**
until a FULL apply runs. `infra-apply.yml` IS that full apply.

- **Run it:** Actions → **infra-apply** → Run workflow → pick `environment`
  (staging/prod) + `mode` (`plan` to review, `apply` to change). Always `plan` first.
- **When:** after ANY change to `deploy/ecs/terraform/**` that isn't purely an image
  bump (IAM/task-roles, buckets, ALB rules, Cognito, SNS/SQS, Valkey, DNS…).
- **Role:** uses a dedicated, broader role **`zopkit-infra-apply`** (NOT the everyday
  least-privilege deploy role), assumable ONLY from the `infra-staging` / `infra-prod`
  GitHub environments. IAM writes are scoped to `zopkit-*` principals.
- **Workspaces/var-files:** staging → `default` workspace (auto `terraform.tfvars`);
  prod → `prod` workspace + `-var-file=terraform.prod.tfvars`.

### One-time GitHub setup (required before first run)
Repo → **Settings → Environments** → create **`infra-staging`** and **`infra-prod`**
(referencing them in the workflow auto-creates them on first run, unprotected). Then on
**`infra-prod`** add **Required reviewers** (and optionally a wait timer) so every prod
infra apply pauses for human approval. `infra-staging` can stay unprotected for fast
iteration. (The role's OIDC trust already restricts it to `environment:infra-*`.)

## Notes / hardening later
- `deploy.yml` deploys to **staging** (default branch → staging). For prod app deploys,
  add a `production` environment gate + run prod via the `prod` workspace.
- The deploy OIDC role is broad-on-read / scoped-on-write; the infra role is broad-write
  but env-gated. Tighten further if needed.
- Frontend deploy is wired for the wrapper SPA only; add CRM/FA SPA steps the same way.
