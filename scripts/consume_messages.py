#!/usr/bin/env python3
"""
Kafka Consumer Script for MSK with IAM Authentication
Reads messages from a specified topic using the public endpoint.

Requirements:
    pip install kafka-python aws-msk-iam-sasl-signer

Usage:
    python consume_messages.py --topic taxi-trips
    python consume_messages.py --topic taxi-trips --from-beginning
    python consume_messages.py --topic taxi-trips --max-messages 10
"""

import argparse
import json
from kafka import KafkaConsumer, KafkaAdminClient
from kafka.admin import NewTopic
from kafka.sasl.oauth import AbstractTokenProvider
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider

# MSK Public Bootstrap Servers (port 9198 for public IAM access)
BOOTSTRAP_SERVERS = [
    "b-1-public.taxikafkamsk.upxkpz.c19.kafka.us-east-1.amazonaws.com:9198",
    "b-2-public.taxikafkamsk.upxkpz.c19.kafka.us-east-1.amazonaws.com:9198",
    "b-3-public.taxikafkamsk.upxkpz.c19.kafka.us-east-1.amazonaws.com:9198"
]
REGION = "us-east-1"


class MSKTokenProvider(AbstractTokenProvider):
    """Token provider for MSK IAM authentication"""
    def token(self):
        token, _ = MSKAuthTokenProvider.generate_auth_token(REGION)
        return token


def list_topics():
    """List all topics in the cluster"""
    print("Connecting to MSK cluster...")
    admin = KafkaAdminClient(
        bootstrap_servers=BOOTSTRAP_SERVERS,
        security_protocol="SASL_SSL",
        sasl_mechanism="OAUTHBEARER",
        sasl_oauth_token_provider=MSKTokenProvider(),
    )
    topics = admin.list_topics()
    print(f"\n📋 Available Topics ({len(topics)}):")
    for topic in sorted(topics):
        print(f"  - {topic}")
    admin.close()
    return topics


def consume_messages(topic: str, from_beginning: bool = False, max_messages: int = None):
    """Consume messages from a Kafka topic"""
    print(f"\n🔌 Connecting to MSK cluster...")
    print(f"📥 Topic: {topic}")
    print(f"📍 Starting from: {'beginning' if from_beginning else 'latest'}")
    if max_messages:
        print(f"📊 Max messages: {max_messages}")
    print("-" * 60)

    consumer = KafkaConsumer(
        topic,
        bootstrap_servers=BOOTSTRAP_SERVERS,
        security_protocol="SASL_SSL",
        sasl_mechanism="OAUTHBEARER",
        sasl_oauth_token_provider=MSKTokenProvider(),
        auto_offset_reset='earliest' if from_beginning else 'latest',
        enable_auto_commit=True,
        group_id='local-consumer-group',
        consumer_timeout_ms=10000,  # 10 second timeout
    )

    print(f"✅ Connected! Waiting for messages...\n")
    
    message_count = 0
    try:
        for message in consumer:
            message_count += 1
            print(f"📨 Message #{message_count}")
            print(f"   Partition: {message.partition}")
            print(f"   Offset: {message.offset}")
            print(f"   Timestamp: {message.timestamp}")
            
            # Try to decode key
            key = message.key
            if key:
                try:
                    key = key.decode('utf-8')
                except:
                    key = key.hex()
            print(f"   Key: {key}")
            
            # Try to decode value - handle UTF-8, JSON, or binary
            value = message.value
            if value:
                try:
                    # Try UTF-8 decoding first
                    decoded = value.decode('utf-8')
                    # Try to parse as JSON
                    try:
                        value = json.loads(decoded)
                        print(f"   Value: {json.dumps(value, indent=6)}")
                    except json.JSONDecodeError:
                        print(f"   Value: {decoded}")
                except UnicodeDecodeError:
                    # Binary data - show as hex with preview
                    print(f"   Value (binary, {len(value)} bytes): {value[:100].hex()}...")
            else:
                print(f"   Value: None")
            print()

            if max_messages and message_count >= max_messages:
                print(f"✋ Reached max messages limit ({max_messages})")
                break

    except KeyboardInterrupt:
        print("\n⏹️ Stopped by user")
    finally:
        consumer.close()
        print(f"\n📊 Total messages consumed: {message_count}")


def main():
    parser = argparse.ArgumentParser(description='Consume messages from MSK Kafka topic')
    parser.add_argument('--topic', '-t', default='taxi-trips', help='Topic name (default: taxi-trips)')
    parser.add_argument('--from-beginning', '-b', action='store_true', help='Read from beginning of topic')
    parser.add_argument('--max-messages', '-m', type=int, help='Maximum number of messages to consume')
    parser.add_argument('--list-topics', '-l', action='store_true', help='List all available topics')
    
    args = parser.parse_args()

    if args.list_topics:
        list_topics()
    else:
        consume_messages(args.topic, args.from_beginning, args.max_messages)


if __name__ == "__main__":
    main()
