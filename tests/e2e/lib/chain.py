"""GridTokenX E2E — Chain Bridge gRPC read client.

All on-chain reads go through Chain Bridge (never direct Solana RPC) per architecture rule.
STUB: generate Chain Bridge proto stubs into tests/e2e/proto/ and wire in Phase 3.
"""
import os

CHAIN_BRIDGE_GRPC = os.getenv("CHAIN_BRIDGE_GRPC", "localhost:5040")


def _stub():
    """TODO(Phase 3): build grpc channel + ChainBridge stub from generated proto.
    Mirror tests/e2e/proto/ pattern used for oracle_pb2."""
    raise NotImplementedError("generate Chain Bridge proto + channel in Phase 3")


def get_balance(account: str) -> int:
    """Token/lamport balance for account via Chain Bridge gRPC."""
    raise NotImplementedError("Phase 3")


def get_account(pubkey: str) -> dict:
    """Raw account data for pubkey (e.g. verify Registry PDA exists)."""
    raise NotImplementedError("Phase 3")


def get_slot() -> int:
    """Current slot — liveness probe for Chain Bridge -> validator."""
    raise NotImplementedError("Phase 3")
