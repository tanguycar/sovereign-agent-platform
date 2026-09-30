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
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.bunker.id]
  }
  name = "fargate-compute-sg"
}

data "aws_ecs_cluster" "canary_cluster" {
  cluster_name = "air-gapped-cluster"
}

data "aws_iam_role" "ecs_execution_role" {
  name = "canary-execution-role"
}

data "aws_iam_role" "ecs_task_role" {
  name = "canary-task-role"
}

# --- 2. Gouvernance IAM (Step Functions) ---
resource "aws_iam_role" "stepfunctions_role" {
  name = "air-gapped-orchestrator-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "states.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy" "stepfunctions_policy" {
  name = "stepfunctions-ecs-sync-policy"
  role = aws_iam_role.stepfunctions_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow"
        Action = "ecs:RunTask"
        Resource = [
          "arn:aws:ecs:eu-west-3:*:task-definition/canary-agent-task:*",
          data.aws_ecs_cluster.canary_cluster.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeTasks",
          "ecs:StopTask"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          data.aws_iam_role.ecs_execution_role.arn,
          data.aws_iam_role.ecs_task_role.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "events:PutTargets",
          "events:PutRule",
          "events:DescribeRule"
        ]
        Resource = "arn:aws:events:eu-west-3:*:rule/StepFunctionsGetEventsForECSTaskRule"
      }
    ]
  })
}

# --- 3. State Machine (Orchestrateur) ---
resource "aws_sfn_state_machine" "orchestrator" {
  name     = "AgentOrchestrator"
  role_arn = aws_iam_role.stepfunctions_role.arn

  definition = jsonencode({
    Comment = "Orchestration Air-Gapped Agent"
    StartAt = "InvokeAgentFargateTask"
    States = {
      InvokeAgentFargateTask = {
        Type = "Task"
        Resource = "arn:aws:states:::ecs:runTask.sync"
        Parameters = {
          LaunchType = "FARGATE"
          Cluster    = data.aws_ecs_cluster.canary_cluster.arn
          TaskDefinition = "canary-agent-task"
          NetworkConfiguration = {
            AwsvpcConfiguration = {
              Subnets        = [data.aws_subnet.compute_subnet_a.id]
              SecurityGroups = [data.aws_security_group.compute_sg.id]
              AssignPublicIp = "DISABLED"
            }
          }
        }
        End = true
      }
    }
  })
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.orchestrator.arn
}