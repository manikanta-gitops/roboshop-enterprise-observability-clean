###############################################################################
# Security groups shared by the platform:
#   - alb: internet-facing ALBs created by the AWS Load Balancer Controller
#   - node_extra: attached to worker nodes for ALB -> pod traffic
#   - datastore: in-VPC access to managed datastores if you move off StatefulSets
###############################################################################

locals {
  name = "${var.project}-${var.environment}"
}

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Internet-facing ALB for Roboshop ingress"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${local.name}-alb" })
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from ${each.value}"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "All outbound to targets"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "node_extra" {
  name        = "${local.name}-node-extra"
  description = "Extra rules for Roboshop worker nodes"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${local.name}-node-extra" })
}

resource "aws_vpc_security_group_ingress_rule" "node_from_alb" {
  security_group_id            = aws_security_group.node_extra.id
  description                  = "NodePort / target group traffic from the ALB"
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 1024
  to_port                      = 65535
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node_extra.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "datastore" {
  count = var.create_datastore_sg ? 1 : 0

  name        = "${local.name}-datastore"
  description = "Managed datastore access from inside the VPC"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${local.name}-datastore" })
}

resource "aws_vpc_security_group_ingress_rule" "datastore_from_nodes" {
  for_each = var.create_datastore_sg ? toset([for p in var.datastore_ports : tostring(p)]) : toset([])

  security_group_id            = aws_security_group.datastore[0].id
  description                  = "Port ${each.value} from worker nodes"
  referenced_security_group_id = aws_security_group.node_extra.id
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  ip_protocol                  = "tcp"
}
