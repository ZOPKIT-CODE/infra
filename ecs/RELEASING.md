# Releasing a service

A **release** puts a new image on an existing ECS service. It does not run
Terraform and does not touch the environment's Terraform state.

A **provisioning change** — new service, changed cpu/memory/env/secrets/roles,
new ALB rule — is a Terraform change, applied through the `infra-apply`
workflow with a reviewed plan. The two are deliberately separate; see the
`modules/ecs-service/main.tf` entry in `terraform/DECISIONS.md` for the
incidents that forced the split.

## The shared pipeline

`.github/workflows/release-service.yml` in this repo is a `workflow_call`
workflow. Every app repo calls it instead of carrying its own copy of the
release logic. Per-service facts (ECR repo, Dockerfile, health endpoint,
migration command, sibling worker) come from `ecs/services.json`, which stays
the single source of truth.

In the app repo:

```yaml
name: deploy
on:
  push:
    branches: [main]
    paths: ["server/**", "package-lock.json"]

jobs:
  release:
    uses: ZOPKIT-CODE/infra/.github/workflows/release-service.yml@main
    permissions: { id-token: write, contents: read }
    with:
      service: crm-web
      environment: staging
```

A called workflow keeps the CALLER's OIDC identity, so the deploy role's trust
policy still needs that repo listed (`github_deploy_repos` in the environment's
tfvars). Nothing else in the app repo is needed — the reusable workflow checks
this repo out for the manifest, and builds from the caller's own checkout.

## What a release does

1. Builds and pushes `<ecr>:<short-sha>`, skipping the build entirely when that
   tag already exists — ECR tags are immutable, so an existing tag is final.
   This is what makes rollback work: pass an old SHA as `image_tag`.

   The build runs under buildx with a GitHub Actions layer cache, scoped per
   service. Before this, every deploy reinstalled dependencies from scratch:
   172s for wrapper, 221s for CRM, 139s for lens. The cache lives in the CALLING
   repo (that is where the build runs), so each app has its own and they cannot
   evict each other. A registry-backed cache is not an option here — the ECR
   repos use immutable tags, so a mutable `buildcache` tag cannot be rewritten.
2. Records the tag at `/zopkit/<env>/deployed-tag/<service>`.
3. Clones the **latest revision of the task-definition family**, swaps only the
   image, registers the result, and calls `update-service`.
4. Runs migrations as a one-off task, when the service owns its schema.
5. Waits for steady state, then smoke-tests the health endpoint.
6. Releases the sibling worker on the same image, after the web service is
   healthy.

Step 3 is the load-bearing one. Cloning the family's latest revision — not the
revision the service is currently running — is what lets Terraform keep
ownership of task configuration: an apply registers a revision carrying the new
env/secrets, and the next release carries it onto the service. Cloning the
running revision instead would strand every Terraform config change forever.

## Rollback

Re-run the app repo's workflow with `image_tag` set to an older short SHA. The
build is skipped (the tag exists), the old image is re-released from ECR, and
the SSM record is corrected to match what is actually running.

## Prod

`environment: prod` targets the `zopkit-prod-*` cluster and assumes
`zopkit-prod-github-deploy`, which today trusts only `ZOPKIT-CODE/Wrapper`. Any
other repo releasing to prod needs adding to `github_deploy_repos` for the prod
environment first. Gate prod callers behind a GitHub environment with required
reviewers rather than a separate workflow.

## Publishing a SPA

`.github/workflows/publish-spa.yml` is the frontend counterpart of the release
workflow. Each app repo BUILDS its own SPA — different package managers, node
versions and baked `VITE_*` env, none of which generalise — uploads `dist` as an
artifact, and calls this to publish it:

```yaml
  build-spa:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - run: npm ci && npm run build
      - uses: actions/upload-artifact@v4
        with: { name: spa-dist, path: dist }

  publish-spa:
    needs: build-spa
    uses: ZOPKIT-CODE/infra/.github/workflows/publish-spa.yml@main
    permissions: { id-token: write, contents: read }
    with:
      app: crm
      environment: staging
```

Bucket, CloudFront distribution, smoke URL and the `no_cache` file list come
from the `frontends` block in `ecs/services.json`.

`no_cache` is the load-bearing field. Everything NOT in it is uploaded with
`public,max-age=31536000,immutable`, so a file missing from the list is a file
browsers will pin for a year — `index.html` and any service-worker or manifest
asset must be listed. Lens's list is the longest because of its PWA assets
(`workbox-*`, `manifest*.webmanifest`, `registerSW.js`).

The publish always ends with a smoke test against the live URL, which only lens
did before.
