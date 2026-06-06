"""GridTokenX E2E — event-bus tap (Kafka / Redis Streams).

Used to assert cross-service dissemination (Oracle -> Redis+Kafka, settlement -> NATS).
Each consumer uses a unique group id per run to avoid offset races. STUB: fill in
client wiring during Phase 2 (de-risk the tap against one real topic first).
"""
import os
import time

KAFKA_BROKER = os.getenv("KAFKA_BROKER", "localhost:29001")
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:7010")
E2E_RUN_ID = os.getenv("E2E_RUN_ID", "local")


def wait_for_kafka(topic: str, predicate, timeout: float = 15.0):
    """Poll Kafka topic until predicate(msg_value:bytes) True or timeout. Returns msg or None.

    TODO(Phase 2): implement with confluent-kafka or kafka-python.
    group_id must be unique per run: f"e2e-{E2E_RUN_ID}-{topic}".
    """
    raise NotImplementedError("wire Kafka consumer in Phase 2")


def wait_for_redis_stream(stream: str, predicate, timeout: float = 15.0):
    """Poll Redis Stream (XREAD) until predicate True or timeout.

    TODO(Phase 2): implement with redis-py XREAD BLOCK.
    """
    raise NotImplementedError("wire Redis stream reader in Phase 2")


def poll(fn, predicate, timeout: float = 15.0, interval: float = 0.5):
    """Generic poll helper: call fn() repeatedly until predicate(result) True."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = fn()
        if predicate(r):
            return r
        time.sleep(interval)
    return None
