provider "aws" {
  region = "eu-west-3"
}

# --- 1. Contexte du Bunker ---
data "aws_vpc" "bunker" {
  tags = { Name = "Air-Gapped-VPC" }
}

data "aws_subnet" "gateway_subnet_a" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.bunker.id]
  }
  tags = { Name = "Gateway-Subnet-A" }
}

data "aws_subnet" "gateway_subnet_b" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.bunker.id]
  }
  tags = { Name = "Gateway-Subnet-B" }
}

data "aws_security_group" "compute_sg" { name = "fargate-compute-sg" }
data "aws_security_group" "endpoints_sg" { name = "vpc-endpoints-sg" }

# --- 2. Micro-segmentation & Security Groups (Zero Trust Chaining) ---
resource "aws_security_group" "gateway_sg" {
  name        = "llm-gateway-sg"
  description = "SG for Internal LLM Gateway Proxy"
  vpc_id      = data.aws_vpc.bunker.id
}

resource "aws_security_group" "redis_sg" {
  name        = "elasticache-redis-sg"
  description = "SG for Semantic Cache"
  vpc_id      = data.aws_vpc.bunker.id
}

# L'Agent (Compute) attaque le Gateway Proxy (port 4000)
resource "aws_security_group_rule" "compute_to_gateway_egress" {
  type                     = "egress"
  from_port                = 4000
  to_port                  = 4000
  protocol                 = "tcp"
  security_group_id        = data.aws_security_group.compute_sg.id
  source_security_group_id = aws_security_group.gateway_sg.id
}

resource "aws_security_group_rule" "gateway_ingress_compute" {
  type                     = "ingress"
  from_port                = 4000
  to_port                  = 4000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.gateway_sg.id
  source_security_group_id = data.aws_security_group.compute_sg.id
}

# Le Gateway Proxy joint Redis (port 6379)
resource "aws_security_group_rule" "gateway_to_redis_egress" {
  type                     = "egress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.gateway_sg.id
  source_security_group_id = aws_security_group.redis_sg.id
}

resource "aws_security_group_rule" "redis_ingress_gateway" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.redis_sg.id
  source_security_group_id = aws_security_group.gateway_sg.id
}

# Le Gateway Proxy accède aux Endpoints AWS (Bedrock/Secrets/S3)
resource "aws_security_group_rule" "gateway_to_endpoints_egress" {
  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.gateway_sg.id
  source_security_group_id = data.aws_security_group.endpoints_sg.id
}

resource "aws_security_group_rule" "endpoints_ingress_gateway" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = data.aws_security_group.endpoints_sg.id
  source_security_group_id = aws_security_group.gateway_sg.id
}

# --- 3. ElastiCache (Semantic Cache Guardrail) ---
resource "aws_elasticache_subnet_group" "redis_subnets" {
  name       = "redis-guardrail-subnets"
  subnet_ids = [data.aws_subnet.gateway_subnet_a.id, data.aws_subnet.gateway_subnet_b.id]
}

resource "aws_elasticache_cluster" "semantic_cache" {
  cluster_id           = "llm-semantic-cache"
  engine               = "redis"
  node_type            = "cache.t4g.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  engine_version       = "7.1"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.redis_subnets.name
  security_group_ids   = [aws_security_group.redis_sg.id]
}

# --- 4. LLM Gateway Proxy (Fargate Service) ---
resource "aws_ecr_repository" "gateway_repo" {
  name                 = "llm-gateway-proxy"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "aws_cloudwatch_log_group" "gateway_logs" {
  name              = "/ecs/llm-gateway-proxy"
  retention_in_days = 1
}

resource "aws_ecs_cluster" "gateway_cluster" {
  name = "guardrails-cluster"
}

resource "aws_iam_role" "gateway_task_role" {
  name = "gateway-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "gateway_bedrock_policy" {
  name = "gateway-bedrock-policy"
  role = aws_iam_role.gateway_task_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Effect = "Allow", Action = "bedrock:InvokeModel", Resource = "*" }]
  })
}

resource "aws_iam_role" "gateway_exec_role" {
  name = "gateway-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "gateway_exec_attach" {
  role       = aws_iam_role.gateway_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_ecs_task_definition" "gateway_task" {
  family                   = "llm-gateway-proxy-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.gateway_exec_role.arn
  task_role_arn            = aws_iam_role.gateway_task_role.arn

  container_definitions = jsonencode([{
    name      = "litellm-proxy"
    image     = "${aws_ecr_repository.gateway_repo.repository_url}:latest"
    essential = true
    portMappings = [{ containerPort = 4000, protocol = "tcp" }]
    environment = [
      { name = "REDIS_HOST", value = aws_elasticache_cluster.semantic_cache.cache_nodes[0].address },
      { name = "REDIS_PORT", value = "6379" }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.gateway_logs.name
        "awslogs-region"        = "eu-west-3"
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "gateway_service" {
  name            = "llm-gateway-service"
  cluster         = aws_ecs_cluster.gateway_cluster.id
  task_definition = aws_ecs_task_definition.gateway_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [data.aws_subnet.gateway_subnet_a.id, data.aws_subnet.gateway_subnet_b.id]
    security_groups  = [aws_security_group.gateway_sg.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.gateway.arn
  }
}

# --- 5. AWS Network Firewall (Egress Préparation) ---
resource "aws_networkfirewall_rule_group" "drop_all" {
  capacity = 100
  name     = "strict-egress-drop"
  type     = "STATEFUL"
  rule_group {
    rules_source {
      stateful_rule {
        action = "DROP"
        header {
          destination      = "ANY"
          destination_port = "ANY"
          direction        = "ANY"
          protocol         = "IP"
          source           = "ANY"
          source_port      = "ANY"
        }
        rule_option { keyword = "sid:1" }
      }
    }
  }
}

resource "aws_networkfirewall_firewall_policy" "fw_policy" {
  name = "air-gapped-fw-policy"
  firewall_policy {
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]
    stateful_rule_group_reference {
      resource_arn = aws_networkfirewall_rule_group.drop_all.arn
    }
  }
}

resource "aws_networkfirewall_firewall" "anfw" {
  name                = "air-gapped-anfw"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.fw_policy.arn
  vpc_id              = data.aws_vpc.bunker.id
  subnet_mapping { subnet_id = data.aws_subnet.gateway_subnet_a.id }
  subnet_mapping { subnet_id = data.aws_subnet.gateway_subnet_b.id }
}

output "gateway_repo_url" { value = aws_ecr_repository.gateway_repo.repository_url }
output "redis_endpoint" { value = aws_elasticache_cluster.semantic_cache.cache_nodes[0].address }

# --- 6. Service Discovery (Cloud Map) ---
resource "aws_service_discovery_private_dns_namespace" "internal" {
  name        = "airgap.local"
  vpc         = data.aws_vpc.bunker.id
  description = "Internal DNS for Air-Gapped Proxy"
}

resource "aws_service_discovery_service" "gateway" {
  name = "llm-proxy"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.internal.id
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
}