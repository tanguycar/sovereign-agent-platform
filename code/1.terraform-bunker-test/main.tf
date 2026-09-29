provider "aws" {
  region = "eu-west-3" # Paris
}

# 1. Le Bunker (VPC Isolé sans IGW ni NAT)
resource "aws_vpc" "air_gapped_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.air_gapped_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "eu-west-3a"
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.air_gapped_vpc.id
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_rt.id
}

# 2. Security Group (Autorise uniquement le HTTPS interne)
resource "aws_security_group" "vpc_endpoints_sg" {
  name   = "vpc-endpoints-sg"
  vpc_id = aws_vpc.air_gapped_vpc.id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.air_gapped_vpc.cidr_block]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 3. S3 Gateway Endpoint
resource "aws_vpc_endpoint" "s3_gateway" {
  vpc_id            = aws_vpc.air_gapped_vpc.id
  service_name      = "com.amazonaws.eu-west-3.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private_rt.id]
}

# 4. Interface Endpoints (Payants - Bedrock + terminaux SSM pour la connexion)
locals {
  endpoints = ["bedrock-runtime", "ssm", "ssmmessages", "ec2messages"]
}

resource "aws_vpc_endpoint" "interfaces" {
  for_each            = toset(local.endpoints)
  vpc_id              = aws_vpc.air_gapped_vpc.id
  service_name        = "com.amazonaws.eu-west-3.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private_subnet.id]
  security_group_ids  = [aws_security_group.vpc_endpoints_sg.id]
  private_dns_enabled = true
}

# 5. Rôle IAM & Instance EC2 de Test (Le Canari)
resource "aws_iam_role" "ssm_role" {
  name = "ssm-test-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "s3_list_policy" {
  name = "allow-list-all-buckets"
  role = aws_iam_role.ssm_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = "s3:ListAllMyBuckets",
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_policy" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "ssm-test-profile"
  role = aws_iam_role.ssm_role.name
}

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

resource "aws_instance" "canary_test" {
  ami                  = data.aws_ami.amazon_linux_2023.id
  instance_type        = "t2.micro" # Couvert par le Free Tier
  subnet_id            = aws_subnet.private_subnet.id
  iam_instance_profile = aws_iam_instance_profile.ssm_profile.name
  depends_on           = [aws_vpc_endpoint.interfaces]
  tags = { Name = "Canary-Test-Air-Gapped" }
}