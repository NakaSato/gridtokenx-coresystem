"""GridTokenX E2E — NATS request/reply helper for the Chain Bridge tx path.

Chain Bridge consumes signed-tx work off NATS JetStream (subjects `chain.tx.*`,
stream `CHAIN_TX`, durable pull consumer `chain-bridge-worker`) and publishes a
result back to the envelope's `reply_subject`
(`gridtokenx-chain-bridge/.../nats_consumer/consumer.rs`). The publisher side uses
plain *core* NATS request/reply (`gridtokenx-blockchain-core/.../rpc/nats_provider.rs`
notes "Core NATS is at-most-once — not JetStream"), so a core subscriber on the
reply subject receives the bridge's result regardless of which stream captures it.

This helper mirrors that: subscribe to the reply subject, publish the JSON envelope
to the work subject, await one reply. Async (nats-py is asyncio); callers wrap with
`asyncio.run`.

NATS host port is 9020 (`docker-compose.yml` maps host 9020 -> container 4222).
"""
import asyncio
import json
import os

import nats

NATS_URL = os.getenv("NATS_URL_HOST", os.getenv("E2E_NATS_URL", "nats://localhost:9020"))


def reachable(timeout: float = 3.0) -> bool:
    """True if a NATS connection can be opened (bridge work bus is up)."""
    async def _probe():
        nc = await nats.connect(NATS_URL, connect_timeout=timeout)
        await nc.close()
        return True
    try:
        return asyncio.run(_probe())
    except Exception:
        return False


async def request_reply(work_subject: str, reply_subject: str, envelope: dict,
                        *, timeout: float = 20.0) -> dict:
    """Publish `envelope` (JSON) to `work_subject` and await one JSON reply on
    `reply_subject`. Subscribes BEFORE publishing so no reply is missed. Returns the
    decoded reply dict; raises asyncio.TimeoutError if none arrives in `timeout`s."""
    nc = await nats.connect(NATS_URL, connect_timeout=5.0)
    try:
        sub = await nc.subscribe(reply_subject)
        await nc.publish(work_subject, json.dumps(envelope).encode("utf-8"))
        await nc.flush(timeout=5.0)
        msg = await sub.next_msg(timeout=timeout)
        return json.loads(msg.data.decode("utf-8"))
    finally:
        await nc.close()


def request_reply_sync(work_subject: str, reply_subject: str, envelope: dict,
                       *, timeout: float = 20.0) -> dict:
    """Blocking wrapper around `request_reply` for pytest bodies."""
    return asyncio.run(request_reply(work_subject, reply_subject, envelope, timeout=timeout))
