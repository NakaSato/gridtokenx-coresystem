"""GridTokenX E2E — event-bus tap (Kafka / Redis Streams).

Used to assert cross-service dissemination (Oracle -> Redis+Kafka, settlement -> NATS).
Each consumer uses a unique group id per run to avoid offset races. The Kafka tap is
implemented against the Oracle dissemination topic `meter.readings`; the Redis-stream
path is covered directly in 20_oracle via lib/redis_util.
"""
import os
import time

KAFKA_BROKER = os.getenv("KAFKA_BROKER", "localhost:29001")
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:7010")
E2E_RUN_ID = os.getenv("E2E_RUN_ID", "local")


def kafka_broker_up(timeout: float = 4.0) -> bool:
    """True if the Kafka broker answers a metadata request (cheap reachability probe)."""
    try:
        from confluent_kafka.admin import AdminClient
        AdminClient({"bootstrap.servers": KAFKA_BROKER,
                     "socket.timeout.ms": int(timeout * 1000)}).list_topics(timeout=timeout)
        return True
    except Exception:
        return False


def kafka_tap(topic: str):
    """Open a consumer positioned at the CURRENT END of every partition of `topic`.

    Returns (consumer, ok_bool). Assigning explicitly to the high-watermark offsets —
    rather than subscribe()+auto.offset.reset — means the tap reads only messages
    produced AFTER this call, with no consumer-group rebalance/join race: we never see
    stale events from prior runs, and we never miss the event we trigger. Caller must
    drain then close() the returned consumer.
    """
    from confluent_kafka import Consumer, TopicPartition

    consumer = Consumer({
        "bootstrap.servers": KAFKA_BROKER,
        "group.id": f"e2e-{E2E_RUN_ID}-{topic}-tap",
        "enable.auto.commit": False,
        "auto.offset.reset": "latest",
        "socket.timeout.ms": 5000,
    })
    md = consumer.list_topics(topic, timeout=5)
    tmd = md.topics.get(topic)
    if tmd is None or tmd.error is not None or not tmd.partitions:
        consumer.close()
        return None, False
    tps = []
    for pid in tmd.partitions:
        # high watermark = next offset that will be written -> start reading there.
        _lo, hi = consumer.get_watermark_offsets(TopicPartition(topic, pid), timeout=5)
        tps.append(TopicPartition(topic, pid, hi))
    consumer.assign(tps)
    return consumer, True


def drain_kafka(consumer, predicate, timeout: float = 15.0):
    """Poll an already-assigned (kafka_tap'd) consumer until predicate(value: bytes) is
    True or timeout. Returns the matching message value (bytes) or None."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        msg = consumer.poll(0.5)
        if msg is None or msg.error():
            continue
        val = msg.value()
        try:
            if predicate(val):
                return val
        except Exception:
            continue
    return None


def wait_for_kafka(topic: str, predicate, timeout: float = 15.0):
    """Open a tap at the topic end and return the first message value (bytes) whose
    predicate is True, or None on timeout. NOTE: opens the tap then waits, so only use
    this when the producing action happens AFTER this call returns its consumer is not
    possible — when you must open the tap, then act, then wait, use kafka_tap()+
    drain_kafka() explicitly (see 20_oracle test_kafka_dissemination_fanout)."""
    consumer, ok = kafka_tap(topic)
    if not ok:
        return None
    try:
        return drain_kafka(consumer, predicate, timeout)
    finally:
        consumer.close()


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
