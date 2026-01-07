# Outputs for Amazon MSK Terraform configuration

output "msk_cluster_arn" {
  description = "ARN of the MSK cluster"
  value       = aws_msk_cluster.msk_cluster.arn
}

output "msk_cluster_name" {
  description = "Name of the MSK cluster"
  value       = aws_msk_cluster.msk_cluster.cluster_name
}

output "bootstrap_brokers" {
  description = "Plaintext connection host:port pairs"
  value       = aws_msk_cluster.msk_cluster.bootstrap_brokers
}

output "bootstrap_brokers_tls" {
  description = "TLS connection host:port pairs"
  value       = aws_msk_cluster.msk_cluster.bootstrap_brokers_tls
}

output "bootstrap_brokers_sasl_iam" {
  description = "IAM authenticated connection host:port pairs"
  value       = aws_msk_cluster.msk_cluster.bootstrap_brokers_sasl_iam
}

output "bootstrap_brokers_sasl_scram" {
  description = "SASL/SCRAM authenticated connection host:port pairs"
  value       = aws_msk_cluster.msk_cluster.bootstrap_brokers_sasl_scram
}

output "zookeeper_connect_string" {
  description = "Zookeeper connection string"
  value       = aws_msk_cluster.msk_cluster.zookeeper_connect_string
}

output "zookeeper_connect_string_tls" {
  description = "Zookeeper TLS connection string"
  value       = aws_msk_cluster.msk_cluster.zookeeper_connect_string_tls
}

output "msk_cluster_current_version" {
  description = "Current version of the MSK cluster"
  value       = aws_msk_cluster.msk_cluster.current_version
}

output "vpc_id" {
  description = "VPC ID where MSK is deployed"
  value       = aws_vpc.msk_vpc.id
}

output "subnet_ids" {
  description = "Subnet IDs used by MSK brokers"
  value       = aws_subnet.msk_subnet[*].id
}

output "security_group_id" {
  description = "Security group ID for MSK cluster"
  value       = aws_security_group.msk_sg.id
}

output "kms_key_arn" {
  description = "KMS key ARN used for encryption"
  value       = aws_kms_key.msk_kms_key.arn
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group for MSK broker logs"
  value       = aws_cloudwatch_log_group.msk_log_group.name
}

output "s3_logs_bucket" {
  description = "S3 bucket for MSK logs"
  value       = aws_s3_bucket.msk_logs_bucket.id
}

output "msk_configuration_arn" {
  description = "ARN of the MSK configuration"
  value       = aws_msk_configuration.msk_config.arn
}

# Lambda Outputs
output "lambda_function_arn" {
  description = "ARN of the Lambda function"
  value       = aws_lambda_function.msk_to_appsync.arn
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.msk_to_appsync.function_name
}

output "lambda_role_arn" {
  description = "ARN of the Lambda execution role"
  value       = aws_iam_role.lambda_msk_role.arn
}

output "lambda_security_group_id" {
  description = "Security group ID for Lambda function"
  value       = aws_security_group.lambda_sg.id
}

# AppSync Outputs
output "appsync_api_id" {
  description = "AppSync Event API ID"
  value       = aws_appsync_api.events_api.id
}

output "appsync_api_arn" {
  description = "AppSync Event API ARN"
  value       = aws_appsync_api.events_api.arn
}

output "appsync_http_endpoint" {
  description = "AppSync HTTP endpoint for publishing events"
  value       = "https://${aws_appsync_api.events_api.dns["HTTP"]}"
}

output "appsync_realtime_endpoint" {
  description = "AppSync Realtime endpoint for WebSocket subscriptions"
  value       = "wss://${aws_appsync_api.events_api.dns["REALTIME"]}"
}

output "appsync_api_key" {
  description = "AppSync API Key (if using API_KEY auth)"
  value       = var.appsync_auth_type == "API_KEY" ? aws_appsync_api_key.events_api_key[0].key : null
  sensitive   = true
}

output "kafka_namespace" {
  description = "Kafka channel namespace for subscriptions"
  value       = aws_appsync_channel_namespace.kafka_namespace.name
}

output "taxi_namespace" {
  description = "Taxi channel namespace for subscriptions"
  value       = aws_appsync_channel_namespace.taxi_namespace.name
}

# Schema Registry Outputs
output "glue_registry_arn" {
  description = "ARN of the Glue Schema Registry"
  value       = aws_glue_registry.msk_registry.arn
}

output "glue_registry_name" {
  description = "Name of the Glue Schema Registry"
  value       = aws_glue_registry.msk_registry.registry_name
}

output "kafka_producer_role_arn" {
  description = "ARN of the IAM role for Kafka producers with schema registry access"
  value       = aws_iam_role.kafka_producer_role.arn
}

output "schema_registry_policy_arn" {
  description = "ARN of the IAM policy for schema registry access"
  value       = aws_iam_policy.glue_schema_registry_policy.arn
}

output "taxi_rides_schema_arn" {
  description = "ARN of the taxi-rides schema"
  value       = var.create_default_schemas ? aws_glue_schema.taxi_rides_schema[0].arn : null
}

output "taxi_locations_schema_arn" {
  description = "ARN of the taxi-locations schema"
  value       = var.create_default_schemas ? aws_glue_schema.taxi_locations_schema[0].arn : null
}

# DynamoDB Outputs
output "events_table_name" {
  description = "Name of the DynamoDB events table"
  value       = aws_dynamodb_table.events_table.name
}

output "events_table_arn" {
  description = "ARN of the DynamoDB events table"
  value       = aws_dynamodb_table.events_table.arn
}

output "delta_sync_table_name" {
  description = "Name of the DynamoDB Delta Sync table"
  value       = aws_dynamodb_table.delta_sync_table.name
}

# AppSync GraphQL API Outputs
output "graphql_api_id" {
  description = "AppSync GraphQL API ID for historical queries"
  value       = aws_appsync_graphql_api.historical_api.id
}

output "graphql_api_endpoint" {
  description = "AppSync GraphQL API endpoint for historical queries"
  value       = aws_appsync_graphql_api.historical_api.uris["GRAPHQL"]
}

output "graphql_api_key" {
  description = "AppSync GraphQL API Key"
  value       = var.appsync_auth_type == "API_KEY" ? aws_appsync_api_key.historical_api_key[0].key : null
  sensitive   = true
}
