"""GridTokenX E2E — Chain Bridge read client (ConnectRPC over HTTP+JSON).

All on-chain reads go through Chain Bridge (never direct Solana RPC) per the
architecture rule. Chain Bridge exposes `gridtokenx.chain.v1.ChainBridgeService`
as ConnectRPC, callable as a plain HTTP POST + JSON body — so no proto codegen is
needed (same pattern as suite 50_chain_bridge).

Reads require a ServiceRole header. In dev the server runs with
CHAIN_BRIDGE_INSECURE=true (grants Admin) or CHAIN_BRIDGE_ALLOW_HEADER_AUTH=1
(trusts `x-gridtokenx-role`); otherwise strict mTLS is required and the HTTP reads
here will be refused (callers should skip).

Also provides Associated-Token-Account derivation (`ata`) so callers can read a
prosumer's GRID balance via GetTokenAccountBalance (suite 30 settlement check).
"""
import os

import requests
from solders.pubkey import Pubkey

CHAIN_BRIDGE_GRPC = os.getenv("CHAIN_BRIDGE_GRPC", "localhost:5040")
BASE = os.getenv("CHAIN_BRIDGE_HTTP", f"http://{CHAIN_BRIDGE_GRPC}")
SVC = "gridtokenx.chain.v1.ChainBridgeService"
ROLE = os.getenv("CHAIN_BRIDGE_ROLE", "admin")

# SPL Token + Associated-Token programs (fixed on every Solana cluster).
TOKEN_PROGRAM_ID = Pubkey.from_string("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")
ASSOCIATED_TOKEN_PROGRAM_ID = Pubkey.from_string("ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL")


class ChainBridgeError(RuntimeError):
    """Non-200 Connect response (carries the structured Connect error body)."""


def _call(method: str, body: dict, timeout: float = 8.0) -> dict:
    h = {"Content-Type": "application/json", "x-gridtokenx-role": ROLE}
    r = requests.post(f"{BASE}/{SVC}/{method}", json=body, headers=h, timeout=timeout)
    if r.status_code != 200:
        raise ChainBridgeError(f"{method} -> {r.status_code}: {r.text}")
    return r.json()


def reachable(timeout: float = 4.0) -> bool:
    """True if Chain Bridge answers a GetSlot over plain HTTP with our role
    (i.e. up AND not in strict-mTLS-only mode)."""
    try:
        _call("GetSlot", {}, timeout=timeout)
        return True
    except (requests.RequestException, ChainBridgeError):
        return False


def get_slot() -> int:
    """Current slot — liveness probe for Chain Bridge -> validator."""
    return int(_call("GetSlot", {})["slot"])


def get_balance(pubkey: str, force_refresh: bool = False) -> int:
    """Lamport balance for an account."""
    body = _call("GetBalance", {"pubkey": pubkey, "forceRefresh": force_refresh})
    return int(body["lamports"])


def get_account_data(pubkey: str) -> dict:
    """Raw account data (e.g. confirm a Registry PDA exists)."""
    return _call("GetAccountData", {"pubkey": pubkey})


def get_token_account_balance(token_account: str) -> dict:
    """SPL token balance for a token account (ATA).

    Returns {"amount": int (base units), "decimals": int, "ui_amount": float}.
    Raises ChainBridgeError if the account does not exist / is not a token account.
    """
    b = _call("GetTokenAccountBalance", {"pubkey": token_account})
    return {
        "amount": int(b.get("amount", 0)),
        "decimals": int(b.get("decimals", 0)),
        "ui_amount": float(b.get("uiAmount", b.get("ui_amount", 0.0)) or 0.0),
    }


def ata(owner: str, mint: str) -> str:
    """Derive the Associated Token Account address for (owner, mint).

    Mirrors spl-associated-token-account: PDA of
    [owner, TOKEN_PROGRAM_ID, mint] under the ATA program.
    """
    pda, _bump = Pubkey.find_program_address(
        [bytes(Pubkey.from_string(owner)), bytes(TOKEN_PROGRAM_ID), bytes(Pubkey.from_string(mint))],
        ASSOCIATED_TOKEN_PROGRAM_ID,
    )
    return str(pda)


def token_balance_of(owner: str, mint: str) -> int:
    """Convenience: base-unit GRID balance held by `owner` for `mint` (0 if the
    ATA does not exist yet)."""
    try:
        return get_token_account_balance(ata(owner, mint))["amount"]
    except ChainBridgeError:
        return 0
