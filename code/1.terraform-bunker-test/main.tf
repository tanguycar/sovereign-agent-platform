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

# Subnet unique pour le test (limitation des coûts des Endpoints par AZ), 
# mais prêt pour l'extension Multi-AZ.
resource "aws_subnet" "private_subnet_a" {
  vpc_id            = aws_vpc.air_gapped_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "eu-west-3a"
  tags = { Name = "Private-Subnet-A" }
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.air_gapped_vpc.id
}

resource "aws_route_table_association" "private_assoc_a" {
  subnet_id      = aws_subnet.private_subnet_a.id
  route_table_id = aws_route_table.private_rt.id
}

# 2. Security Group Hermétique (Zero-Trust)
# Récupération dynamique de la Prefix List S3 de la région
data "aws_prefix_list" "s3" {
  name = "com.amazonaws.eu-west-3.s3"
}

resource "aws_security_group" "vpc_endpoints_sg" {
  name        = "vpc-endpoints-strict-sg"
  description = "Allow HTTPS internal and S3 Gateway traffic"
  vpc_id      = aws_vpc.air_gapped_vpc.id
  
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.air_gapped_vpc.cidr_block]
  }
  
  # Egress vers le VPC (pour joindre les Interface Endpoints)
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.air_gapped_vpc.cidr_block]
  }

  # Egress vers S3 (VITAL pour que le S3 Gateway Endpoint fonctionne)
  egress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [data.aws_prefix_list.s3.id]
  }
}

# 3. S3 Gateway Endpoint (Vital pour tirer les couches de l'image ECR depuis Fargate)
resource "aws_vpc_endpoint" "s3_gateway" {
  vpc_id            = aws_vpc.air_gapped_vpc.id
  service_name      = "com.amazonaws.eu-west-3.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private_rt.id]
}

# 4. Interface Endpoints Cibles (Ce dont Fargate et l'Agent ont REELLEMENT besoin)
locals {
  target_endpoints = [
    "ecr.api",           # Pull image Fargate
    "ecr.dkr",           # Pull image Fargate
    "logs",              # CloudWatch Logs (indispensable pour débugger l'agent)
    "secretsmanager",    # Récupération du jeton
    "kms",               # Déchiffrement du secret
    "bedrock-runtime"    # Inférence IA
  ]
}

resource "aws_vpc_endpoint" "interfaces" {
  for_each            = toset(local.target_endpoints)
  vpc_id              = aws_vpc.air_gapped_vpc.id
  service_name        = "com.amazonaws.eu-west-3.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_subnet_a.id]
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
  private_dns_enabled = true
}