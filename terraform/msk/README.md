# MSK to AppSync Event API Integration

This Terraform configuration sets up an Amazon MSK (Managed Streaming for Apache Kafka) cluster integrated with AWS AppSync Event API via AWS Lambda.

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────────────┐     ┌─────────────┐
│   Kafka     │     │   AWS       │     │   AWS AppSync       │     │   Client    │
│  Producers  │────▶│   MSK       │────▶│   Event API         │────▶│  WebSocket  │
│             │     │  (Topics)   │     │  (Real-time)        │     │ Subscribers │
└─────────────┘     └──────┬──────┘     └─────────────────────┘     └─────────────┘
                           │                      ▲
                           │     ┌────────────────┘
                           │     │
                    ┌──────▼─────┴──────┐
                    │   AWS Lambda      │
                    │   (Event Bridge)  │
                    └───────────────────┘
```

## Components

### MSK Cluster (`main.tf`)
- Provisioned Kafka cluster with configurable broker nodes
- VPC with dedicated subnets
- KMS encryption at rest and TLS in transit
- CloudWatch and S3 logging
- Prometheus monitoring (JMX & Node exporters)

### Lambda Function (`lambda.tf`)
- Python 3.12 runtime
- Triggered by MSK event source mapping
- Processes Kafka messages and publishes to AppSync
- VPC-enabled for MSK connectivity

### AppSync Event API (`appsync.tf`)
- Real-time Event API for WebSocket subscriptions
- Channel namespaces: `/kafka/*` and `/taxi/*`
- Supports API_KEY, IAM, or Cognito authentication

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.0.0
- AWS account with permissions for MSK, Lambda, AppSync, VPC, IAM

## Usage

### 1. Initialize Terraform

```bash
cd terraform/msk
terraform init
```

### 2. Configure Variables

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

### 3. Review Plan

```bash
terraform plan
```

### 4. Apply Configuration

```bash
terraform apply
```

## Configuration Variables

### MSK Configuration
| Variable | Description | Default |
|----------|-------------|---------|
| `cluster_name` | MSK cluster name | `taxi-kafka-msk` |
| `kafka_version` | Kafka version | `3.6.0` |
| `number_of_broker_nodes` | Number of broker nodes | `3` |
| `broker_instance_type` | Instance type | `kafka.m5.large` |
| `broker_ebs_volume_size` | EBS volume size (GB) | `100` |

### Lambda Configuration
| Variable | Description | Default |
|----------|-------------|---------|
| `lambda_timeout` | Function timeout (seconds) | `60` |
| `lambda_memory_size` | Memory size (MB) | `256` |
| `lambda_batch_size` | Max records per batch | `100` |
| `kafka_topics` | Topics to consume | `["taxi-rides", "taxi-locations"]` |

### AppSync Configuration
| Variable | Description | Default |
|----------|-------------|---------|
| `appsync_auth_type` | Auth type (API_KEY, AWS_IAM, AMAZON_COGNITO_USER_POOLS) | `API_KEY` |
| `appsync_api_key_expiry_days` | API key expiry | `365` |

## Outputs

After deployment, you'll get:

- `bootstrap_brokers_sasl_iam` - MSK broker endpoints for IAM auth
- `appsync_http_endpoint` - HTTP endpoint for publishing events
- `appsync_realtime_endpoint` - WebSocket endpoint for subscriptions
- `appsync_api_key` - API key (if using API_KEY auth)

## Subscribing to Events

### JavaScript Client Example

```javascript
import { Amplify } from 'aws-amplify';
import { events } from 'aws-amplify/data';

// Configure AppSync
Amplify.configure({
  API: {
    Events: {
      endpoint: 'YOUR_APPSYNC_HTTP_ENDPOINT',
      region: 'us-east-1',
      defaultAuthMode: 'apiKey',
      apiKey: 'YOUR_API_KEY'
    }
  }
});

// Subscribe to taxi rides
const channel = await events.connect('/kafka/taxi-rides');
channel.subscribe({
  next: (data) => {
    console.log('Received taxi ride:', data);
  },
  error: (err) => console.error('Error:', err)
});
```

### Event Payload Structure

```json
{
  "topic": "taxi-rides",
  "partition": 0,
  "offset": 12345,
  "timestamp": 1703073600000,
  "key": "ride-123",
  "data": {
    "ride_id": "ride-123",
    "pickup_location": {"lat": 40.7128, "lng": -74.0060},
    "dropoff_location": {"lat": 40.7614, "lng": -73.9776},
    "passenger_count": 2
  },
  "processed_at": "2024-12-20T10:00:00.000Z"
}
```

## Channel Namespaces

| Namespace | Channel Pattern | Description |
|-----------|-----------------|-------------|
| `kafka` | `/kafka/{topic}` | Auto-generated from Kafka topic names |
| `taxi` | `/taxi/{event-type}` | Custom taxi-specific events |

## Security Considerations

1. **Network**: MSK and Lambda are deployed in a private VPC
2. **Encryption**: TLS in transit, KMS encryption at rest
3. **Authentication**: IAM auth for MSK, configurable auth for AppSync
4. **Least Privilege**: IAM roles with minimal required permissions

## Cleanup

```bash
terraform destroy
```

## Troubleshooting

### Lambda not receiving messages
- Check MSK event source mapping status in AWS Console
- Verify Lambda has correct IAM permissions for MSK
- Check Lambda CloudWatch logs

### AppSync events not publishing
- Verify APPSYNC_HTTP_ENDPOINT environment variable
- Check Lambda has outbound internet access (NAT Gateway may be needed)
- Review AppSync API logs

### Authentication issues
- Ensure API key hasn't expired
- Verify IAM roles have correct trust relationships
- Check Cognito user pool configuration if using Cognito auth
