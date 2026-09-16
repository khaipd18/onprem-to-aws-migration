resource "aws_security_group" "alb_public" {
  name        = "${var.name_prefix}-sg-alb-public"
  description = "Public application load balancer"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-sg-alb-public" }
}

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-sg-app"
  description = "Application tier instances and workers"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-sg-app" }
}

resource "aws_security_group" "rds_proxy" {
  name        = "${var.name_prefix}-sg-rds-proxy"
  description = "RDS Proxy endpoint"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-sg-rds-proxy" }
}

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-sg-rds"
  description = "RDS PostgreSQL instances"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-sg-rds" }
}

resource "aws_security_group" "fileserver" {
  name        = "${var.name_prefix}-sg-fileserver"
  description = "Shared file server"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-sg-fileserver" }
}

resource "aws_security_group" "admin_client" {
  name        = "${var.name_prefix}-sg-admin-client"
  description = "Administrative workstation and DataSync agent. Carries no inbound rules, it exists to be referenced as a source."
  vpc_id      = var.vpc_id

  tags = { Name = "${var.name_prefix}-sg-admin-client" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_public_http" {
  security_group_id = aws_security_group.alb_public.id
  description       = "Port 80 from 0.0.0.0/0"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80

  tags = { Name = "${var.name_prefix}-alb-public-http-0.0.0.0/0" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_public_https" {
  security_group_id = aws_security_group.alb_public.id
  description       = "Port 443 from 0.0.0.0/0"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443

  tags = { Name = "${var.name_prefix}-alb-public-https-0.0.0.0/0" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb_public" {
  security_group_id            = aws_security_group.app.id
  description                  = "Application traffic from the public load balancer"
  referenced_security_group_id = aws_security_group.alb_public.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080

  tags = { Name = "${var.name_prefix}-app-from-alb-public" }
}

resource "aws_vpc_security_group_ingress_rule" "rds_proxy_from_app" {
  security_group_id            = aws_security_group.rds_proxy.id
  description                  = "PostgreSQL from the application tier"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432

  tags = { Name = "${var.name_prefix}-rds-proxy-from-app" }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_proxy" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL from the database proxy"
  referenced_security_group_id = aws_security_group.rds_proxy.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432

  tags = { Name = "${var.name_prefix}-rds-from-proxy" }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_app" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL direct from the application tier, fallback if the proxy is unavailable"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432

  tags = { Name = "${var.name_prefix}-rds-from-app" }
}

resource "aws_vpc_security_group_ingress_rule" "fileserver_from_app" {
  security_group_id            = aws_security_group.fileserver.id
  description                  = "NFS file access from app"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049

  tags = { Name = "${var.name_prefix}-fileserver-nfs-from-app" }
}

resource "aws_vpc_security_group_ingress_rule" "fileserver_from_admin_client" {
  security_group_id            = aws_security_group.fileserver.id
  description                  = "NFS file access from admin_client"
  referenced_security_group_id = aws_security_group.admin_client.id
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049

  tags = { Name = "${var.name_prefix}-fileserver-nfs-from-admin_client" }
}

resource "aws_vpc_security_group_egress_rule" "allow_all" {
  for_each = {
    alb-public   = aws_security_group.alb_public.id
    app          = aws_security_group.app.id
    rds-proxy    = aws_security_group.rds_proxy.id
    rds          = aws_security_group.rds.id
    fileserver   = aws_security_group.fileserver.id
    admin-client = aws_security_group.admin_client.id
  }

  security_group_id = each.value
  description       = "All outbound traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"

  tags = { Name = "${var.name_prefix}-${each.key}-egress-all" }
}
