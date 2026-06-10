# Architecture — Zopkit Suite on AWS (ECS Fargate)

Visual guide for developers. Operational steps: [`PLAYBOOK.md`](./PLAYBOOK.md).  
**Current environment:** `zopkit-staging` · account `207567767101` · `us-east-1` · `staging.zopkit.com`

> **Compute:** ECS Fargate (not EKS). Three apps (wrapper / crm / fa); **only wrapper is live** in staging — crm/fa are defined but `enabled=false`.

---

## 1. Two doors into the product

Every user hits **two separate paths**. They never merge in the network — only in the browser (the SPA calls the API).

```mermaid
flowchart TB
  user((User browser))

  subgraph door1["Door 1 — Website (static files)"]
    direction TB
    host1["app.staging.zopkit.com"]
    cf["CloudFront<br/>TLS ACM"]
    s3["S3 bucket<br/>private SPA files<br/>OAC signed access"]
    host1 --> cf --> s3
  end

  subgraph door2["Door 2 — API (live backend)"]
    direction TB
    host2["api.staging.zopkit.com"]
    r53["Route53 A-record"]
    alb["ALB shared<br/>HTTPS :443"]
    task["Fargate task wrapper-web<br/>container :3000"]
    host2 --> r53 --> alb --> task
  end

  user -->|"open app"| host1
  user -->|"API + login"| host2
```

| Path | Hostname | What happens |
|------|----------|--------------|
| **Frontend** | `app.staging.zopkit.com` | CloudFront → private S3. HTML/JS/CSS only. **Does not enter the VPC.** |
| **Backend** | `api.staging.zopkit.com` | Route53 → ALB → Fargate container. Handles auth, DB, events, files. |

After the SPA loads from CloudFront, the browser calls `https://api.staging.zopkit.com/...` for data and login.

---

## 2. API path — inside the VPC

Staging VPC: **`10.43.0.0/16`**, **2 AZs**, **no NAT gateway** (tasks use public IPs for outbound).

```mermaid
flowchart TB
  internet((Internet))

  subgraph vpc["AWS VPC 10.43.0.0/16"]
    igw["Internet Gateway"]

    subgraph public["Public subnets — per AZ"]
      alb["Application Load Balancer<br/>SG: allow 443 from Internet<br/>rule: api.* → wrapper-web TG"]
      fargate["Fargate task wrapper-web<br/>public subnet + public IP<br/>SG: allow :3000 from ALB only<br/>egress: all via IGW"]
      alb -->|"forward :3000"| fargate
    end

    subgraph private["Private subnets — per AZ"]
      valkey[("ElastiCache Valkey<br/>cache.t4g.micro")]
    end

    igw <--> internet
    igw <--> alb
    fargate -->|"6379"| valkey
    fargate -->|"outbound"| igw
  end

  internet -->|"HTTPS :443"| alb
```

**Security model (the important part):**

| Resource | Who can reach it |
|----------|------------------|
| **ALB** | Internet on port **443** |
| **Fargate task** | **Only the ALB** on port 3000 — not the Internet directly |
| **Valkey** | **Only Fargate tasks** on port 6379 |
| **Public IP on task** | Used for **outbound** (ECR pull, Supabase, AWS APIs) — inbound is blocked by SG |

**Why no NAT in staging:** cheaper. Tasks sit in **public subnets** with a public IP and egress via IGW. Production should use **private subnets + NAT** (`fargate_assign_public_ip = false`).

**Other services (crm-web, fa-web, fa-consumer):** defined in Terraform, `enabled=false` until you roll them out.

---

## 3. What the API talks to (outside the VPC)

```mermaid
flowchart LR
  api["Fargate wrapper-web"]

  db[("Supabase Postgres<br/>IPv4 pooler")]
  msg["SNS to SQS<br/>16 queues + DLQs"]
  auth["Cognito<br/>login + Google"]
  media[("S3 dev bucket<br/>logos / blog media")]
  secrets["Secrets Manager<br/>DB URL JWT Sentry etc"]

  api --> db
  api --> msg
  api --> auth
  api --> media
  api --> secrets
```

| Service | Purpose in staging |
|---------|-------------------|
| **Supabase** | Shared **dev** Postgres via pooler (`aws-0-ap-south-1.pooler.supabase.com`) |
| **SNS → SQS** | Event bus to CRM/FA (queues exist; consumers deploy later) |
| **Cognito** | Shared pool `zopkit-platform` + Google OAuth |
| **S3** | Shared dev bucket `wrapper-tenant-logos` |
| **Secrets Manager** | Injected into task at runtime — never baked into Docker image |

---

## 4. End-to-end (one picture)

```mermaid
flowchart TB
  user((User))

  subgraph edge["Edge — no VPC"]
    cf["CloudFront"]
    s3spa["S3 SPA"]
    cf --> s3spa
  end

  subgraph vpc["VPC"]
    alb["ALB"]
    ecs["ECS Fargate wrapper-web"]
    valkey[("Valkey")]
    alb --> ecs
    ecs --> valkey
  end

  subgraph aws["AWS + external"]
    cognito["Cognito"]
    supa[("Supabase")]
    sns["SNS/SQS"]
    s3data["S3 media"]
    sm["Secrets Manager"]
  end

  user -->|"app.staging..."| cf
  user -->|"api.staging..."| alb
  ecs --> cognito
  ecs --> supa
  ecs --> sns
  ecs --> s3data
  ecs --> sm
```

---

## 5. Deployment flow

```mermaid
flowchart LR
  subgraph once["One-time per environment"]
    tf["terraform apply"]
    sec["Populate Secrets Manager"]
    tf --> sec
  end

  subgraph each["Every app deploy"]
    b["1 BUILD docker amd64"]
    p["2 PUSH ECR git-SHA"]
    r["3 RELEASE terraform target"]
    m["4 MIGRATE one-off Fargate task"]
    w["5 WAIT ECS stable"]
    s["6 SMOKE curl /health"]
    b --> p --> r --> m --> w --> s
  end

  subgraph fe["Frontend separately"]
    v["vite build"]
    sync["s3 sync"]
    inv["CloudFront invalidation"]
    v --> sync --> inv
  end
```

**One command for backend:** `./deploy/ecs/deploy-service.sh wrapper-web`

**Rollback:** re-run deploy steps 1–5 with a **previous git SHA** (ECR tags are immutable).

---

## 6. Suite rollout order

```mermaid
flowchart LR
  w["wrapper<br/>live"]
  c["crm<br/>next"]
  f["fa<br/>then"]
  w -->|"events buffer in SQS"| c --> f
```

Wrapper owns tenants, login, credits. CRM/FA consume its events. Their queues already exist.

**Add an app:** `enabled=true` in tfvars → `terraform apply` → `deploy-service.sh <svc>` → deploy that app's frontend.

---

## 7. Login flow

```mermaid
sequenceDiagram
  participant B as Browser
  participant API as api.staging.zopkit.com
  participant C as Cognito
  participant G as Google

  B->>API: GET /api/auth/oauth/login
  API-->>B: 302 redirect
  B->>C: OAuth authorize
  C->>G: Google sign-in
  G-->>C: user approved
  C-->>B: redirect to callback
  B->>API: GET /api/auth/callback
  API-->>B: Set .zopkit.com cookie + redirect to app.staging
```

**Rule:** auth always goes to the **API host** (`api.…`), not relative `/api` (relative only works locally via Vite proxy).

---

## 8. Staging facts (quick reference)

| Item | Value |
|------|-------|
| Domain | `staging.zopkit.com` |
| VPC CIDR | `10.43.0.0/16` (2 AZs, NAT-less) |
| ECS cluster | `zopkit-staging-ecs` |
| Running service | `zopkit-staging-wrapper-web` (1 task) |
| Frontend | `app.staging.zopkit.com` → CloudFront `E34U1BABF6H31O` → S3 `zopkit-staging-wrapper-fe` |
| API | `api.staging.zopkit.com` → ALB → Fargate `:3000` |
| DB | Dev Supabase (IPv4 pooler) |
| Auth | Cognito `us-east-1_6e8AY4eMj` + Google |
| Messaging | SNS ×3 → SQS ×16 (+ DLQs) |
| Tracing | Sentry org `zopkit-cg` |

---

## 9. Glossary

| Term | Meaning |
|------|---------|
| **ECR** | Docker image registry |
| **ECS / Fargate** | Runs containers without managing EC2 |
| **ALB** | Load balancer; routes `api.…` by hostname to the right task |
| **Task definition** | Container recipe (image + env + secrets). **Service** keeps N tasks running. |
| **VPC / subnet / SG** | Private network / AZ slices / per-resource firewall |
| **IGW / NAT** | Internet Gateway (public subnet in/out) / NAT (private subnet outbound only) |
| **CloudFront + OAC** | CDN + signed access to private S3 |
| **SNS → SQS** | Publish once, many queues receive; DLQ catches failures |
| **Secrets Manager** | Secrets injected at task start |
| **Terraform** | Infrastructure as code; `terraform apply` updates AWS |

---

## Related docs

- **Deploy steps:** [`ecs/terraform/README.md`](./ecs/terraform/README.md)
- **Full suite (EKS alternative, unused):** older `deploy/terraform/` EKS stack — left untouched; ECS is the active path.
