###############################################################################
# Cluster add-ons installed with Helm:
#   - AWS Load Balancer Controller (IRSA)
#   - External Secrets Operator (IRSA -> Secrets Manager)
#   - Metrics Server (HPA source)
#   - gp3 StorageClass (default)
#   - ArgoCD (optional, install it once per cluster)
###############################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name = "${var.project}-${var.environment}"
}

# --------------------------------------------------------------------------- #
# AWS Load Balancer Controller
# --------------------------------------------------------------------------- #
module "alb_irsa" {
  source = "../irsa"

  role_name          = "${local.name}-alb-controller"
  description        = "AWS Load Balancer Controller"
  oidc_provider_arn  = var.oidc_provider_arn
  oidc_provider_url  = var.oidc_provider_url
  service_accounts   = ["kube-system:aws-load-balancer-controller"]
  inline_policy_json = file("${path.module}/policies/alb-controller.json")
  tags               = var.tags
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.alb_controller_chart_version
  namespace  = "kube-system"
  atomic     = true
  timeout    = 600

  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  set {
    name  = "region"
    value = data.aws_region.current.name
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.alb_irsa.role_arn
  }

  set {
    name  = "enableServiceMutatorWebhook"
    value = "false"
  }

  set {
    name  = "replicaCount"
    value = var.high_availability ? "2" : "1"
  }
}

# --------------------------------------------------------------------------- #
# External Secrets Operator
# --------------------------------------------------------------------------- #
data "aws_iam_policy_document" "external_secrets" {
  statement {
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecretVersionIds",
    ]

    resources = [
      "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.secrets_prefix}*",
    ]
  }

  statement {
    effect  = "Allow"
    actions = ["secretsmanager:ListSecrets"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]

    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/${var.secrets_prefix}*",
    ]
  }
}

module "external_secrets_irsa" {
  source = "../irsa"

  role_name         = "${local.name}-external-secrets"
  description       = "External Secrets Operator -> AWS Secrets Manager"
  oidc_provider_arn = var.oidc_provider_arn
  oidc_provider_url = var.oidc_provider_url

  service_accounts = [
    "external-secrets:external-secrets",
    "${var.app_namespace}:${var.project}-external-secrets",
  ]

  inline_policy_json = data.aws_iam_policy_document.external_secrets.json
  tags               = var.tags
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.external_secrets_chart_version
  namespace        = "external-secrets"
  create_namespace = true
  atomic           = true
  timeout          = 600

  set {
    name  = "installCRDs"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "external-secrets"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.external_secrets_irsa.role_arn
  }

  set {
    name  = "webhook.replicaCount"
    value = var.high_availability ? "2" : "1"
  }

  set {
    name  = "replicaCount"
    value = var.high_availability ? "2" : "1"
  }
}

# --------------------------------------------------------------------------- #
# Metrics Server (required by every HPA in the Roboshop charts)
# --------------------------------------------------------------------------- #
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_chart_version
  namespace  = "kube-system"
  atomic     = true
  timeout    = 300

  set {
    name  = "args[0]"
    value = "--kubelet-preferred-address-types=InternalIP\\,Hostname\\,ExternalIP"
  }

  set {
    name  = "resources.requests.cpu"
    value = "50m"
  }

  set {
    name  = "resources.requests.memory"
    value = "128Mi"
  }
}

# --------------------------------------------------------------------------- #
# Default gp3 StorageClass (EBS CSI add-on is installed by the eks module)
# --------------------------------------------------------------------------- #
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Retain"

  parameters = {
    type      = "gp3"
    encrypted = "true"
    fsType    = "ext4"
  }
}

# --------------------------------------------------------------------------- #
# ArgoCD (GitOps control plane)
# --------------------------------------------------------------------------- #
resource "helm_release" "argocd" {
  count = var.install_argocd ? 1 : 0

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true
  atomic           = true
  timeout          = 900

  values = [yamlencode({
    global = {
      domain = var.argocd_domain
    }
    configs = {
      params = {
        "server.insecure" = true
      }
      cm = {
        "timeout.reconciliation" = "180s"
        "application.resourceTrackingMethod" = "annotation"
      }
    }
    controller = {
      replicas = var.high_availability ? 2 : 1
    }
    repoServer = {
      replicas = var.high_availability ? 2 : 1
    }
    server = {
      replicas = var.high_availability ? 2 : 1
      service = {
        type = "ClusterIP"
      }
    }
    applicationSet = {
      replicas = 1
    }
    redis_ha = {
      enabled = var.high_availability
    }
  })]

  depends_on = [helm_release.alb_controller]
}
