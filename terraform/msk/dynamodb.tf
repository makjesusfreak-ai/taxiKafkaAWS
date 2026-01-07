# DynamoDB Tables for Historical Data and Delta Sync

# Main events table for historical data
resource "aws_dynamodb_table" "events_table" {
  name         = "${var.cluster_name}-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  attribute {
    name = "topic"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "N"
  }

  attribute {
    name = "DOLocationID"
    type = "N"
  }

  attribute {
    name = "pickup_datetime"
    type = "S"
  }

  # GSI for querying by topic and time range
  global_secondary_index {
    name            = "topic-timestamp-index"
    hash_key        = "topic"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  # GSI for querying by pk (LOC#<PULocationID>) and timestamp
  global_secondary_index {
    name            = "pickup-location-timestamp-index"
    hash_key        = "pk"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  # GSI for querying by dropoff location and pickup datetime
  global_secondary_index {
    name            = "dropoff-location-index"
    hash_key        = "DOLocationID"
    range_key       = "pickup_datetime"
    projection_type = "ALL"
  }

  # TTL for automatic cleanup
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  # Enable DynamoDB Streams for Delta Sync
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  tags = {
    Name        = "${var.cluster_name}-events"
    Environment = var.environment
  }
}

# Delta Sync table for tracking changes
resource "aws_dynamodb_table" "delta_sync_table" {
  name         = "${var.cluster_name}-delta-sync"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ds_pk"
  range_key    = "ds_sk"

  attribute {
    name = "ds_pk"
    type = "S"
  }

  attribute {
    name = "ds_sk"
    type = "S"
  }

  # TTL for automatic cleanup of delta records
  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = {
    Name        = "${var.cluster_name}-delta-sync"
    Environment = var.environment
  }
}

# IAM Policy for Lambda to access DynamoDB
resource "aws_iam_role_policy" "lambda_dynamodb_policy" {
  name = "${var.cluster_name}-lambda-dynamodb-policy"
  role = aws_iam_role.lambda_msk_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:BatchWriteItem",
          "dynamodb:UpdateItem",
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = [
          aws_dynamodb_table.events_table.arn,
          "${aws_dynamodb_table.events_table.arn}/index/*",
          aws_dynamodb_table.delta_sync_table.arn,
          "${aws_dynamodb_table.delta_sync_table.arn}/index/*"
        ]
      }
    ]
  })
}
