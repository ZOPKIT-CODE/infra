# ---------------------------------------------------------------------------
# Cluster add-ons (Helm) + the ExternalSecrets ClusterSecretStore.
#
# Installs the in-cluster controllers the workloads depend on:
#   1. aws-load-balancer-controller  -> provisions the shared ALB from Ingress.
#   2. external-dns                  -> manages Route53 records from Ingress/Service
#                                       (api.*, crm-api.*, accounting-api.*, *.zopkit.com).
#   3. external-secrets (ESO)        -> syncs Secrets Manager -> k8s Secrets.
#   4. metrics-server                -> Resource metrics for the wrapper HPA.
#   5. ClusterSecretStore            -> the ESO backend pointing at Secrets Manager.
#
# Every helm_release depends_on module.eks so the node group / API server exist
# before the chart installs. IRSA role ARNs come from iam_irsa.tf. The k8s/helm
# providers authenticate via `aws eks get-token` (see providers.tf); on the very
# first run, bootstrap the cluster first (terraform apply -target=module.eks)
# per the README "Apply order".
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 1. AWS Load Balancer Controller — turns Ingress objects into a shared ALB.
#    The IRSA role (lb_controller_irsa) carries elasticloadbalancing/ec2 perms.
# ---------------------------------------------------------------------------
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.8.1" # pin for reproducibility; bump deliberately
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "region"
    value = var.aws_region
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  # Dots inside the annotation key must be escaped so Helm treats it as a single key.
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.lb_controller_irsa.iam_role_arn
  }

  depends_on = [module.eks]
}

# ---------------------------------------------------------------------------
# 2. external-dns — reconciles Route53 from Ingress/Service hostnames.
#    policy=upsert-only never deletes records it did not create. txtOwnerId
#    scopes ownership TXT records to this cluster. domainFilters limits it to
#    the suite root domain. external-dns owns api/*-api/wildcard records; the
#    SPA apex records (app/crm/accounting) are managed by Terraform/CloudFront.
# ---------------------------------------------------------------------------
resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns"
  chart      = "external-dns"
  version    = "1.15.0"
  namespace  = "kube-system"

  set {
    name  = "provider"
    value = "aws"
  }
  set {
    name  = "policy"
    value = "upsert-only"
  }
  set {
    name  = "txtOwnerId"
    value = local.name_prefix
  }
  set {
    name  = "domainFilters[0]"
    value = var.root_domain
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "external-dns"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_dns_irsa.iam_role_arn
  }

  depends_on = [module.eks]
}

# ---------------------------------------------------------------------------
# 3. external-secrets (ESO) — installs the controller + CRDs into its own
#    namespace. The CRDs it installs (ExternalSecret, ClusterSecretStore) are
#    consumed by the ClusterSecretStore below and by the Helm chart's
#    externalsecret.yaml template.
# ---------------------------------------------------------------------------
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.10.4" # serves external-secrets.io/v1beta1 (the CRD the chart uses)
  namespace        = "external-secrets"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "external-secrets"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_secrets_irsa.iam_role_arn
  }

  depends_on = [module.eks]
}

# ---------------------------------------------------------------------------
# 4. metrics-server — provides resource metrics (CPU/mem) for the wrapper HPA.
#    crm/fa keep HPA disabled (leader-unsafe), but the wrapper Deployment scales.
# ---------------------------------------------------------------------------
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server"
  chart      = "metrics-server"
  version    = "3.12.1"
  namespace  = "kube-system"

  depends_on = [module.eks]
}

# ---------------------------------------------------------------------------
# 5. ClusterSecretStore "aws-secretsmanager" — the ESO backend that the chart's
#    ExternalSecrets reference (externalSecret.secretStoreRef). It authenticates
#    to Secrets Manager via the external-secrets controller's IRSA service
#    account (no static creds).
#
#    NOTE: kubernetes_manifest is parsed/validated by the provider at PLAN time,
#    which requires the ExternalSecrets CRDs to ALREADY exist in the cluster. They
#    are installed by the external_secrets helm_release above, so the very first
#    apply cannot create both in one pass. It is therefore gated behind
#    var.enable_cluster_secret_store (default false): leave it false on the first
#    apply, then set it true on the second apply once ESO is installed.
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "cluster_secret_store" {
  count = var.enable_cluster_secret_store ? 1 : 0

  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ClusterSecretStore"
    metadata = {
      name = "aws-secretsmanager"
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
          auth = {
            jwt = {
              serviceAccountRef = {
                name      = "external-secrets"
                namespace = "external-secrets"
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.external_secrets]
}
