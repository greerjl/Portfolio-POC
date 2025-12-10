### Terraform main configuration file ###

# Local variables
locals {
  default_tags = {
    Project     = "Portfolio-POC"
    Environment = var.env
  }
}

## Terraform data sources for AWS
data "aws_caller_identity" "this" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ecr_repository" "ecr_repo" {
  name = var.ecr_repo_name
}

## Terraform resources for AWS
resource "aws_iam_role" "iam_role_ecs_task_execution" {
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect    = "Allow",
        Principal = { Service = "ecs-tasks.amazonaws.com" },
        Action    = "sts:AssumeRole"
      }
    ]
  })
  name = "${var.name}-ecs-task-execution-role"
}

resource "aws_iam_role_policy" "ssm_read_parameters_policy" {
  name = "ssm-read-parameters-policy"
  role = aws_iam_role.iam_role_ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ],
        Resource = ["*"]
      }
    ]
  })

}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy_attachment" {
  role       = aws_iam_role.iam_role_ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "cloudwatch_logs_group" {
  name              = "/ecs/${var.name}-${var.env}-logs"
  retention_in_days = 7
}

resource "aws_ecs_cluster" "ecs_cluster" {
  name = "${var.name}-${var.env}-cluster"
}

resource "aws_ecs_task_definition" "ecs_task_definition" {
  family                   = "${var.name}-${var.env}-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"

  # Execution role must have: AmazonECSTaskExecutionRolePolicy + SSM read for the collector secret
  execution_role_arn = aws_iam_role.iam_role_ecs_task_execution.arn

  # (Optional) If your app needs AWS APIs at runtime, set a task role here:
  # task_role_arn          = aws_iam_role.app_task_role.arn

  container_definitions = jsonencode([
    // ===== App container =====
    {
      name      = "${var.name}-container"
      image     = var.image
      essential = true

      # Start after the collector is healthy
      dependsOn = [
        { containerName = "otel-collector", condition = "HEALTHY" }
      ]

      # Start the app through the OTel launcher so env vars are honored
      command = ["sh", "-lc", "opentelemetry-instrument python app.py"]

      portMappings = [
        {
          containerPort = var.container_port
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.cloudwatch_logs_group.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "${var.name}"
        }
      }

      environment = [
        # helpful bump so every apply creates a new task def revision
        { name = "CONFIG_VERSION", value = formatdate("YYYYMMDDhhmmss", timestamp()) },

        { name = "ENVIRONMENT", value = var.env },
        { name = "OTEL_SERVICE_NAME", value = "app-demo" },
        { name = "OTEL_RESOURCE_ATTRIBUTES", value = "deployment.environment=${var.env}" },

        # Traces via OTLP HTTP to the sidecar (not localhost):
        { name = "OTEL_TRACES_EXPORTER", value = "otlp" },
        { name = "OTEL_EXPORTER_OTLP_PROTOCOL", value = "http/protobuf" },
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://otel-collector:4318" },
        { name = "OTEL_EXPORTER_OTLP_TRACES_PROTOCOL", value = "http/protobuf" },
        { name = "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", value = "http://otel-collector:4318" },

        # Optional while debugging to reduce noise:
        { name = "OTEL_METRICS_EXPORTER", value = "none" }
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:${var.container_port}/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }
    },

    // ===== ADOT Collector sidecar =====
    {
      name      = "otel-collector"
      image     = "public.ecr.aws/aws-observability/aws-otel-collector:latest"
      essential = false
      cpu       = 128
      memory    = 256

      # awsvpc mode: only containerPort needed; no hostPort mapping required
      portMappings = [
        { containerPort = 4317, protocol = "tcp" }, # OTLP gRPC (kept open if you switch later)
        { containerPort = 4318, protocol = "tcp" }, # OTLP HTTP (used now)
        { containerPort = 13133, protocol = "tcp" } # health endpoint
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "curl -fsS http://localhost:13133/health || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 10
      }

      # SSM-injected ADOT config (must include otlp http/grpc receivers and health_check)
      secrets = [
        {
          name      = "AOT_CONFIG_CONTENT"
          valueFrom = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.this.account_id}:parameter/otel/${var.env}/config"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/app-demo-${var.env}-logs"
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "otel-collector"
        }
      }

      environment = [
        { name = "AWS_REGION", value = var.aws_region }
      ]
    }
  ])
}

resource "aws_security_group" "ecs_security_group" {
  name        = "${var.name}-${var.env}-sg"
  description = "Security group for ECS tasks"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_service" "ecs_service" {
  name            = "${var.name}-${var.env}-service"
  cluster         = aws_ecs_cluster.ecs_cluster.id
  task_definition = aws_ecs_task_definition.ecs_task_definition.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    assign_public_ip = true
    security_groups  = [aws_security_group.ecs_security_group.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.ecs_task_execution_role_policy_attachment
  ]
}