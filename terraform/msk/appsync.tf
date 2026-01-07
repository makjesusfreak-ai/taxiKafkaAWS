# AWS AppSync Event API configuration

# AppSync Event API
resource "aws_appsync_api" "events_api" {
  name = "${var.cluster_name}-events-api"

  event_config {
    auth_providers {
      auth_type = var.appsync_auth_type

      dynamic "cognito_config" {
        for_each = var.appsync_auth_type == "AMAZON_COGNITO_USER_POOLS" ? [1] : []
        content {
          user_pool_id = var.cognito_user_pool_id
          aws_region   = var.aws_region
        }
      }
    }

    # Connection authentication
    connection_auth_modes {
      auth_type = var.appsync_auth_type
    }

    # Default publish authentication
    default_publish_auth_modes {
      auth_type = var.appsync_auth_type
    }

    # Default subscribe authentication
    default_subscribe_auth_modes {
      auth_type = var.appsync_auth_type
    }
  }

  tags = {
    Name        = "${var.cluster_name}-events-api"
    Environment = var.environment
  }
}

# AppSync API Key (if using API_KEY auth)
resource "aws_appsync_api_key" "events_api_key" {
  count   = var.appsync_auth_type == "API_KEY" ? 1 : 0
  api_id  = aws_appsync_api.events_api.id
  expires = timeadd(timestamp(), "${var.appsync_api_key_expiry_days * 24}h")

  lifecycle {
    ignore_changes = [expires]
  }
}

# AppSync Channel Namespace for Kafka topics
resource "aws_appsync_channel_namespace" "kafka_namespace" {
  api_id = aws_appsync_api.events_api.id
  name   = "kafka"

  # Publish auth modes
  publish_auth_modes {
    auth_type = var.appsync_auth_type
  }

  # Subscribe auth modes  
  subscribe_auth_modes {
    auth_type = var.appsync_auth_type
  }

  tags = {
    Name        = "${var.cluster_name}-kafka-namespace"
    Environment = var.environment
  }
}

# Additional channel namespace for taxi events (specific to your use case)
resource "aws_appsync_channel_namespace" "taxi_namespace" {
  api_id = aws_appsync_api.events_api.id
  name   = "taxi"

  # Publish auth modes
  publish_auth_modes {
    auth_type = var.appsync_auth_type
  }

  # Subscribe auth modes
  subscribe_auth_modes {
    auth_type = var.appsync_auth_type
  }

  tags = {
    Name        = "${var.cluster_name}-taxi-namespace"
    Environment = var.environment
  }
}

# IAM Role for AppSync logging
resource "aws_iam_role" "appsync_logs_role" {
  name = "${var.cluster_name}-appsync-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "appsync.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.cluster_name}-appsync-logs-role"
    Environment = var.environment
  }
}

# IAM Policy for AppSync CloudWatch logs
resource "aws_iam_role_policy" "appsync_logs_policy" {
  name = "${var.cluster_name}-appsync-logs-policy"
  role = aws_iam_role.appsync_logs_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/appsync/*"
      }
    ]
  })
}

# CloudWatch Log Group for AppSync
resource "aws_cloudwatch_log_group" "appsync_log_group" {
  name              = "/aws/appsync/apis/${aws_appsync_api.events_api.id}"
  retention_in_days = var.log_retention_days

  tags = {
    Name        = "${var.cluster_name}-appsync-logs"
    Environment = var.environment
  }
}
