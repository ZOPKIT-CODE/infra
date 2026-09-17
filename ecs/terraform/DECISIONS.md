# Why the Terraform looks the way it does

The `.tf` files carry no comments — this file holds the reasoning that used to
live in them. Each entry records the file and the line it sat at when extracted.

**Read the entry before changing the thing it describes.** Several of these
record real incidents; the configuration they explain looks arbitrary or
needlessly restrictive until you know what it prevented.


## `environments/prod/backend.tf`

**~line 1**

> Root module for the prod environment.
>
> The backend key points at the state object the `prod` WORKSPACE already
> uses, so this directory ADOPTS the prod workspace's existing state object rather
> than migrating it. Terraform stores workspace state at "env:/<workspace>/<key>",
> which is just an S3 object key — nothing needs to be moved or re-imported.
>
> Do not run `terraform workspace select` here. The directory IS the environment.
>

## `environments/prod/main.tf`

**~line 63**

> ---------------------------------------------------------------------------
> Address migration: this directory adopts the state that the root module used
> to own, so every address gains a `module.stack.` prefix. Without these blocks
> Terraform reads all 65 resources as new and plans destroy+create.
>
> A single `moved` on a module address carries every resource inside it, which
> is why the 8 module entries cover far more than 8 resources.
>
> Keep these indefinitely — they are cheap, and they are the only record of how
> the pre-prod-directory state maps onto the current layout.
> ---------------------------------------------------------------------------
>

**~line 439**

> ---------------------------------------------------------------------------
> Second-generation moves: the six modules extracted from the flat root
> (observability, messaging, ci-oidc, bastion, db-admin, mathesar).
>
> These MUST live here, not inside modules/stack. A `moved` block resolves its
> addresses relative to the module that declares it, so the same block inside
> the stack would read `from` as module.stack.<addr> — an address state has
> never held — and every one of these resources would be planned for destroy.
> ---------------------------------------------------------------------------
>

## `environments/prod/providers.tf`

**~line 1**

> Provider configuration for this environment.
>
> - aws           : primary region (ECS, ALB, SNS/SQS, Cognito, Secrets Manager)
> - aws.us_east_1 : pinned us-east-1. CloudFront REQUIRES its ACM cert there.
> - aws.crm_data  : region for CRM/FA S3 + SES; defaults to primary.
>
> default_tags must stay byte-identical to what the stack previously set, or
> every resource in state shows a tag diff.
>

## `environments/prod/variables.tf`

**~line 114**

> Per-ENVIRONMENT service enablement. local.services carries one `enabled` flag
> shared by every workspace, which breaks as soon as an app lives in one env but
> not the other: prod demanded an SSM deployed-tag for lens-web (enabled=true
> globally, never deployed to prod) and `terraform plan` failed outright on the
> missing parameter. Set false here to make a service absent from THIS
> environment without touching the global default.
>

**~line 138**

> t4g.micro: the suite's auth/permission caches are tiny and low-traffic
> (~hundreds of ops/day, <1% CPU/mem observed on medium) — micro is ample
> headroom even for the full 6-app fleet. Downsized from t4g.medium 2026-06-10
> (~$119/mo saved across both envs).
>

## `environments/staging/backend.tf`

**~line 1**

> Root module for the staging environment.
>
> The backend key points at the state object the `default` WORKSPACE already
> uses, so this directory ADOPTS the default workspace's existing state object rather
> than migrating it. Terraform stores workspace state at "env:/<workspace>/<key>",
> which is just an S3 object key — nothing needs to be moved or re-imported.
>
> Do not run `terraform workspace select` here. The directory IS the environment.
>

## `environments/staging/main.tf`

**~line 63**

> ---------------------------------------------------------------------------
> Address migration: this directory adopts the state that the root module used
> to own, so every address gains a `module.stack.` prefix. Without these blocks
> Terraform reads all 65 resources as new and plans destroy+create.
>
> A single `moved` on a module address carries every resource inside it, which
> is why the 8 module entries cover far more than 8 resources.
>
> Keep these indefinitely — they are cheap, and they are the only record of how
> the pre-staging-directory state maps onto the current layout.
> ---------------------------------------------------------------------------
>

**~line 439**

> ---------------------------------------------------------------------------
> Second-generation moves: the six modules extracted from the flat root
> (observability, messaging, ci-oidc, bastion, db-admin, mathesar).
>
> These MUST live here, not inside modules/stack. A `moved` block resolves its
> addresses relative to the module that declares it, so the same block inside
> the stack would read `from` as module.stack.<addr> — an address state has
> never held — and every one of these resources would be planned for destroy.
> ---------------------------------------------------------------------------
>

## `environments/staging/providers.tf`

**~line 1**

> Provider configuration for this environment.
>
> - aws           : primary region (ECS, ALB, SNS/SQS, Cognito, Secrets Manager)
> - aws.us_east_1 : pinned us-east-1. CloudFront REQUIRES its ACM cert there.
> - aws.crm_data  : region for CRM/FA S3 + SES; defaults to primary.
>
> default_tags must stay byte-identical to what the stack previously set, or
> every resource in state shows a tag diff.
>

## `environments/staging/variables.tf`

**~line 114**

> Per-ENVIRONMENT service enablement. local.services carries one `enabled` flag
> shared by every workspace, which breaks as soon as an app lives in one env but
> not the other: prod demanded an SSM deployed-tag for lens-web (enabled=true
> globally, never deployed to prod) and `terraform plan` failed outright on the
> missing parameter. Set false here to make a service absent from THIS
> environment without touching the global default.
>

**~line 138**

> t4g.micro: the suite's auth/permission caches are tiny and low-traffic
> (~hundreds of ops/day, <1% CPU/mem observed on medium) — micro is ample
> headroom even for the full 6-app fleet. Downsized from t4g.medium 2026-06-10
> (~$119/mo saved across both envs).
>

## `modules/bastion/main.tf`

**~line 17**

> STANDARD AL2023 (NOT al2023-ami-minimal-*, which omits the SSM agent and
> never registers with Session Manager). The standard image ships + enables
> amazon-ssm-agent by default.
>

**~line 71**

> The bastion→RDS 5432 ingress lives INLINE on the RDS security group (rds.tf).
> It was previously a separate aws_security_group_rule here, which Terraform kept
> stripping on any apply that touched the SG (inline rules are treated as the
> complete set) — silently breaking every dev tunnel/MCP. Do not re-add it as a
> separate resource.
>

## `modules/ci-oidc/main.tf`

**~line 27**

> Match both the standard subject format (personal-account repos, e.g. ursrudra/zopkit-lens)
> and the ZOPKIT-CODE org's custom OIDC subject-claim template, which embeds numeric
> owner/repo IDs: "repo:ZOPKIT-CODE@<owner_id>/<repo>@<repo_id>:ref:...". Discovered via a
> temporary token-decode debug step after AssumeRoleWithWebIdentity kept failing for a newly
> trusted org repo - the plain "repo:${r}:*" pattern never matches the ID-suffixed form.
>

**~line 133**

> Infra-apply role — for the FULL `terraform apply` workflow (infra-apply.yml).
>
> The everyday deploy role above is least-privilege (ECS/ALB/frontend only) and
> its targeted apply never touches iam.tf/buckets/sns/etc. Full-stack changes
> (task-role grants, new buckets, ALB rules, Cognito, Valkey…) need broad infra
> perms, so they get a SEPARATE role assumable ONLY from the gated GitHub
> `infra-staging` / `infra-prod` environments (add required reviewers to those
> environments in repo settings — especially infra-prod). Created once (in the
> enable_ci_oidc=true workspace); referenced by both env workflows.
>

**~line 156**

> Assumable ONLY from a job pinned to the infra-* GitHub environments, so the
> environment's protection rules (required reviewers) gate every infra apply.
>
> BOTH repos are trusted during the IaC migration: infra-apply.yml still runs
> from ZOPKIT-CODE/Wrapper today and moves to ZOPKIT-CODE/infra once this
> policy is applied. Drop the Wrapper entries after the workflow has moved.
>
> The @*/…@* forms match the org's custom OIDC subject-claim template, which
> embeds numeric owner/repo IDs — see github_deploy_trust above. The plain
> form alone does NOT match for org repos using that template.
>

## `modules/ecs-service/main.tf`

**~line 115**

> 4. ECS service
>
> ignore_changes = [desired_count] is set unconditionally: it is safe for
> pinned services (Terraform still sets the initial count on create) and
> required for autoscaled services (so the appautoscaling-driven count is not
> reverted on every apply).
>

## `modules/mathesar/main.tf`

**~line 1**

> mathesar.tf — Mathesar (web DB UI) as an in-VPC ECS service.
>
> Reaches the RDS instance over the PRIVATE network (tasks SG → rds SG), so the DB
> is never publicly exposed. Team accesses Mathesar at https://db.<root_domain>
> (behind the shared ALB; wildcard cert covers it). Its own metadata lives in a
> `mathesar_django` database on the RDS instance (created out-of-band via the
> db-admin task). Gated by var.enabled.
>

**~line 124**

> Must out-prioritize the tenant_wildcard rule (priority 11, matches
> *.<root_domain> incl. db.<root_domain>) so db. routes to Mathesar, not wrapper.
>

## `modules/observability/main.tf`

**~line 1**

> CloudWatch log groups + the ops alarm SNS topic.
>
> Groups are created here rather than left to the awslogs driver's auto-create so
> the name, retention and tags are pinned, and so the execution role's
> CreateLogStream/PutLogEvents grant can target a known group.
>

## `modules/stack/alb.tf`

**~line 110**

> Wrapper tenant-vanity wildcard rule. The wrapper service must serve both
> api.<root> (its own module-created rule at priority 10) AND *.<root> tenant
> hosts. Rather than widen the module's host_header condition, attach a
> dedicated catch-all rule here forwarding *.<root> to wrapper's
> target group. (`aws_route53_record.tenant_wildcard` aliases *.<root> -> ALB.)
>
> PRIORITY MUST SIT AFTER EVERY APP RULE (wrapper 10 / crm 20 / fa 30): at its
> old value (11) the wildcard swallowed crm-api.<root>/accounting-api.<root>
> before their host rules could match — every CRM API call was answered by
> WRAPPER (broken CORS, wrong app) while crm-web sat healthy and unreachable.
>

## `modules/stack/bastion.tf`

**~line 11**

> currently disabled (enable_bastion = false), so these instances are already
> planned for destroy — the blocks keep that a clean destroy of the MOVED
> addresses rather than a destroy of the old plus a no-op create of the new.
> Re-exported so the root output surface is unchanged by the move.
>

## `modules/stack/ci-oidc.tf`

**~line 13**

> account-level singletons (the OIDC provider especially) — a destroy+create
> would break every repo's deploy workflow until the new provider exists. Keep
> these blocks indefinitely; they also carry the move into the `prod` workspace.
> Re-exported so the root output surface is unchanged by the move into the module.
>

## `modules/stack/cloudfront.tf`

**~line 20**

> SPA routing via edge function instead of custom_error_response, for apps that
> also proxy /api/* through this same distribution (cdn_proxies_api = true).
> custom_error_response (403/404 -> index.html) applies DISTRIBUTION-WIDE, not
> per-behavior - it was rewriting the backend's legitimate JSON 404s (e.g. "no
> site for this host") into the SPA HTML shell. Rewriting non-file request URIs
> to /index.html (or /gallery.html for /g/<token>) at viewer-request time, on
> the S3 default behavior only, means S3 never 404s for a real client route in
> the first place - so custom_error_response can be dropped for these apps
> entirely and the /api/* behavior's real error responses pass through untouched.
>

**~line 85**

> Backend ALB origin - only for apps whose frontend has no configurable API base URL and
> must reach /api/* same-origin (see local.apps[*].cdn_proxies_api). domain_name is the
> app's OWN api subdomain (not the raw ALB DNS name) so CloudFront's default custom-origin
> Host header matches the ALB listener rule's host_header condition for this app.
>

**~line 119**

> AWS managed "CachingDisabled" - API responses are dynamic, never cache.
>

## `modules/stack/cognito.tf`

**~line 1**

> cognito.tf — Cognito User Pool + hosted UI domain + per-app app clients.
> Single suite-wide user pool; one app client per app (wrapper|crm|fa).
> Pinned addresses (consumed by outputs.tf):
>   aws_cognito_user_pool.this
>   aws_cognito_user_pool_domain.this
>   aws_cognito_user_pool_client.clients[<app>]  (apps with cognito_client = true)
>

**~line 88**

> Opt-in per app. An adopted app can bring its own IdP (academy uses Google
> OAuth + Supabase), and creating a pool client it never calls is dead config
> that still shows up in every plan and audit.
>

**~line 111**

> Backend-mediated OAuth: the app builds redirect_uri = ${BACKEND_URL}/api/auth/callback
> and exchanges the code server-side, so the callback MUST be the API host (behind the
> ALB), not the CloudFront SPA host. The frontend host is kept as an allowed return target.
>

**~line 117**

> SPA-side PKCE (CRM login + the cross-app silent-SSO prompt=none flow):
> the browser exchanges the code itself; redirect_uri must byte-match.
>

## `modules/stack/delegation.tf`

**~line 1**

> delegation.tf
> When root_domain is a SUBdomain we CREATE for this environment (e.g.
> staging.zopkit.com via create_route53_zone=true), the new zone only resolves
> publicly if its PARENT zone (zopkit.com) delegates to it. Without this NS
> delegation, ACM DNS-validation never completes and no *.staging.zopkit.com
> hostname resolves. Skipped automatically for an apex/pre-existing zone.
>

## `modules/stack/ecr.tf`

**~line 10**

> Resolve repo URLs from whichever source is active, so consumers don't branch.
>

**~line 26**

> IMMUTABLE by default — that is what makes a rollback trustworthy and what the
> deploy pipeline's "tag already in ECR, skip the build" guard relies on.
>
> Per-repo opt-out for apps still publishing a MOVING tag. Adopting
> entertainment-erp-backend (which republishes :staging on every deploy) flipped
> it to IMMUTABLE and would have made its very next push fail — an immutable repo
> rejects a re-pushed tag. Onboarding order is: switch the app to git-SHA tags
> FIRST, then drop it from this set. See deploy/ecs/ONBOARDING.md, A1/A2.
>

**~line 46**

> Allow `terraform destroy` to remove repos that still contain images.
>

## `modules/stack/elasticache.tf`

**~line 67**

> Apply modifications (e.g. node_type resizes) as a rolling change NOW rather
> than silently deferring to the weekly maintenance window.
>

## `modules/stack/locals.tf`

**~line 1**

> Shared locals — the single source of truth referenced by every other .tf file.
> Resource naming convention: "${local.name_prefix}-<resource>", e.g.
> zopkit-staging-wrapper-events.
>
> Two separate contracts live here and must not be conflated:
>   local.apps     — per-application (wrapper, crm, fa, lens, academy,
>                    entertainment-erp). Drives Cognito clients, secrets, DNS.
>   local.services — per-ECS-service. Several services can share one app
>                    (crm-web + crm-worker both app = "crm").
>

**~line 31**

> lens's frontend does bare relative fetch("/api/...") calls with no configurable API base
> URL (unlike wrapper/crm/fa) - it MUST be same-origin, so its CloudFront distribution needs
> to proxy /api/* to the backend ALB. wrapper/crm/fa are deliberately left false: unclear
> whether their frontends rely on this and untested here - don't change their live behavior.
>

**~line 88**

> PROCESS_ROLE is set but READ BY NOTHING: b2b-crm's server.ts starts the
> Platform Bus SQS consumer, crmOutboxPoller, the DLQ drain, invitation-sync
> and the crons unconditionally, in every process. (server/src/app.ts:632
> describes a "PROCESS_ROLE gate" that was never implemented.) So this task
> runs the full background machinery, not just the API.
>

**~line 98**

> PINNED. This previously read `autoscaling_enabled = true # UNPINNED:
> outbox poller + SQS consumer moved to crm-worker` — a false premise, see
> above: nothing moved. A 2nd task means two SQS consumers on one queue and
> two outbox pollers (which have no SKIP-LOCKED claim). That duplicate
> consumption is the 2026-06-11 incident where a 4-copy tenant.onboarded
> batch drove concurrent bootstraps and corrupted a tenant's layouts.
> Unpin only after CRM leader-gates its pollers the way wrapper does
> (pg_try_advisory_lock).
>

**~line 122**

> DO NOT RUN THIS ALONGSIDE crm-web. Same image, no command override, and
> PROCESS_ROLE is read by nothing — so this is a second full copy of every
> consumer/poller crm-web already runs, not a complement to it. It is
> absent in staging and desired_count=0 in prod; both are correct today.
> It becomes meaningful only once b2b-crm actually implements the role gate.
>

**~line 204**

> ⚠ EXTERNALLY DEPLOYED — terraform does NOT own this service's running revision.
> academy ships from .github/workflows/deploy-dev-ecs.yml on its `dev` branch,
> which registers a task definition and calls update-service directly. Terraform
> tracks the surrounding infrastructure (target group, listener rule, log group,
> task role, secret, ECR repo) but its aws_ecs_service.task_definition will drift
> to whatever that pipeline last shipped.
>
> DO NOT `terraform apply` this service without checking the plan first: an apply
> sets task_definition back to the revision terraform knows, rolling the app back
> to an older image. The proper fix is ignore_changes = [task_definition], which
> needs a module change because ignore_changes cannot be driven by a variable.
>

**~line 337**

> An app is "live" when its <app>-web service is enabled (i.e. it has a prod
> backend + frontend). When dns_only_live_apps=true, the apex DNS records are
> created ONLY for live apps, so a partial-rollout env (e.g. prod with only
> wrapper deployed) never points crm./accounting. records at empty resources or
> clobbers another app's existing DNS. Default false preserves all-apps behavior.
>

**~line 417**

> Public blog crawler-HTML (blog-prerender.ts): siteOrigin/mediaOrigin for
> og:url/og:image must resolve to the public marketing site + API domain,
> not whatever Host header the request arrived with.
>

**~line 445**

> lens is a standalone app: SSO via the shared zopkit-platform Cognito pool (its own
> confidential app client, provisioned out-of-band — see backend/docs/COGNITO-SSO.md
> in the lens repo), own Stripe/Razorpay, no platform SNS/SQS bus. service_env_common's
> COGNITO_*/REDIS_ENABLED keys are harmless-but-unused (lens's code never reads them) —
> lens's own Cognito wiring (EXTERNAL_*) comes from its app secret, not from here.
>

**~line 496**

> Entertainment ERP: adopted, so this mirrors its live task definition. CORS is
> pinned to the literal prod hostname it is actually served on, not a derived one.
>

**~line 508**

> SECRETS injection (per app). Source ARNs:
>   - app secret  : aws_secretsmanager_secret.app[<app>].arn (keys = local.app_secret_keys[<app>], defined in secrets.tf)
>   - valkey secret: aws_secretsmanager_secret.valkey.arn   (we inject only REDIS_URL + REDIS_PASSWORD)
>
> DEDUP RULE: injected keys = (app_secret_keys[app] ∪ {REDIS_URL,REDIS_PASSWORD})
>             MINUS keys(service_env[app]). A key MUST NOT appear in both the
>             'environment' and 'secrets' blocks (ECS rejects duplicates). This
>             drops e.g. fa's CORS_ORIGINS (it lives in env) from its secrets.
> Empty when disabled: no app's task definition asks ECS to resolve a REDIS_URL/
> REDIS_PASSWORD secret that no longer exists (would otherwise fail every future
> task launch, not just lose caching).
>

## `modules/stack/marketing.tf`

**~line 1**

> marketing.tf — the frontend-marketing (www.zopkit.com / zopkit.com) CloudFront
> distribution. Created out-of-band during the marketing-site split
> (2026-07-25, no ManagedBy tag) and imported here so it can be safely extended
> with UA-based bot routing for blog link-preview unfurling (see the Lambda@Edge
> association below). Reuses the SAME shared OAC + ACM cert as the frontends
> in cloudfront.tf (confirmed live: OAC E14K2TOMA3ALDG = aws_cloudfront_origin_access_control.this,
> cert 821c5f70-... = aws_acm_certificate_validation.cloudfront) — this was
> built by hand to match the existing pattern, not created independently of it.
>

**~line 82**

> AWS managed "UserAgentRefererHeaders" - REQUIRED for the Lambda to see the
> real viewer User-Agent. CloudFront replaces User-Agent with the generic
> string "Amazon CloudFront" before origin-request fires unless a policy
> explicitly forwards it (learned the hard way testing this live - every
> request looked identical to the bot check without this). NOT
> AllViewerExceptHostHeader (the lens app's choice, and my first attempt
> here) - CloudFront rejects that for an S3 target origin: "Origin S3 Origins
> can only use the following managed request policies: CORS-CustomOrigin,
> CORS-S3Origin, UserAgentRefererHeaders." This behavior's default target
> IS the S3 origin (s3-fe_marketing), so the policy must be one of those
> three; this one is the only one that forwards User-Agent.
>

**~line 133**

> Lambda@Edge: origin-request bot router for /blog* (lambda/blog-bot-router).
> Must be created in us-east-1 (provider aws.us_east_1 - same alias already
> used for the CloudFront ACM cert in route53_acm.tf) and referenced by a
> PUBLISHED, QUALIFIED version ARN - CloudFront rejects $LATEST/aliases here.
>

## `modules/stack/mathesar.tf`

**~line 33**

> The two random_password resources are the dangerous ones — without a moved
> block Terraform would generate NEW values, silently rotating Mathesar's DB
> password and Django secret key away from what the running service holds.
> Re-exported so the root output surface is unchanged by the move.
>

## `modules/stack/messaging.tf`

**~line 10**

> ./modules/messaging. Without these blocks Terraform reads the new addresses as
> new resources and plans destroy+create — which for SQS means losing whatever
> is queued. Keep them indefinitely; they are also what makes the move land
> correctly in the `prod` workspace.
>

## `modules/stack/observability.tf`

**~line 10**

> ./modules/observability. Without these blocks Terraform reads the new
> addresses as new resources and plans destroy+create. Keep them indefinitely —
> they are also what makes the move land correctly in the `prod` workspace.
>

## `modules/stack/providers.tf`

**~line 1**

> Provider CONFIGURATION lives in the root module (environments/<env>/providers.tf).
> A shared module must not configure providers of its own — it receives them,
> including the aws.us_east_1 and aws.crm_data aliases declared in versions.tf.
>

## `modules/stack/rds.tf`

**~line 36**

> INLINE (not a separate aws_security_group_rule): this SG uses inline ingress
> blocks, and Terraform treats the inline set as COMPLETE — any rule managed as
> a separate resource is stripped by the next apply that touches this SG. That
> is exactly how the bastion rule silently vanished before (breaking every dev
> tunnel/MCP). Keep ALL ingress for this SG inline.
>

## `modules/stack/route53_acm.tf`

**~line 84**

> ###########################################
> DNS validation records
> ###########################################
> for_each MUST be keyed by a value known at plan time. domain_validation_options'
> resource_record_name is computed (unknown until apply) and cannot be a for_each
> key, but domain_name is static (var.root_domain + the wildcard SAN), so we key on
> that — the canonical ACM-DNS-validation pattern.
>
> Both certs (primary wildcard + us-east-1 cloudfront) request the IDENTICAL domain
> set, so ACM returns identical validation CNAMEs. We create ONE record set from the
> wildcard cert's options; the same records validate BOTH certs (referenced below).
> apex and *.apex share the same CNAME target, so allow_overwrite handles the dup.
>

**~line 124**

> Validate the us-east-1 (CloudFront) certificate. Validation must run through
> the us_east_1 provider since the certificate lives there.
>

## `modules/stack/s3.tf`

**~line 1**

> s3.tf — Object storage buckets for the Zopkit suite.
>
> Buckets (from local.s3_buckets):
>   claim_check       — large SNS/SQS payload offload (claim-check pattern)
>   wrapper_logos     — wrapper tenant/org logo uploads
>   crm_attachments   — CRM record attachments (browser direct upload via CORS)
>   fa_receipts       — finance-accounting receipt uploads (browser direct upload via CORS)
>   ses_inbound       — raw inbound email objects written by the SES receipt rule
>   fe_wrapper        — wrapper SPA static assets (served via CloudFront)
>   fe_crm            — CRM SPA static assets (served via CloudFront)
>   fe_fa             — finance-accounting SPA static assets (served via CloudFront)
>
> All buckets are created under the DEFAULT provider (single region) to satisfy
> the pinned address aws_s3_bucket.buckets[<k>]. To split CRM/FA data storage into
> var.data_region, move crm_attachments/fa_receipts to provider = aws.crm_data
> (e.g. via a separate for_each over the data-region keys) and adjust outputs.tf.
>
> Conventions: block ALL public access, versioning Enabled, SSE AES256.
> Frontend bucket policies are intentionally NOT defined here — cloudfront.tf owns
> those (Origin Access Control grant).
>

## `modules/stack/secrets.tf`

**~line 1**

> ###############################################################################
> secrets.tf — Per-app AWS Secrets Manager secrets (one per suite app)
>
> Each app gets a single JSON secret at `${var.project}/${var.environment}/<app>`
> (e.g. zopkit/prod/wrapper). The values authored here are PLACEHOLDERS only —
> every key is set to "REPLACE_ME". Operators MUST populate the real values
> BEFORE the first task starts; ECS injects them into the container via the task
> definition's `secrets` block (valueFrom = "<secret arn>:<KEY>::"), so values
> never appear in the task's plain environment, in plans, or in state.
>
> AWS credentials are intentionally NOT included here — the per-app ECS TASK role
> (aws_iam_role.task, see iam.tf) provides the container's AWS access at runtime.
>
> The `lifecycle { ignore_changes = [secret_string] }` block ensures Terraform
> never clobbers operator-populated values on subsequent applies.
> ###############################################################################
>

**~line 25**

> Privileged migrator role URL — used ONLY by the one-off `run-migrations.js`
> task (reads MIGRATION_DATABASE_URL first). On least-privilege RDS, DATABASE_URL
> (app_user) is DML-only and cannot create/own __drizzle_migrations, so the
> migration must run as the migrator role. The long-running app ignores this key.
>

**~line 97**

> Academy's secret already exists (zopkit/staging/academy) and is imported, not
> created. These are the keys it actually holds — read from the live secret, so
> the placeholder document Terraform would write matches its real shape. Values
> are never touched: ignore_changes = [secret_string] on the version below.
>
> Adopting it replaces the hand-written AWS description, which recorded:
>   "Academy backend secrets (manual ECS deploy, dev branch). DATABASE_URL
>    points at the shared production Supabase DB per explicit user decision."
> Keeping that here because it is the more important half: academy's
> DATABASE_URL is deliberately pointed at the shared PRODUCTION Supabase
> database, not a staging one.
>

## `modules/stack/services.tf`

**~line 7**

> The deployed tag for each service lives in SSM Parameter Store
> (/<project>/<env>/deployed-tag/<service>), written by every release path
> BEFORE its apply (CI deploy.yml, deploy-service.sh). Terraform reads the
> LIVE value at plan time, so unrelated applies can never roll a service back
> to a stale tag. Git holds no tag record anymore: the old
> image-tags.auto.tfvars.json went stale silently (dispatched releases could
> not push to the protected main) and a secrets roll downgraded staging CRM
> four commits (2026-06-12). Bootstrap of a brand-new service: create the
> parameter first (the deploy paths do) or pass -var='service_image_tags={...}'.
>

## `modules/stack/variables.tf`

**~line 114**

> Per-ENVIRONMENT service enablement. local.services carries one `enabled` flag
> shared by every workspace, which breaks as soon as an app lives in one env but
> not the other: prod demanded an SSM deployed-tag for lens-web (enabled=true
> globally, never deployed to prod) and `terraform plan` failed outright on the
> missing parameter. Set false here to make a service absent from THIS
> environment without touching the global default.
>

**~line 138**

> t4g.micro: the suite's auth/permission caches are tiny and low-traffic
> (~hundreds of ops/day, <1% CPU/mem observed on medium) — micro is ample
> headroom even for the full 6-app fleet. Downsized from t4g.medium 2026-06-10
> (~$119/mo saved across both envs).
>
