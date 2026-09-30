provider "aws" {
  region = "eu-west-3"
}

# --- 1. Récupération du Bunker (Strict) ---
data "aws_vpc" "bunker" {
  tags = { Name = "Air-Gapped-VPC" }
}

data "aws_subnet" "compute_subnet_a" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.bunker.id]
  }
  tags = { Name = "Compute-Subnet-A" }
}

data "aws_security_group" "compute_sg" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.bunker.id]
  }
  name = "fargate-compute-sg"
}

# --- 2. Gouvernance (KMS & Secrets Manager) ---
resource "aws_kms_key" "agent_cmk" {
  description             = "CMK for Canary Agent Secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_secretsmanager_secret" "canary_secret" {
  name                    = "agent/canary/api-token"
  kms_key_id              = aws_kms_key.agent_cmk.id
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "canary_secret_val" {
  secret_id     = aws_secretsmanager_secret.canary_secret.id
  secret_string = jsonencode({ "dummy_token" : "AIR_GAPPED_SUCCESS_42" })
}

# --- 3. Registre & Logs ---
resource "aws_ecr_repository" "canary_repo" {
  name                 = "canary-agent"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "aws_cloudwatch_log_group" "canary_logs" {
  name              = "/ecs/canary-agent"
  retention_in_days = 1
}

# --- 4. Rôles IAM (Moindre Privilège Stricte) ---
resource "aws_iam_role" "ecs_execution_role" {
  name = "canary-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "ecs_execution_custom_policy" {
  name = "canary-execution-policy"
  role = aws_iam_role.ecs_execution_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      { Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"], Resource = aws_ecr_repository.canary_repo.arn },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.canary_logs.arn}:*" }
    ]
  })
}

resource "aws_iam_role" "ecs_task_role" {
  name = "canary-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "canary_task_policy" {
  name = "canary-task-policy"
  role = aws_iam_role.ecs_task_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = aws_secretsmanager_secret.canary_secret.arn },
      { Effect = "Allow", Action = "kms:Decrypt", Resource = aws_kms_key.agent_cmk.arn },
      { Effect = "Allow", Action = "bedrock:InvokeModel", Resource = "arn:aws:bedrock:eu-west-3::foundation-model/mistral.mistral-large-2402-v1:0" }
    ]
  })
}

# --- 5. Compute ---
resource "aws_ecs_cluster" "canary_cluster" {
  name = "air-gapped-cluster"
}

resource "aws_ecs_task_definition" "canary_task" {
  family                   = "canary-agent-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([{
    name      = "canary-container"
    image     = "${aws_ecr_repository.canary_repo.repository_url}:latest"
    essential = true
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.canary_logs.name
        "awslogs-region"        = "eu-west-3"
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

# --- Outputs pour le script de déploiement (aws ecs run-task) ---
output "repository_url" { value = aws_ecr_repository.canary_repo.repository_url }
output "cluster_name" { value = aws_ecs_cluster.canary_cluster.name }
output "task_family" { value = aws_ecs_task_definition.canary_task.family }
output "subnet_id" { value = data.aws_subnet.compute_subnet_a.id }
output "security_group_id" { value = data.aws_security_group.compute_sg.id }