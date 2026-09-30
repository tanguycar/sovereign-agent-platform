provider "aws" {
  region = "eu-west-3"
}

# 1. Le Bunker (VPC Isolé)
resource "aws_vpc" "air_gapped_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "Air-Gapped-VPC" }
}

# 2. Ségrégation des sous-réseaux (Multi-AZ & Préparation Firewall)
resource "aws_subnet" "compute_subnet_a" {
  vpc_id            = aws_vpc.air_gapped_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "eu-west-3a"
  tags = { Name = "Compute-Subnet-A" }
}

resource "aws_subnet" "compute_subnet_b" {
  vpc_id            = aws_vpc.air_gapped_vpc.id
  cidr_block        = "10.0.5.0/24"
  availability_zone = "eu-west-3b"
  tags = { Name = "Compute-Subnet-B" }
}

resource "aws_subnet" "endpoints_subnet_a" {
  vpc_id            = aws_vpc.air_gapped_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "eu-west-3a"
  tags = { Name = "Endpoints-Subnet-A" }
}

resource "aws_subnet" "endpoints_subnet_b" {
  vpc_id            = aws_vpc.air_gapped_vpc.id
  cidr_block        = "10.0.6.0/24"
  availability_zone = "eu-west-3b"
  tags = { Name = "Endpoints-Subnet-B" }
}

resource "aws_subnet" "gateway_subnet_a" {
  vpc_id            = aws_vpc.air_gapped_vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "eu-west-3a"
  tags = { Name = "Gateway-Subnet-A" }
}

resource "aws_subnet" "gateway_subnet_b" {
  vpc_id            = aws_vpc.air_gapped_vpc.id
  cidr_block        = "10.0.7.0/24"
  availability_zone = "eu-west-3b"
  tags = { Name = "Gateway-Subnet-B" }
}

# Tables de routage découplées pour insertion future de l'ANFW
resource "aws_route_table" "compute_rt" {
  vpc_id = aws_vpc.air_gapped_vpc.id
  tags = { Name = "Compute-RT" }
}

resource "aws_route_table" "endpoints_rt" {
  vpc_id = aws_vpc.air_gapped_vpc.id
  tags = { Name = "Endpoints-RT" }
}

resource "aws_route_table" "gateway_rt" {
  vpc_id = aws_vpc.air_gapped_vpc.id
  tags = { Name = "Gateway-RT" }
}

resource "aws_route_table_association" "compute_assoc_a" {
  subnet_id      = aws_subnet.compute_subnet_a.id
  route_table_id = aws_route_table.compute_rt.id
}

resource "aws_route_table_association" "compute_assoc_b" {
  subnet_id      = aws_subnet.compute_subnet_b.id
  route_table_id = aws_route_table.compute_rt.id
}

resource "aws_route_table_association" "endpoints_assoc_a" {
  subnet_id      = aws_subnet.endpoints_subnet_a.id
  route_table_id = aws_route_table.endpoints_rt.id
}

resource "aws_route_table_association" "endpoints_assoc_b" {
  subnet_id      = aws_subnet.endpoints_subnet_b.id
  route_table_id = aws_route_table.endpoints_rt.id
}

resource "aws_route_table_association" "gateway_assoc_a" {
  subnet_id      = aws_subnet.gateway_subnet_a.id
  route_table_id = aws_route_table.gateway_rt.id
}

resource "aws_route_table_association" "gateway_assoc_b" {
  subnet_id      = aws_subnet.gateway_subnet_b.id
  route_table_id = aws_route_table.gateway_rt.id
}

# 3. Security Groups (Zero-Trust)
data "aws_prefix_list" "s3" {
  name = "com.amazonaws.eu-west-3.s3"
}

resource "aws_security_group" "compute_sg" {
  name        = "fargate-compute-sg"
  description = "Strict egress for Fargate Canary"
  vpc_id      = aws_vpc.air_gapped_vpc.id
}

resource "aws_security_group" "endpoints_sg" {
  name        = "vpc-endpoints-sg"
  description = "Allow inbound from Compute SG only"
  vpc_id      = aws_vpc.air_gapped_vpc.id
  
  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.compute_sg.id]
  }
}

resource "aws_security_group_rule" "compute_egress_endpoints" {
  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.compute_sg.id
  source_security_group_id = aws_security_group.endpoints_sg.id
}

resource "aws_security_group_rule" "compute_egress_s3" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.compute_sg.id
  prefix_list_ids   = [data.aws_prefix_list.s3.id]
}

# 4. Endpoints
resource "aws_vpc_endpoint" "s3_gateway" {
  vpc_id            = aws_vpc.air_gapped_vpc.id
  service_name      = "com.amazonaws.eu-west-3.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.compute_rt.id, aws_route_table.endpoints_rt.id, aws_route_table.gateway_rt.id]
}

locals {
  target_endpoints = [
    "ecr.api", "ecr.dkr", "logs", "secretsmanager", "kms", "bedrock-runtime", "aoss"
  ]
}

resource "aws_vpc_endpoint" "interfaces" {
  for_each            = toset(local.target_endpoints)
  vpc_id              = aws_vpc.air_gapped_vpc.id
  service_name        = "com.amazonaws.eu-west-3.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.endpoints_subnet_a.id, aws_subnet.endpoints_subnet_b.id]
  security_group_ids  = [aws_security_group.endpoints_sg.id]
  private_dns_enabled = true
  timeouts {
    delete = "45m"
  }
}