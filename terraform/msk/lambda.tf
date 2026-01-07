# AWS Lambda configuration for MSK to AppSync Event API integration

# IAM Role for Lambda
resource "aws_iam_role" "lambda_msk_role" {
  name = "${var.cluster_name}-lambda-msk-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.cluster_name}-lambda-msk-role"
    Environment = var.environment
  }
}

# IAM Policy for Lambda to access MSK
resource "aws_iam_role_policy" "lambda_msk_policy" {
  name = "${var.cluster_name}-lambda-msk-policy"
  role = aws_iam_role.lambda_msk_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kafka:DescribeCluster",
          "kafka:DescribeClusterV2",
          "kafka:GetBootstrapBrokers",
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeCluster",
          "kafka-cluster:DescribeTopic",
          "kafka-cluster:ReadData",
          "kafka-cluster:DescribeGroup",
          "kafka-cluster:AlterGroup"
        ]
        Resource = [
          aws_msk_cluster.msk_cluster.arn,
          "${aws_msk_cluster.msk_cluster.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kafka-cluster:Connect",
          "kafka-cluster:DescribeTopic",
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

# IAM Policy for Lambda to access AppSync
resource "aws_iam_role_policy" "lambda_appsync_policy" {
  name = "${var.cluster_name}-lambda-appsync-policy"
  role = aws_iam_role.lambda_msk_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "appsync:EventPublish",
          "appsync:EventSubscribe"
        ]
        Resource = "${aws_appsync_api.events_api.arn}/*"
      }
    ]
  })
}

# IAM Policy for Lambda VPC access
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda_msk_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# IAM Policy for Lambda basic execution
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_msk_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Security Group for Lambda
resource "aws_security_group" "lambda_sg" {
  name        = "${var.cluster_name}-lambda-sg"
  description = "Security group for Lambda function"
  vpc_id      = aws_vpc.msk_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name        = "${var.cluster_name}-lambda-sg"
    Environment = var.environment
  }
}

# Allow Lambda to connect to MSK
resource "aws_security_group_rule" "msk_from_lambda" {
  type                     = "ingress"
  from_port                = 9092
  to_port                  = 9098
  protocol                 = "tcp"
  security_group_id        = aws_security_group.msk_sg.id
  source_security_group_id = aws_security_group.lambda_sg.id
  description              = "Allow Lambda to connect to MSK"
}

# Lambda function code
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda_src"
  output_path = "${path.module}/lambda_function.zip"

  depends_on = [local_file.lambda_code]
}

# Create Lambda source directory and code
resource "local_file" "lambda_code" {
  filename = "${path.module}/lambda_src/index.py"
  content  = <<-PYTHON
import json
import os
import base64
import urllib.request
import urllib.error
from datetime import datetime

# AppSync Event API configuration
APPSYNC_HTTP_ENDPOINT = os.environ.get('APPSYNC_HTTP_ENDPOINT')
APPSYNC_API_KEY = os.environ.get('APPSYNC_API_KEY')
GLUE_REGISTRY_NAME = os.environ.get('GLUE_REGISTRY_NAME')
SCHEMA_AUTO_REGISTRATION = os.environ.get('SCHEMA_AUTO_REGISTRATION', 'true').lower() == 'true'

# Try to import Glue Schema Registry deserializer
try:
    import boto3
    from aws_schema_registry.avro import AvroSchema
    from aws_schema_registry import SchemaRegistryClient
    SCHEMA_REGISTRY_AVAILABLE = True
except ImportError:
    SCHEMA_REGISTRY_AVAILABLE = False
    print("AWS Glue Schema Registry libraries not available, using raw deserialization")

# Initialize Schema Registry client if available
schema_registry_client = None
if SCHEMA_REGISTRY_AVAILABLE and GLUE_REGISTRY_NAME:
    try:
        region = os.environ.get('AWS_GLUE_REGION', os.environ.get('AWS_REGION', 'us-east-1'))
        schema_registry_client = SchemaRegistryClient(
            endpoint=f"https://glue.{region}.amazonaws.com",
            region=region,
            registry_name=GLUE_REGISTRY_NAME,
            auto_register_schemas=SCHEMA_AUTO_REGISTRATION
        )
        print(f"Schema Registry client initialized for registry: {GLUE_REGISTRY_NAME}")
    except Exception as e:
        print(f"Failed to initialize Schema Registry client: {e}")


def deserialize_avro_message(raw_bytes, topic):
    """
    Deserialize Avro message using Glue Schema Registry.
    Falls back to raw deserialization if schema registry is not available.
    """
    if schema_registry_client and len(raw_bytes) > 18:
        try:
            # Check for Glue Schema Registry header (starts with version byte 0x03)
            if raw_bytes[0] == 0x03:
                # Use schema registry to deserialize
                from aws_schema_registry.adapter.kafka import KafkaDeserializer
                deserializer = KafkaDeserializer(schema_registry_client)
                return deserializer.deserialize(topic, raw_bytes)
        except Exception as e:
            print(f"Schema Registry deserialization failed for topic {topic}: {e}")
    
    # Fallback: try to decode as UTF-8 JSON
    try:
        return json.loads(raw_bytes.decode('utf-8'))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return {"raw_bytes": base64.b64encode(raw_bytes).decode('utf-8')}


def publish_to_appsync(channel, event_data):
    """
    Publish an event to AppSync Event API
    """
    if not APPSYNC_HTTP_ENDPOINT:
        print("APPSYNC_HTTP_ENDPOINT not configured")
        return False
    
    # Construct the event publish URL
    url = f"{APPSYNC_HTTP_ENDPOINT}/event"
    
    payload = {
        "channel": channel,
        "events": [json.dumps(event_data)]
    }
    
    headers = {
        "Content-Type": "application/json"
    }
    
    # Add API key if available
    if APPSYNC_API_KEY:
        headers["x-api-key"] = APPSYNC_API_KEY
    
    try:
        data = json.dumps(payload).encode('utf-8')
        req = urllib.request.Request(url, data=data, headers=headers, method='POST')
        
        with urllib.request.urlopen(req, timeout=10) as response:
            response_data = response.read().decode('utf-8')
            print(f"AppSync response: {response_data}")
            return True
    except urllib.error.HTTPError as e:
        print(f"HTTP Error publishing to AppSync: {e.code} - {e.read().decode('utf-8')}")
        return False
    except urllib.error.URLError as e:
        print(f"URL Error publishing to AppSync: {e.reason}")
        return False
    except Exception as e:
        print(f"Error publishing to AppSync: {str(e)}")
        return False


def lambda_handler(event, context):
    """
    Lambda handler for MSK events
    Processes Kafka messages (with Schema Registry support) and publishes to AppSync Event API
    """
    print(f"Received event with {sum(len(records) for records in event.get('records', {}).values())} records")
    
    processed_count = 0
    error_count = 0
    
    # Process each record from MSK
    for topic_partition, records in event.get('records', {}).items():
        # Extract topic name from the key (format: topic-partition)
        topic = topic_partition.rsplit('-', 1)[0]
        
        for record in records:
            try:
                # Decode the Kafka message value (base64 encoded by MSK Lambda trigger)
                raw_value = base64.b64decode(record.get('value', ''))
                
                # Deserialize using Schema Registry if available, otherwise try JSON
                message_data = deserialize_avro_message(raw_value, topic)
                
                # Extract key if present
                key = None
                if record.get('key'):
                    key = base64.b64decode(record['key']).decode('utf-8')
                
                # Build event payload with schema metadata if available
                event_payload = {
                    "topic": topic,
                    "partition": record.get('partition'),
                    "offset": record.get('offset'),
                    "timestamp": record.get('timestamp'),
                    "key": key,
                    "data": message_data,
                    "schema_registry_enabled": schema_registry_client is not None,
                    "processed_at": datetime.utcnow().isoformat()
                }
                
                # Determine channel based on topic or use default
                channel = f"/kafka/{topic}"
                
                # Publish to AppSync Event API
                if publish_to_appsync(channel, event_payload):
                    processed_count += 1
                else:
                    error_count += 1
                    
            except Exception as e:
                print(f"Error processing record: {str(e)}")
                error_count += 1
    
    result = {
        "statusCode": 200,
        "body": {
            "processed": processed_count,
            "errors": error_count
        }
    }
    
    print(f"Processing complete: {result}")
    return result
PYTHON
}

# Lambda function
resource "aws_lambda_function" "msk_to_appsync" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${var.cluster_name}-msk-to-appsync"
  role             = aws_iam_role.lambda_msk_role.arn
  handler          = "index.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.12"
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_size

  vpc_config {
    subnet_ids         = aws_subnet.msk_subnet[*].id
    security_group_ids = [aws_security_group.lambda_sg.id]
  }

  environment {
    variables = {
      APPSYNC_HTTP_ENDPOINT   = aws_appsync_api.events_api.event_config[0].connection_auth_modes[0] != null ? "https://${aws_appsync_api.events_api.dns["HTTP"]}" : ""
      APPSYNC_API_KEY         = var.appsync_auth_type == "API_KEY" ? aws_appsync_api_key.events_api_key[0].key : ""
      CLUSTER_NAME            = var.cluster_name
      GLUE_REGISTRY_NAME      = aws_glue_registry.msk_registry.registry_name
      SCHEMA_AUTO_REGISTRATION = tostring(var.schema_auto_registration)
      AWS_GLUE_REGION         = var.aws_region
    }
  }

  tags = {
    Name        = "${var.cluster_name}-msk-to-appsync"
    Environment = var.environment
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_vpc_access,
    aws_iam_role_policy_attachment.lambda_basic_execution,
    aws_cloudwatch_log_group.lambda_log_group
  ]
}

# CloudWatch Log Group for Lambda
resource "aws_cloudwatch_log_group" "lambda_log_group" {
  name              = "/aws/lambda/${var.cluster_name}-msk-to-appsync"
  retention_in_days = var.log_retention_days

  tags = {
    Name        = "${var.cluster_name}-lambda-logs"
    Environment = var.environment
  }
}

# MSK Event Source Mapping
resource "aws_lambda_event_source_mapping" "msk_trigger" {
  count = length(var.kafka_topics)

  event_source_arn  = aws_msk_cluster.msk_cluster.arn
  function_name     = aws_lambda_function.msk_to_appsync.arn
  topics            = [var.kafka_topics[count.index]]
  starting_position = var.lambda_starting_position
  batch_size        = var.lambda_batch_size

  dynamic "amazon_managed_kafka_event_source_config" {
    for_each = var.consumer_group_id != "" ? [1] : []
    content {
      consumer_group_id = var.consumer_group_id
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda_msk_policy
  ]
}

# VPC Endpoint for AppSync (optional, for private connectivity)
resource "aws_vpc_endpoint" "appsync" {
  count = var.create_appsync_vpc_endpoint ? 1 : 0

  vpc_id              = aws_vpc.msk_vpc.id
  service_name        = "com.amazonaws.${var.aws_region}.appsync-api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.msk_subnet[*].id
  security_group_ids  = [aws_security_group.lambda_sg.id]
  private_dns_enabled = true

  tags = {
    Name        = "${var.cluster_name}-appsync-endpoint"
    Environment = var.environment
  }
}
