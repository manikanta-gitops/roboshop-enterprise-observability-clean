project = "roboshop"

region = "ap-south-1"

vpc_cidr = "10.10.0.0/16"

availability_zones = [
  "ap-south-1a",
  "ap-south-1b",
  "ap-south-1c"
]

kubernetes_version = "1.35"

app_namespace = "roboshop-dev"

github_org  = "manikanta-gitops"
github_repo = "roboshop-enterprise-observability-clean"

# Immutable GitHub OIDC subject IDs (from the verified token sub claim).
github_org_id  = "311366158"
github_repo_id = "1332791563"

create_github_oidc_provider = true

argocd_domain = "argocd.streanzo.online"

public_access_cidrs = [
  "0.0.0.0/0"
]
