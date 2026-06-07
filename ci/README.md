# CI/CD — auto-deploy via GitHub Actions

Reusable pipeline that mirrors `deploy/ecs/deploy-service.sh`, in CI, with **OIDC**
(no AWS keys stored in GitHub). Build → push → `terraform apply -target` → migrate →
wait stable → smoke. Wrapper also builds+deploys its SPA.

## How it's wired
```
  wrapper repo:  .github/workflows/deploy.yml   ← the real deploy (terraform lives here)
                 triggers: push to `staging`, manual dispatch, repository_dispatch
  crm / fa repos: .github/workflows/deploy.yml  ← build+push their image, then
                 repository_dispatch → wrapper's deploy.yml (which does terraform)
```
Why: Terraform + state live in the **wrapper** repo. CRM/FA build their own images
(self-contained) and hand off the deploy to the wrapper workflow via a dispatch event.

## One-time setup (already done unless noted)
1. **Remote Terraform state** — S3 `zopkit-tfstate-207567767101`, native locking. ✅ done.
2. **OIDC deploy role** — `arn:aws:iam::207567767101:role/zopkit-staging-github-deploy`,
   trusts repos `ZOPKIT-CODE/Wrapper`, `ZOPKIT-CODE/B2B-CRM`, `ZOPKIT-CODE/Finance-Accounting`. ✅ done (`ci-oidc.tf`).
3. **`staging` branch** in each repo → pushing to it auto-deploys that app.
4. **For CRM/FA only — a dispatch token**: create a fine-grained PAT (or GitHub App)
   with **read/write Actions + Contents on `ZOPKIT-CODE/Wrapper`**, and add it as a
   secret named **`DEPLOY_DISPATCH_TOKEN`** in the CRM and FA repos. (Needed because
   one repo can't trigger another repo's workflow with the default token.)

## Deploying
- **Auto**: push/merge to `staging` in any app repo.
- **Manual / rollback**: wrapper repo → Actions → **deploy** → Run workflow → pick the
  service + (for rollback) an existing image SHA.

## CRM / FA caller workflow (drop into each repo as `.github/workflows/deploy.yml`)
```yaml
name: deploy
on:
  push: { branches: [staging] }
  workflow_dispatch:
permissions: { id-token: write, contents: read }
env:
  AWS_REGION: us-east-1
  ECR_REGISTRY: 207567767101.dkr.ecr.us-east-1.amazonaws.com
  ROLE_ARN: arn:aws:iam::207567767101:role/zopkit-staging-github-deploy
  ECR_REPO: crm-backend     # FA: fa-backend
  SERVICE: crm-web          # FA: fa-web
jobs:
  build-and-dispatch:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with: { role-to-assume: "${{ env.ROLE_ARN }}", aws-region: "${{ env.AWS_REGION }}" }
      - uses: aws-actions/amazon-ecr-login@v2
      - name: Build & push
        run: |
          TAG=$(git rev-parse --short HEAD)
          IMAGE=$ECR_REGISTRY/$ECR_REPO:$TAG
          docker build --platform linux/amd64 -f server/Dockerfile --target production -t $IMAGE .   # VERIFY Dockerfile path
          docker push $IMAGE
          echo "TAG=$TAG" >> $GITHUB_ENV
      - name: Hand off deploy to wrapper
        uses: peter-evans/repository-dispatch@v3
        with:
          token: ${{ secrets.DEPLOY_DISPATCH_TOKEN }}
          repository: ZOPKIT-CODE/Wrapper
          event-type: deploy-service
          client-payload: '{"service":"${{ env.SERVICE }}","image_tag":"${{ env.TAG }}"}'
```
> Before first CRM/FA deploy, VERIFY in `wrapper/.github/workflows/deploy.yml` the
> migrate command + health URL for that service, and the Dockerfile path above (the
> CRM/FA entries were templated, not yet validated against those repos).

## Notes / hardening later
- This deploys to **staging** (the only env so far). For prod, add an `environment:`
  with required reviewers (manual approval gate) + a separate role/state key.
- The OIDC role is broad-on-read (terraform refresh) / scoped-on-write. Tighten if needed.
- Frontend deploy is wired for the wrapper SPA only; add CRM/FA SPA steps the same way.
