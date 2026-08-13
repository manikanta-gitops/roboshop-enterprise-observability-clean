project            = "roboshop"
region             = "us-east-1"
vpc_cidr           = "10.20.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]
kubernetes_version = "1.35"
app_namespace      = "roboshop-production"

github_org  = "manikanta-gitops"
github_repo = "roboshop-enterprise"

endpoint_public_access = false
public_access_cidrs    = []
argocd_domain          = "argocd.example.com"
