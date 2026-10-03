provider "aws" {
  region = "eu-west-3"
}

# --- 1. Importation du Contexte ---
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
  name = "fargate-compute-sg"
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.bunker.id]
  }
}

resource "aws_iam_role" "remediation_exec_role" {
  name = "remediation-exec-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "remediation_exec_policy" {
  name = "remediation-exec-policy"
  role = aws_iam_role.remediation_exec_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
      { Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"], Resource = aws_ecr_repository.remediation_repo.arn },
      { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "${aws_cloudwatch_log_group.remediation_logs.arn}:*" }
    ]
  })
}

data "aws_kms_key" "agent_cmk" {
  key_id = "alias/agent-cmk"
}

# --- 2. S3 Target Sink (Le système cible ségrégué) ---
resource "aws_s3_bucket" "target_is" {
  bucket_prefix = "remediation-target-is-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "target_is_block" {
  bucket                  = aws_s3_bucket.target_is.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- 3. Vulnerability Context (Secrets Manager) ---
resource "aws_secretsmanager_secret" "vuln_report" {
  name                    = "agent/remediation/vuln-report"
  kms_key_id              = data.aws_kms_key.agent_cmk.id
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "vuln_report_val" {
  secret_id     = aws_secretsmanager_secret.vuln_report.id
  secret_string = jsonencode({ "cve" : "CVE-2026-9999", "code" : "eval(user_input)" })
}

# --- 4. IAM Moindre Privilège (Amputation de Bedrock) ---
resource "aws_iam_role" "remediation_task_role" {
  name = "remediation-task-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ecs-tasks.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "remediation_task_policy" {
  name = "remediation-task-policy"
  role = aws_iam_role.remediation_task_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      { Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = aws_secretsmanager_secret.vuln_report.arn },
      { Effect = "Allow", Action = "kms:Decrypt", Resource = data.aws_kms_key.agent_cmk.arn },
      { Effect = "Allow", Action = "s3:PutObject", Resource = "${aws_s3_bucket.target_is.arn}/*" }
      # NOTE RED TEAM: Aucune permission bedrock:InvokeModel n'est accordée ici. 
      # L'Agent sera refusé par l'API AWS s'il tente de contourner le Proxy.
    ]
  })
}

resource "aws_s3_bucket_policy" "target_is_policy" {
  bucket = aws_s3_bucket.target_is.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = { AWS = aws_iam_role.remediation_task_role.arn },
        Action = "s3:PutObject",
        Resource = "${aws_s3_bucket.target_is.arn}/*",
        Condition = {
          StringEquals = { "aws:sourceVpc" = data.aws_vpc.bunker.id }
        }
      }
    ]
  })
}

# --- 5. Registre et Déploiement Fargate ---
resource "aws_ecr_repository" "remediation_repo" {
  name                 = "remediation-agent"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "aws_cloudwatch_log_group" "remediation_logs" {
  name              = "/ecs/remediation-agent"
  retention_in_days = 1
}

resource "aws_ecs_task_definition" "remediation_task" {
  family                   = "remediation-agent-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.remediation_exec_role.arn
  task_role_arn            = aws_iam_role.remediation_task_role.arn

  container_definitions = jsonencode([{
    name      = "remediation-container"
    image     = "${aws_ecr_repository.remediation_repo.repository_url}:latest"
    essential = true
    environment = [
      { name = "LLM_PROXY_URL", value = "http://llm-proxy.airgap.local:4000" },
      { name = "TARGET_S3_BUCKET", value = aws_s3_bucket.target_is.bucket },
      { name = "SECRET_ARN", value = aws_secretsmanager_secret.vuln_report.arn }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.remediation_logs.name
        "awslogs-region"        = "eu-west-3"
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

output "repository_url" { value = aws_ecr_repository.remediation_repo.repository_url }
output "task_family" { value = aws_ecs_task_definition.remediation_task.family }
output "target_bucket" { value = aws_s3_bucket.target_is.id }