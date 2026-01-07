# Terraform configuration for Amazon MSK Provisioned Cluster

terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Data source to get available AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# VPC for MSK
resource "aws_vpc" "msk_vpc" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name        = "${var.cluster_name}-vpc"
    Environment = var.environment
  }
}

# Internet Gateway
resource "aws_internet_gateway" "msk_igw" {
  vpc_id = aws_vpc.msk_vpc.id

  tags = {
    Name        = "${var.cluster_name}-igw"
    Environment = var.environment
  }
}

# Subnets for MSK (one per AZ)
resource "aws_subnet" "msk_subnet" {
  count                   = var.number_of_broker_nodes
  vpc_id                  = aws_vpc.msk_vpc.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name        = "${var.cluster_name}-subnet-${count.index + 1}"
    Environment = var.environment
  }
}

# Route Table
resource "aws_route_table" "msk_rt" {
  vpc_id = aws_vpc.msk_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.msk_igw.id
  }

  tags = {
    Name        = "${var.cluster_name}-rt"
    Environment = var.environment
  }
}

# Route Table Association
resource "aws_route_table_association" "msk_rta" {
  count          = var.number_of_broker_nodes
  subnet_id      = aws_subnet.msk_subnet[count.index].id
  route_table_id = aws_route_table.msk_rt.id
}

# Security Group for MSK
resource "aws_security_group" "msk_sg" {
  name        = "${var.cluster_name}-sg"
  description = "Security group for MSK cluster"
  vpc_id      = aws_vpc.msk_vpc.id

  # Kafka plaintext
  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Kafka plaintext"
  }

  # Kafka TLS
  ingress {
    from_port   = 9094
    to_port     = 9094
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Kafka TLS"
  }

  # Kafka SASL/SCRAM
  ingress {
    from_port   = 9096
    to_port     = 9096
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Kafka SASL/SCRAM"
  }

  # Kafka IAM
  ingress {
    from_port   = 9098
    to_port     = 9098
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Kafka IAM authentication"
  }

  # Zookeeper
  ingress {
    from_port   = 2181
    to_port     = 2181
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "Zookeeper"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }

  tags = {
    Name        = "${var.cluster_name}-sg"
    Environment = var.environment
  }
}

# KMS Key for MSK encryption
resource "aws_kms_key" "msk_kms_key" {
  description             = "KMS key for MSK cluster encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name        = "${var.cluster_name}-kms-key"
    Environment = var.environment
  }
}

resource "aws_kms_alias" "msk_kms_alias" {
  name          = "alias/${var.cluster_name}-key"
  target_key_id = aws_kms_key.msk_kms_key.key_id
}

# CloudWatch Log Group for MSK
resource "aws_cloudwatch_log_group" "msk_log_group" {
  name              = "/aws/msk/${var.cluster_name}"
  retention_in_days = var.log_retention_days

  tags = {
    Name        = "${var.cluster_name}-logs"
    Environment = var.environment
  }
}

# S3 Bucket for MSK logs (optional)
resource "aws_s3_bucket" "msk_logs_bucket" {
  bucket = "${var.cluster_name}-logs-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name        = "${var.cluster_name}-logs-bucket"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "msk_logs_versioning" {
  bucket = aws_s3_bucket.msk_logs_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_caller_identity" "current" {}

# MSK Configuration
resource "aws_msk_configuration" "msk_config" {
  name              = "${var.cluster_name}-config"
  kafka_versions    = [var.kafka_version]
  server_properties = <<PROPERTIES
auto.create.topics.enable=true
delete.topic.enable=true
log.retention.hours=${var.log_retention_hours}
num.partitions=${var.default_partitions}
default.replication.factor=${var.default_replication_factor}
min.insync.replicas=${var.min_insync_replicas}
log.segment.bytes=1073741824
log.retention.check.interval.ms=300000
PROPERTIES

  description = "MSK configuration for ${var.cluster_name}"
}

# Amazon MSK Cluster
resource "aws_msk_cluster" "msk_cluster" {
  cluster_name           = var.cluster_name
  kafka_version          = var.kafka_version
  number_of_broker_nodes = var.number_of_broker_nodes

  broker_node_group_info {
    instance_type   = var.broker_instance_type
    client_subnets  = aws_subnet.msk_subnet[*].id
    security_groups = [aws_security_group.msk_sg.id]

    storage_info {
      ebs_storage_info {
        volume_size = var.broker_ebs_volume_size
        provisioned_throughput {
          enabled           = var.provisioned_throughput_enabled
          volume_throughput = var.provisioned_throughput_enabled ? var.volume_throughput : null
        }
      }
    }

    connectivity_info {
      public_access {
        type = var.public_access_enabled ? "SERVICE_PROVIDED_EIPS" : "DISABLED"
      }
    }
  }

  configuration_info {
    arn      = aws_msk_configuration.msk_config.arn
    revision = aws_msk_configuration.msk_config.latest_revision
  }

  encryption_info {
    encryption_at_rest_kms_key_arn = aws_kms_key.msk_kms_key.arn
    encryption_in_transit {
      client_broker = var.encryption_in_transit_client_broker
      in_cluster    = var.encryption_in_transit_in_cluster
    }
  }

  client_authentication {
    sasl {
      iam   = var.sasl_iam_enabled
      scram = var.sasl_scram_enabled
    }
    unauthenticated = var.unauthenticated_access_enabled
  }

  logging_info {
    broker_logs {
      cloudwatch_logs {
        enabled   = true
        log_group = aws_cloudwatch_log_group.msk_log_group.name
      }
      s3 {
        enabled = true
        bucket  = aws_s3_bucket.msk_logs_bucket.id
        prefix  = "logs/msk-"
      }
    }
  }

  open_monitoring {
    prometheus {
      jmx_exporter {
        enabled_in_broker = var.jmx_exporter_enabled
      }
      node_exporter {
        enabled_in_broker = var.node_exporter_enabled
      }
    }
  }

  enhanced_monitoring = var.enhanced_monitoring

  tags = {
    Name        = var.cluster_name
    Environment = var.environment
  }
}
