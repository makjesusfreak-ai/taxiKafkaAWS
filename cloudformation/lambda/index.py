import json
import os
import base64
import urllib.request
import urllib.error
import uuid
import io
import struct
from datetime import datetime
from decimal import Decimal

# Try to import fastavro for Avro decoding
try:
    import fastavro
    FASTAVRO_AVAILABLE = True
except ImportError:
    FASTAVRO_AVAILABLE = False
    print("fastavro not available, Avro decoding will return raw bytes")

# AppSync Event API configuration
APPSYNC_HTTP_ENDPOINT = os.environ.get('APPSYNC_HTTP_ENDPOINT')
APPSYNC_API_KEY = os.environ.get('APPSYNC_API_KEY')
GLUE_REGISTRY_NAME = os.environ.get('GLUE_REGISTRY_NAME')
SCHEMA_AUTO_REGISTRATION = os.environ.get('SCHEMA_AUTO_REGISTRATION', 'true').lower() == 'true'
EVENTS_TABLE = os.environ.get('EVENTS_TABLE')
HISTORICAL_RETENTION_DAYS = int(os.environ.get('HISTORICAL_RETENTION_DAYS', '30'))

# Try to import boto3 for DynamoDB
try:
    import boto3
    from botocore.config import Config
    
    config = Config(
        retries={'max_attempts': 3, 'mode': 'adaptive'}
    )
    dynamodb = boto3.resource('dynamodb', config=config)
    events_table = dynamodb.Table(EVENTS_TABLE) if EVENTS_TABLE else None
    glue_client = boto3.client('glue', config=config)
    DYNAMODB_AVAILABLE = True
except ImportError:
    DYNAMODB_AVAILABLE = False
    events_table = None
    glue_client = None
    print("boto3 not available, DynamoDB persistence disabled")

# Cache for parsed Avro schemas
_schema_cache = {}


class DecimalEncoder(json.JSONEncoder):
    """JSON encoder that handles Decimal types from DynamoDB."""
    def default(self, obj):
        if isinstance(obj, Decimal):
            return float(obj)
        return super().default(obj)


def get_avro_schema(schema_version_id):
    """
    Fetch and cache Avro schema from Glue Schema Registry by version ID.
    """
    if schema_version_id in _schema_cache:
        return _schema_cache[schema_version_id]
    
    if not glue_client:
        print("Glue client not available")
        return None
    
    try:
        response = glue_client.get_schema_version(
            SchemaVersionId=schema_version_id
        )
        schema_def = json.loads(response['SchemaDefinition'])
        parsed_schema = fastavro.parse_schema(schema_def) if FASTAVRO_AVAILABLE else schema_def
        _schema_cache[schema_version_id] = parsed_schema
        print(f"Cached schema for version {schema_version_id}")
        return parsed_schema
    except Exception as e:
        print(f"Error fetching schema {schema_version_id}: {e}")
        return None


def get_schema_by_name(schema_name):
    """
    Fetch and cache Avro schema from Glue Schema Registry by schema name.
    """
    cache_key = f"name:{schema_name}"
    if cache_key in _schema_cache:
        return _schema_cache[cache_key]
    
    if not glue_client or not GLUE_REGISTRY_NAME:
        print("Glue client or registry name not available")
        return None
    
    try:
        response = glue_client.get_schema_version(
            SchemaId={
                'RegistryName': GLUE_REGISTRY_NAME,
                'SchemaName': schema_name
            },
            SchemaVersionNumber={'LatestVersion': True}
        )
        schema_def = json.loads(response['SchemaDefinition'])
        parsed_schema = fastavro.parse_schema(schema_def) if FASTAVRO_AVAILABLE else schema_def
        _schema_cache[cache_key] = parsed_schema
        print(f"Cached schema for name {schema_name}")
        return parsed_schema
    except Exception as e:
        print(f"Error fetching schema by name {schema_name}: {e}")
        return None


def decode_avro_payload(avro_bytes, schema):
    """
    Decode Avro binary data using the provided schema.
    """
    if not FASTAVRO_AVAILABLE:
        return {"raw_bytes": base64.b64encode(avro_bytes).decode('utf-8'), "decode_error": "fastavro not available"}
    
    try:
        reader = io.BytesIO(avro_bytes)
        record = fastavro.schemaless_reader(reader, schema)
        return record
    except Exception as e:
        print(f"Error decoding Avro: {e}")
        return {"raw_bytes": base64.b64encode(avro_bytes).decode('utf-8'), "decode_error": str(e)}


def deserialize_message(raw_bytes, topic):
    """
    Deserialize message - handles Avro (with/without Glue Schema Registry header) and JSON.
    
    Glue Schema Registry header format:
    - Byte 0: Header version (0x03)
    - Byte 1: Compression type (0x00 = none, 0x05 = zlib)
    - Bytes 2-17: Schema version UUID (16 bytes)
    - Remaining bytes: Avro payload
    
    Raw Avro format (no header):
    - Direct Avro binary data, first byte often 0x00-0x02 for union/record types
    """
    # Map topic names to schema names in Glue Registry
    TOPIC_SCHEMA_MAP = {
        'taxi-trips': 'taxi-trip-schema',
        'taxi-rides': 'taxi-trip-schema',
        'taxi-trip-schema': 'taxi-trip-schema',
        'taxi-locations': 'taxi-locations',
    }
    
    # Check for Glue Schema Registry header (starts with version byte 0x03)
    if len(raw_bytes) > 18 and raw_bytes[0] == 0x03:
        try:
            print(f"Detected Glue Schema Registry encoded message for topic {topic}")
            compression = raw_bytes[1]
            # Extract schema version UUID (bytes 2-17)
            schema_uuid_bytes = raw_bytes[2:18]
            schema_version_id = str(uuid.UUID(bytes=schema_uuid_bytes))
            print(f"Schema version ID: {schema_version_id}")
            
            avro_payload = raw_bytes[18:]
            
            # Handle compression
            if compression == 0x05:  # zlib
                import zlib
                avro_payload = zlib.decompress(avro_payload)
                print("Decompressed zlib payload")
            
            # Fetch schema and decode
            schema = get_avro_schema(schema_version_id)
            if schema:
                decoded = decode_avro_payload(avro_payload, schema)
                print(f"Successfully decoded Avro message: {list(decoded.keys()) if isinstance(decoded, dict) else 'non-dict'}")
                return decoded
            else:
                return {"raw_bytes": base64.b64encode(avro_payload).decode('utf-8'), "schema_version_id": schema_version_id}
        except Exception as e:
            print(f"Schema Registry deserialization failed: {e}")
            return {"raw_bytes": base64.b64encode(raw_bytes).decode('utf-8'), "error": str(e)}
    
    # Try to decode as UTF-8 JSON first
    try:
        return json.loads(raw_bytes.decode('utf-8'))
    except (json.JSONDecodeError, UnicodeDecodeError):
        pass
    
    # Try raw Avro decoding for known topics
    schema_name = TOPIC_SCHEMA_MAP.get(topic)
    if schema_name and FASTAVRO_AVAILABLE:
        schema = get_schema_by_name(schema_name)
        if schema:
            print(f"Attempting raw Avro decode for topic {topic} using schema {schema_name}")
            decoded = decode_avro_payload(raw_bytes, schema)
            if isinstance(decoded, dict) and 'decode_error' not in decoded:
                print(f"Successfully decoded raw Avro message: {list(decoded.keys())}")
                return decoded
            else:
                print(f"Raw Avro decode failed: {decoded.get('decode_error', 'unknown error')}")
    
    # Fallback: return raw bytes
    return {"raw_bytes": base64.b64encode(raw_bytes).decode('utf-8')}


def save_to_dynamodb(event_payload):
    """
    Save event to DynamoDB for historical queries and Delta Sync.
    Uses PULocationID as partition key for location-based queries, with
    Kafka coordinates (partition + offset) as sort key for deduplication.
    """
    if not events_table:
        print("DynamoDB table not configured, skipping persistence")
        return None
    
    try:
        # Extract Kafka metadata
        topic = event_payload.get('topic', 'unknown')
        partition = event_payload.get('partition', 0)
        offset = event_payload.get('offset', 0)
        
        # Extract taxi ride data from the decoded message
        data = event_payload.get('data', {})
        
        # Get location IDs from the taxi data (for pk/sk)
        pu_location_id = data.get('PULocationID')
        do_location_id = data.get('DOLocationID')
        
        # Get location coordinates (new fields from updated schema)
        pickup_longitude = data.get('pickup_longitude')
        pickup_latitude = data.get('pickup_latitude')
        dropoff_longitude = data.get('dropoff_longitude')
        dropoff_latitude = data.get('dropoff_latitude')
        
        # Get trip timestamps
        pickup_datetime = data.get('tpep_pickup_datetime', '')
        dropoff_datetime = data.get('tpep_dropoff_datetime', '')
        
        # Create deterministic event_id from Kafka coordinates
        event_id = f"{topic}-{partition}-{offset}"
        
        timestamp = int(datetime.utcnow().timestamp())
        event_timestamp = event_payload.get('timestamp', timestamp)
        ttl = timestamp + (HISTORICAL_RETENTION_DAYS * 24 * 60 * 60)
        
        # Convert floats to Decimal for DynamoDB
        def convert_to_decimal(obj):
            if isinstance(obj, float):
                return Decimal(str(obj))
            elif isinstance(obj, dict):
                return {k: convert_to_decimal(v) for k, v in obj.items()}
            elif isinstance(obj, list):
                return [convert_to_decimal(v) for v in obj]
            return obj
        
        # Use PULocationID as partition key for efficient location-based queries
        # Fall back to topic-based key if PULocationID is not available
        if pu_location_id is not None:
            pk = f"LOC#{pu_location_id}"
        else:
            pk = f"TOPIC#{topic}"
        
        item = {
            'pk': pk,                                     # Partition by pickup location for geo queries
            'sk': f"P#{partition}#O#{offset}",          # Sort key = partition + offset (natural dedup)
            'id': event_id,
            'topic': topic,
            'partition': partition,
            'offset': offset,
            'timestamp': event_timestamp,
            'key': event_payload.get('key'),
            # Store location IDs as top-level attributes for GSI queries
            'PULocationID': pu_location_id,
            'DOLocationID': do_location_id,
            # Store coordinates as top-level attributes for geo queries
            'pickup_longitude': convert_to_decimal(pickup_longitude) if pickup_longitude is not None else None,
            'pickup_latitude': convert_to_decimal(pickup_latitude) if pickup_latitude is not None else None,
            'dropoff_longitude': convert_to_decimal(dropoff_longitude) if dropoff_longitude is not None else None,
            'dropoff_latitude': convert_to_decimal(dropoff_latitude) if dropoff_latitude is not None else None,
            # Store trip times for time-range queries
            'pickup_datetime': pickup_datetime,
            'dropoff_datetime': dropoff_datetime,
            # Store full data as JSON for complete record
            'data': json.dumps(data, cls=DecimalEncoder),
            'processedAt': event_payload.get('processed_at', datetime.utcnow().isoformat()),
            'ttl': ttl,
            '_version': 1,
            '_lastChangedAt': timestamp
        }
        
        # Remove None values
        item = {k: v for k, v in item.items() if v is not None}
        
        events_table.put_item(Item=item)
        print(f"Saved event {event_id} to DynamoDB")
        return event_id
    except Exception as e:
        print(f"Error saving to DynamoDB: {str(e)}")
        return None


def batch_save_to_dynamodb(event_payloads):
    """
    Batch save events to DynamoDB for better performance.
    Uses PULocationID as partition key for location-based queries, with
    Kafka coordinates (partition + offset) as sort key for deduplication.
    """
    if not events_table or not event_payloads:
        return []
    
    saved_ids = []
    timestamp = int(datetime.utcnow().timestamp())
    ttl = timestamp + (HISTORICAL_RETENTION_DAYS * 24 * 60 * 60)
    
    # Convert floats to Decimal for DynamoDB
    def convert_to_decimal(obj):
        if isinstance(obj, float):
            return Decimal(str(obj))
        elif isinstance(obj, dict):
            return {k: convert_to_decimal(v) for k, v in obj.items()}
        elif isinstance(obj, list):
            return [convert_to_decimal(v) for v in obj]
        return obj
    
    try:
        with events_table.batch_writer() as batch:
            for event_payload in event_payloads:
                # Extract Kafka metadata
                topic = event_payload.get('topic', 'unknown')
                partition = event_payload.get('partition', 0)
                offset = event_payload.get('offset', 0)
                
                # Extract taxi ride data from the decoded message
                data = event_payload.get('data', {})
                
                # Get location IDs from the taxi data (for pk/sk)
                pu_location_id = data.get('PULocationID')
                do_location_id = data.get('DOLocationID')
                
                # Get location coordinates (new fields from updated schema)
                pickup_longitude = data.get('pickup_longitude')
                pickup_latitude = data.get('pickup_latitude')
                dropoff_longitude = data.get('dropoff_longitude')
                dropoff_latitude = data.get('dropoff_latitude')
                
                # Get trip timestamps
                pickup_datetime = data.get('tpep_pickup_datetime', '')
                dropoff_datetime = data.get('tpep_dropoff_datetime', '')
                
                # Create deterministic event_id from Kafka coordinates
                event_id = f"{topic}-{partition}-{offset}"
                event_timestamp = event_payload.get('timestamp', timestamp)
                
                # Use PULocationID as partition key for efficient location-based queries
                # Fall back to topic-based key if PULocationID is not available
                if pu_location_id is not None:
                    pk = f"LOC#{pu_location_id}"
                else:
                    pk = f"TOPIC#{topic}"
                
                item = {
                    'pk': pk,                                     # Partition by pickup location for geo queries
                    'sk': f"P#{partition}#O#{offset}",          # Sort key = partition + offset (natural dedup)
                    'id': event_id,
                    'topic': topic,
                    'partition': partition,
                    'offset': offset,
                    'timestamp': event_timestamp,
                    'key': event_payload.get('key'),
                    # Store location IDs as top-level attributes for GSI queries
                    'PULocationID': pu_location_id,
                    'DOLocationID': do_location_id,
                    # Store coordinates as top-level attributes for geo queries
                    'pickup_longitude': convert_to_decimal(pickup_longitude) if pickup_longitude is not None else None,
                    'pickup_latitude': convert_to_decimal(pickup_latitude) if pickup_latitude is not None else None,
                    'dropoff_longitude': convert_to_decimal(dropoff_longitude) if dropoff_longitude is not None else None,
                    'dropoff_latitude': convert_to_decimal(dropoff_latitude) if dropoff_latitude is not None else None,
                    # Store trip times for time-range queries
                    'pickup_datetime': pickup_datetime,
                    'dropoff_datetime': dropoff_datetime,
                    # Store full data as JSON for complete record
                    'data': json.dumps(data, cls=DecimalEncoder),
                    'processedAt': event_payload.get('processed_at', datetime.utcnow().isoformat()),
                    'ttl': ttl,
                    '_version': 1,
                    '_lastChangedAt': timestamp
                }
                
                # Remove None values
                item = {k: v for k, v in item.items() if v is not None}
                
                batch.put_item(Item=item)
                saved_ids.append(event_id)
        
        print(f"Batch saved {len(saved_ids)} events to DynamoDB")
    except Exception as e:
        print(f"Error in batch save to DynamoDB: {str(e)}")
    
    return saved_ids


def publish_to_appsync(channel, event_data):
    """
    Publish an event to AppSync Event API for real-time streaming.
    """
    if not APPSYNC_HTTP_ENDPOINT:
        print("APPSYNC_HTTP_ENDPOINT not configured")
        return False
    
    url = f"{APPSYNC_HTTP_ENDPOINT}/event"
    
    payload = {
        "channel": channel,
        "events": [json.dumps(event_data, cls=DecimalEncoder)]
    }
    
    headers = {
        "Content-Type": "application/json"
    }
    
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
    Lambda handler for MSK events.
    Processes Kafka messages, stores in DynamoDB, and publishes to AppSync Event API.
    """
    total_records = sum(len(records) for records in event.get('records', {}).values())
    print(f"Received event with {total_records} records")
    
    processed_count = 0
    error_count = 0
    saved_count = 0
    
    # Collect all event payloads for batch DynamoDB write
    all_event_payloads = []
    
    # Process each record from MSK
    for topic_partition, records in event.get('records', {}).items():
        topic = topic_partition.rsplit('-', 1)[0]
        
        for record in records:
            try:
                raw_value = base64.b64decode(record.get('value', ''))
                message_data = deserialize_message(raw_value, topic)
                
                key = None
                if record.get('key'):
                    key = base64.b64decode(record['key']).decode('utf-8')
                
                event_payload = {
                    "topic": topic,
                    "partition": record.get('partition'),
                    "offset": record.get('offset'),
                    "timestamp": record.get('timestamp'),
                    "key": key,
                    "data": message_data,
                    "processed_at": datetime.utcnow().isoformat()
                }
                
                all_event_payloads.append(event_payload)
                
                # Publish to AppSync Event API for real-time streaming
                channel = f"/kafka/{topic}"
                if publish_to_appsync(channel, event_payload):
                    processed_count += 1
                else:
                    error_count += 1
                    
            except Exception as e:
                print(f"Error processing record: {str(e)}")
                error_count += 1
    
    # Batch save to DynamoDB for historical queries
    if all_event_payloads:
        saved_ids = batch_save_to_dynamodb(all_event_payloads)
        saved_count = len(saved_ids)
    
    result = {
        "statusCode": 200,
        "body": {
            "processed": processed_count,
            "saved": saved_count,
            "errors": error_count
        }
    }
    
    print(f"Processing complete: {result}")
    return result
