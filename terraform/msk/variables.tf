# Variables for Amazon MSK Terraform configuration

variable "aws_region" {
  description = "AWS region to deploy MSK cluster"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (e.g., dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "Name of the MSK cluster"
  type        = string
  default     = "taxi-kafka-msk"
}

variable "kafka_version" {
  description = "Apache Kafka version for MSK cluster"
  type        = string
  default     = "3.6.0"
}

variable "number_of_broker_nodes" {
  description = "Number of broker nodes in the MSK cluster"
  type        = number
  default     = 3
}

variable "broker_instance_type" {
  description = "Instance type for MSK broker nodes"
  type        = string
  default     = "kafka.m5.large"
}

variable "broker_ebs_volume_size" {
  description = "EBS volume size in GB for each broker"
  type        = number
  default     = 100
}

variable "provisioned_throughput_enabled" {
  description = "Enable provisioned throughput for EBS storage"
  type        = bool
  default     = false
}

variable "volume_throughput" {
  description = "Provisioned throughput in MiB/s (250-2375)"
  type        = number
  default     = 250
}

# Networking
variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_access_enabled" {
  description = "Enable public access to MSK brokers"
  type        = bool
  default     = false
}

# Encryption
variable "encryption_in_transit_client_broker" {
  description = "Encryption setting for client-broker communication (TLS, TLS_PLAINTEXT, or PLAINTEXT)"
  type        = string
  default     = "TLS"
}

variable "encryption_in_transit_in_cluster" {
  description = "Enable encryption in-transit within the cluster"
  type        = bool
  default     = true
}

# Authentication
variable "sasl_iam_enabled" {
  description = "Enable SASL/IAM authentication"
  type        = bool
  default     = true
}

variable "sasl_scram_enabled" {
  description = "Enable SASL/SCRAM authentication"
  type        = bool
  default     = false
}

variable "unauthenticated_access_enabled" {
  description = "Enable unauthenticated access"
  type        = bool
  default     = false
}

# Logging
variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 7
}

# Kafka Configuration
variable "log_retention_hours" {
  description = "Kafka log retention in hours"
  type        = number
  default     = 168
}

variable "default_partitions" {
  description = "Default number of partitions for auto-created topics"
  type        = number
  default     = 3
}

variable "default_replication_factor" {
  description = "Default replication factor for auto-created topics"
  type        = number
  default     = 3
}

variable "min_insync_replicas" {
  description = "Minimum in-sync replicas"
  type        = number
  default     = 2
}

# Monitoring
variable "enhanced_monitoring" {
  description = "Enhanced monitoring level (DEFAULT, PER_BROKER, PER_TOPIC_PER_BROKER, or PER_TOPIC_PER_PARTITION)"
  type        = string
  default     = "PER_BROKER"
}

variable "jmx_exporter_enabled" {
  description = "Enable JMX Exporter for Prometheus"
  type        = bool
  default     = true
}

variable "node_exporter_enabled" {
  description = "Enable Node Exporter for Prometheus"
  type        = bool
  default     = true
}

# Lambda Configuration
variable "lambda_timeout" {
  description = "Lambda function timeout in seconds"
  type        = number
  default     = 60
}

variable "lambda_memory_size" {
  description = "Lambda function memory size in MB"
  type        = number
  default     = 256
}

variable "lambda_batch_size" {
  description = "Maximum number of records Lambda receives from MSK per batch"
  type        = number
  default     = 100
}

variable "lambda_starting_position" {
  description = "Starting position for Lambda to read from MSK (TRIM_HORIZON or LATEST)"
  type        = string
  default     = "LATEST"
}

variable "kafka_topics" {
  description = "List of Kafka topics to trigger Lambda function"
  type        = list(string)
  default     = ["taxi-rides", "taxi-locations"]
}

variable "consumer_group_id" {
  description = "Kafka consumer group ID for Lambda"
  type        = string
  default     = ""
}

# AppSync Configuration
variable "appsync_auth_type" {
  description = "AppSync authentication type (API_KEY, AWS_IAM, AMAZON_COGNITO_USER_POOLS)"
  type        = string
  default     = "API_KEY"
}

variable "appsync_api_key_expiry_days" {
  description = "Number of days until AppSync API key expires"
  type        = number
  default     = 365
}

variable "cognito_user_pool_id" {
  description = "Cognito User Pool ID (required if using AMAZON_COGNITO_USER_POOLS auth)"
  type        = string
  default     = ""
}

variable "create_appsync_vpc_endpoint" {
  description = "Create VPC endpoint for AppSync"
  type        = bool
  default     = false
}

# Schema Registry Configuration
variable "schema_data_format" {
  description = "Data format for schemas (AVRO, JSON, or PROTOBUF)"
  type        = string
  default     = "AVRO"
}

variable "schema_compatibility" {
  description = "Schema compatibility mode (NONE, DISABLED, BACKWARD, BACKWARD_ALL, FORWARD, FORWARD_ALL, FULL, FULL_ALL)"
  type        = string
  default     = "BACKWARD"
}

variable "create_default_schemas" {
  description = "Create default schemas for taxi-rides and taxi-locations topics"
  type        = bool
  default     = true
}

variable "schema_auto_registration" {
  description = "Enable auto-registration of schemas on first message"
  type        = bool
  default     = true
}

# DynamoDB and Delta Sync Configuration
variable "historical_retention_days" {
  description = "Days to retain historical events in DynamoDB"
  type        = number
  default     = 30
}

variable "delta_sync_ttl_minutes" {
  description = "TTL in minutes for Delta Sync table records"
  type        = number
  default     = 1440  # 24 hours
}
