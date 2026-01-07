# AWS Glue Schema Registry configuration for MSK

# Glue Schema Registry
resource "aws_glue_registry" "msk_registry" {
  registry_name = "${var.cluster_name}-registry"
  description   = "Schema Registry for ${var.cluster_name} MSK cluster"

  tags = {
    Name        = "${var.cluster_name}-registry"
    Environment = var.environment
  }
}

# Schema for taxi rides topic
resource "aws_glue_schema" "taxi_rides_schema" {
  count = var.create_default_schemas ? 1 : 0

  schema_name       = "taxi-rides"
  registry_arn      = aws_glue_registry.msk_registry.arn
  data_format       = var.schema_data_format
  compatibility     = var.schema_compatibility
  description       = "Schema for taxi ride events"

  schema_definition = jsonencode({
    type      = "record"
    name      = "TaxiRide"
    namespace = "com.taxi.events"
    fields = [
      { name = "ride_id", type = "string" },
      { name = "timestamp", type = "long" },
      { name = "pickup_latitude", type = "double" },
      { name = "pickup_longitude", type = "double" },
      { name = "dropoff_latitude", type = "double" },
      { name = "dropoff_longitude", type = "double" },
      { name = "passenger_count", type = "int" },
      { name = "fare_amount", type = ["null", "double"], default = null },
      { name = "driver_id", type = "string" },
      { name = "status", type = { type = "enum", name = "RideStatus", symbols = ["REQUESTED", "ACCEPTED", "IN_PROGRESS", "COMPLETED", "CANCELLED"] } }
    ]
  })

  tags = {
    Name        = "taxi-rides-schema"
    Environment = var.environment
  }
}

# Schema for taxi locations topic
resource "aws_glue_schema" "taxi_locations_schema" {
  count = var.create_default_schemas ? 1 : 0

  schema_name       = "taxi-locations"
  registry_arn      = aws_glue_registry.msk_registry.arn
  data_format       = var.schema_data_format
  compatibility     = var.schema_compatibility
  description       = "Schema for taxi location updates"

  schema_definition = jsonencode({
    type      = "record"
    name      = "TaxiLocation"
    namespace = "com.taxi.events"
    fields = [
      { name = "vehicle_id", type = "string" },
      { name = "timestamp", type = "long" },
      { name = "latitude", type = "double" },
      { name = "longitude", type = "double" },
      { name = "speed", type = ["null", "double"], default = null },
      { name = "heading", type = ["null", "double"], default = null },
      { name = "accuracy", type = ["null", "double"], default = null },
      { name = "driver_id", type = "string" },
      { name = "availability", type = { type = "enum", name = "AvailabilityStatus", symbols = ["AVAILABLE", "BUSY", "OFFLINE"] } }
    ]
  })

  tags = {
    Name        = "taxi-locations-schema"
    Environment = var.environment
  }
}

# IAM Policy for Schema Registry access (for producers/consumers)
resource "aws_iam_policy" "glue_schema_registry_policy" {
  name        = "${var.cluster_name}-glue-schema-registry-policy"
  description = "Policy for accessing Glue Schema Registry with auto-registration"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "glue:GetRegistry",
          "glue:ListRegistries",
          "glue:GetSchema",
          "glue:ListSchemas",
          "glue:GetSchemaVersion",
          "glue:ListSchemaVersions",
          "glue:GetSchemaByDefinition",
          "glue:GetSchemaVersionsDiff"
        ]
        Resource = [
          aws_glue_registry.msk_registry.arn,
          "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schema/${aws_glue_registry.msk_registry.registry_name}/*"
        ]
      },
      {
        # Auto-registration permissions - allows creating schemas on first message
        Effect = "Allow"
        Action = [
          "glue:CreateSchema",
          "glue:RegisterSchemaVersion",
          "glue:PutSchemaVersionMetadata"
        ]
        Resource = [
          aws_glue_registry.msk_registry.arn,
          "arn:aws:glue:${var.aws_region}:${data.aws_caller_identity.current.account_id}:schema/${aws_glue_registry.msk_registry.registry_name}/*"
        ]
      }
    ]
  })

  tags = {
    Name        = "${var.cluster_name}-glue-schema-registry-policy"
    Environment = var.environment
  }
}

# Attach Schema Registry policy to Lambda role
resource "aws_iam_role_policy_attachment" "lambda_schema_registry" {
  role       = aws_iam_role.lambda_msk_role.name
  policy_arn = aws_iam_policy.glue_schema_registry_policy.arn
}

# IAM Role for Kafka producers (can be used by applications)
resource "aws_iam_role" "kafka_producer_role" {
  name = "${var.cluster_name}-kafka-producer-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = [
            "ec2.amazonaws.com",
            "ecs-tasks.amazonaws.com",
            "lambda.amazonaws.com"
          ]
        }
      },
      {
        # Allow IAM users/roles to assume this role
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.cluster_name}-kafka-producer-role"
    Environment = var.environment
  }
}

# Attach Schema Registry policy to producer role
resource "aws_iam_role_policy_attachment" "producer_schema_registry" {
  role       = aws_iam_role.kafka_producer_role.name
  policy_arn = aws_iam_policy.glue_schema_registry_policy.arn
}

# Attach MSK access policy to producer role
resource "aws_iam_role_policy" "producer_msk_policy" {
  name = "${var.cluster_name}-producer-msk-policy"
  role = aws_iam_role.kafka_producer_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster"
        ]
        Resource = aws_msk_cluster.msk_cluster.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:CreateTopic",
          "kafka-cluster:WriteData",
          "kafka-cluster:ReadData"
        ]
        Resource = "arn:aws:kafka:${var.aws_region}:${data.aws_caller_identity.current.account_id}:topic/${var.cluster_name}/*/*"
      },
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:AlterGroup",
          "kafka-cluster:DescribeGroup"
        ]
        Resource = "arn:aws:kafka:${var.aws_region}:${data.aws_caller_identity.current.account_id}:group/${var.cluster_name}/*/*"
      }
    ]
  })
}
