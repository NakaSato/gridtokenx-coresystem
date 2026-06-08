#!/bin/bash
# RabbitMQ Initialization Script for GridTokenX
# This script creates exchanges, queues, and bindings on first startup

set -e

RABBITMQ_URL="${RABBITMQ_URL:-amqp://gridtokenx:rabbitmq_secret_2025@localhost:9031}"
RABBITMQ_USER="${RABBITMQ_DEFAULT_USER:-gridtokenx}"
RABBITMQ_PASS="${RABBITMQ_DEFAULT_PASS:-rabbitmq_secret_2025}"

echo "🐰 Waiting for RabbitMQ to start..."
sleep 10

echo "🐰 Setting up RabbitMQ exchanges, queues, and bindings..."

# Enable management plugin
rabbitmq-plugins enable rabbitmq_management

# Declare exchanges
rabbitmqadmin declare exchange name=notifications type=topic durable=true
rabbitmqadmin declare exchange name=trading type=topic durable=true
rabbitmqadmin declare exchange name=aggregator type=topic durable=true
rabbitmqadmin declare exchange name=scheduler type=topic durable=true
rabbitmqadmin declare exchange name=integrations type=topic durable=true
rabbitmqadmin declare exchange name=dlx.exchange type=direct durable=true

# Declare queues with DLQ policy
rabbitmqadmin declare queue name=email.notifications durable=true arguments='{"x-dead-letter-exchange":"dlx.exchange"}'
rabbitmqadmin declare queue name=password.resets durable=true arguments='{"x-dead-letter-exchange":"dlx.exchange"}'
rabbitmqadmin declare queue name=settlement.retries durable=true arguments='{"x-dead-letter-exchange":"dlx.exchange","x-max-priority":10}'
rabbitmqadmin declare queue name=meter.validation durable=true arguments='{"x-dead-letter-exchange":"dlx.exchange"}'
rabbitmqadmin declare queue name=batch.jobs durable=true arguments='{"x-dead-letter-exchange":"dlx.exchange"}'
rabbitmqadmin declare queue name=webhook.deliveries durable=true arguments='{"x-dead-letter-exchange":"dlx.exchange"}'

# Declare DLQ
rabbitmqadmin declare queue name=dlq durable=true

# Bind queues to exchanges
rabbitmqadmin declare binding source=notifications destination=email.notifications routing_key="email.*"
rabbitmqadmin declare binding source=trading destination=settlement.retries routing_key="settlement.retry"
rabbitmqadmin declare binding source=oracle destination=meter.validation routing_key="meter.validate"
rabbitmqadmin declare binding source=scheduler destination=batch.jobs routing_key="batch.*"
rabbitmqadmin declare binding source=integrations destination=webhook.deliveries routing_key="webhook.*"

echo "✅ RabbitMQ setup complete!"
echo "📊 Management UI: http://localhost:9031"
echo "🔑 Username: $RABBITMQ_USER"
echo "🔑 Password: $RABBITMQ_PASS"
