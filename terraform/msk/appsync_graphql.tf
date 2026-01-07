# AppSync GraphQL API for Historical Queries and Delta Sync

# GraphQL API
resource "aws_appsync_graphql_api" "historical_api" {
  name                = "${var.cluster_name}-graphql-api"
  authentication_type = var.appsync_auth_type
  xray_enabled        = true

  dynamic "user_pool_config" {
    for_each = var.appsync_auth_type == "AMAZON_COGNITO_USER_POOLS" ? [1] : []
    content {
      user_pool_id   = var.cognito_user_pool_id
      aws_region     = var.aws_region
      default_action = "ALLOW"
    }
  }

  tags = {
    Name        = "${var.cluster_name}-graphql-api"
    Environment = var.environment
  }
}

# GraphQL API Key
resource "aws_appsync_api_key" "historical_api_key" {
  count   = var.appsync_auth_type == "API_KEY" ? 1 : 0
  api_id  = aws_appsync_graphql_api.historical_api.id
  expires = timeadd(timestamp(), "${var.appsync_api_key_expiry_days * 24}h")

  lifecycle {
    ignore_changes = [expires]
  }
}

# GraphQL Schema
resource "aws_appsync_graphql_api_schema" "schema" {
  api_id = aws_appsync_graphql_api.historical_api.id

  definition = <<-SCHEMA
    type TaxiEvent {
      id: ID!
      topic: String!
      partition: Int
      offset: Int
      timestamp: AWSTimestamp!
      key: String
      data: AWSJSON!
      processedAt: AWSDateTime!
      ttl: Int
      _version: Int
      _lastChangedAt: AWSTimestamp
      _deleted: Boolean
    }

    type TaxiEventConnection {
      items: [TaxiEvent]
      nextToken: String
      startedAt: AWSTimestamp
    }

    input EventFilterInput {
      topic: String
      startTime: AWSTimestamp
      endTime: AWSTimestamp
      key: String
    }

    type Query {
      getEvent(id: ID!): TaxiEvent
      
      listEvents(
        filter: EventFilterInput
        limit: Int
        nextToken: String
      ): TaxiEventConnection
      
      queryEventsByTopic(
        topic: String!
        startTime: AWSTimestamp
        endTime: AWSTimestamp
        limit: Int
        nextToken: String
      ): TaxiEventConnection
      
      syncEvents(
        lastSync: AWSTimestamp
        nextToken: String
        limit: Int
      ): TaxiEventConnection
      
      getLatestEvents(
        topic: String
        limit: Int
      ): TaxiEventConnection
    }

    type Mutation {
      createEvent(
        topic: String!
        key: String
        data: AWSJSON!
      ): TaxiEvent
    }

    type Subscription {
      onCreateEvent(topic: String): TaxiEvent
        @aws_subscribe(mutations: ["createEvent"])
    }

    schema {
      query: Query
      mutation: Mutation
      subscription: Subscription
    }
  SCHEMA
}

# IAM Role for AppSync
resource "aws_iam_role" "appsync_dynamodb_role" {
  name = "${var.cluster_name}-appsync-dynamodb-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "appsync.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name        = "${var.cluster_name}-appsync-dynamodb-role"
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "appsync_dynamodb_policy" {
  name = "${var.cluster_name}-appsync-dynamodb-policy"
  role = aws_iam_role.appsync_dynamodb_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:BatchGetItem",
          "dynamodb:BatchWriteItem"
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

# DynamoDB Data Source with Delta Sync
resource "aws_appsync_datasource" "events_table" {
  api_id           = aws_appsync_graphql_api.historical_api.id
  name             = "EventsTable"
  service_role_arn = aws_iam_role.appsync_dynamodb_role.arn
  type             = "AMAZON_DYNAMODB"

  dynamodb_config {
    table_name             = aws_dynamodb_table.events_table.name
    region                 = var.aws_region
    use_caller_credentials = false
    versioned              = true

    delta_sync_config {
      base_table_ttl       = var.historical_retention_days * 60  # in minutes
      delta_sync_table_name = aws_dynamodb_table.delta_sync_table.name
      delta_sync_table_ttl = var.delta_sync_ttl_minutes
    }
  }
}

# Resolvers

# Get Event Resolver
resource "aws_appsync_resolver" "get_event" {
  api_id      = aws_appsync_graphql_api.historical_api.id
  type        = "Query"
  field       = "getEvent"
  data_source = aws_appsync_datasource.events_table.name
  runtime {
    name            = "APPSYNC_JS"
    runtime_version = "1.0.0"
  }
  code = <<-CODE
    import { util } from '@aws-appsync/utils';
    export function request(ctx) {
      return {
        operation: 'GetItem',
        key: util.dynamodb.toMapValues({ pk: 'EVENT#' + ctx.args.id, sk: 'EVENT#' + ctx.args.id })
      };
    }
    export function response(ctx) {
      return ctx.result;
    }
  CODE
}

# List Events Resolver
resource "aws_appsync_resolver" "list_events" {
  api_id      = aws_appsync_graphql_api.historical_api.id
  type        = "Query"
  field       = "listEvents"
  data_source = aws_appsync_datasource.events_table.name
  runtime {
    name            = "APPSYNC_JS"
    runtime_version = "1.0.0"
  }
  code = <<-CODE
    import { util } from '@aws-appsync/utils';
    export function request(ctx) {
      const { filter, limit, nextToken } = ctx.args;
      const req = { operation: 'Scan', limit: limit || 20 };
      if (nextToken) req.nextToken = nextToken;
      if (filter && filter.topic) {
        req.filter = {
          expression: '#topic = :topic',
          expressionNames: { '#topic': 'topic' },
          expressionValues: { ':topic': util.dynamodb.toDynamoDB(filter.topic) }
        };
      }
      return req;
    }
    export function response(ctx) {
      return { items: ctx.result.items, nextToken: ctx.result.nextToken, startedAt: util.time.nowEpochSeconds() };
    }
  CODE
}

# Query Events by Topic Resolver
resource "aws_appsync_resolver" "query_events_by_topic" {
  api_id      = aws_appsync_graphql_api.historical_api.id
  type        = "Query"
  field       = "queryEventsByTopic"
  data_source = aws_appsync_datasource.events_table.name
  runtime {
    name            = "APPSYNC_JS"
    runtime_version = "1.0.0"
  }
  code = <<-CODE
    import { util } from '@aws-appsync/utils';
    export function request(ctx) {
      const { topic, startTime, endTime, limit, nextToken } = ctx.args;
      let expr = '#topic = :topic';
      const names = { '#topic': 'topic' };
      const values = { ':topic': util.dynamodb.toDynamoDB(topic) };
      if (startTime && endTime) {
        expr += ' AND #ts BETWEEN :st AND :et';
        names['#ts'] = 'timestamp';
        values[':st'] = util.dynamodb.toDynamoDB(startTime);
        values[':et'] = util.dynamodb.toDynamoDB(endTime);
      } else if (startTime) {
        expr += ' AND #ts >= :st';
        names['#ts'] = 'timestamp';
        values[':st'] = util.dynamodb.toDynamoDB(startTime);
      }
      const req = {
        operation: 'Query',
        index: 'topic-timestamp-index',
        query: { expression: expr, expressionNames: names, expressionValues: values },
        limit: limit || 20,
        scanIndexForward: false
      };
      if (nextToken) req.nextToken = nextToken;
      return req;
    }
    export function response(ctx) {
      return { items: ctx.result.items, nextToken: ctx.result.nextToken, startedAt: util.time.nowEpochSeconds() };
    }
  CODE
}

# Sync Events Resolver (Delta Sync)
resource "aws_appsync_resolver" "sync_events" {
  api_id      = aws_appsync_graphql_api.historical_api.id
  type        = "Query"
  field       = "syncEvents"
  data_source = aws_appsync_datasource.events_table.name
  runtime {
    name            = "APPSYNC_JS"
    runtime_version = "1.0.0"
  }
  code = <<-CODE
    import { util } from '@aws-appsync/utils';
    export function request(ctx) {
      const { lastSync, nextToken, limit } = ctx.args;
      const req = { operation: 'Sync', limit: limit || 100, lastSync: lastSync || 0 };
      if (nextToken) req.nextToken = nextToken;
      return req;
    }
    export function response(ctx) {
      return { items: ctx.result.items, nextToken: ctx.result.nextToken, startedAt: ctx.result.startedAt };
    }
  CODE
}

# Get Latest Events Resolver
resource "aws_appsync_resolver" "get_latest_events" {
  api_id      = aws_appsync_graphql_api.historical_api.id
  type        = "Query"
  field       = "getLatestEvents"
  data_source = aws_appsync_datasource.events_table.name
  runtime {
    name            = "APPSYNC_JS"
    runtime_version = "1.0.0"
  }
  code = <<-CODE
    import { util } from '@aws-appsync/utils';
    export function request(ctx) {
      const { topic, limit } = ctx.args;
      if (topic) {
        return {
          operation: 'Query',
          index: 'topic-timestamp-index',
          query: {
            expression: '#topic = :topic',
            expressionNames: { '#topic': 'topic' },
            expressionValues: { ':topic': util.dynamodb.toDynamoDB(topic) }
          },
          limit: limit || 50,
          scanIndexForward: false
        };
      }
      return { operation: 'Scan', limit: limit || 50 };
    }
    export function response(ctx) {
      return { items: ctx.result.items, nextToken: ctx.result.nextToken, startedAt: util.time.nowEpochSeconds() };
    }
  CODE
}

# Create Event Mutation Resolver
resource "aws_appsync_resolver" "create_event" {
  api_id      = aws_appsync_graphql_api.historical_api.id
  type        = "Mutation"
  field       = "createEvent"
  data_source = aws_appsync_datasource.events_table.name
  runtime {
    name            = "APPSYNC_JS"
    runtime_version = "1.0.0"
  }
  code = <<-CODE
    import { util } from '@aws-appsync/utils';
    export function request(ctx) {
      const id = util.autoId();
      const ts = util.time.nowEpochSeconds();
      const item = {
        pk: 'EVENT#' + id, sk: 'EVENT#' + id, id: id, topic: ctx.args.topic,
        key: ctx.args.key, data: ctx.args.data, timestamp: ts,
        processedAt: util.time.nowISO8601(), ttl: ts + 2592000,
        _version: 1, _lastChangedAt: ts
      };
      return {
        operation: 'PutItem',
        key: util.dynamodb.toMapValues({ pk: item.pk, sk: item.sk }),
        attributeValues: util.dynamodb.toMapValues(item)
      };
    }
    export function response(ctx) {
      return ctx.result;
    }
  CODE
}
