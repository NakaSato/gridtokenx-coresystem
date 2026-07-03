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
# Token-2022 — the GRID / energy-token mint is a Token-2022 mint (the on-chain
# mint instruction `build_mint_to_wallet_instruction` derives the destination ATA
# under spl_token_2022::id()), so GRID ATA reads MUST use this program id, not the
# classic TOKEN_PROGRAM_ID above.
TOKEN_2022_PROGRAM_ID = Pubkey.from_string("TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb")
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


def get_latest_blockhash() -> str:
    """Recent blockhash (base58) — needed to build a landable/simulatable tx.
    Read through Chain Bridge (GetLatestBlockhash RPC), never direct Solana RPC."""
    return _call("GetLatestBlockhash", {})["blockhash"]


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


def ata(owner: str, mint: str, token_program: Pubkey = TOKEN_2022_PROGRAM_ID) -> str:
    """Derive the Associated Token Account address for (owner, mint).

    Mirrors spl-associated-token-account: PDA of
    [owner, token_program, mint] under the ATA program. Defaults to Token-2022
    because the GRID / energy-token mint is a Token-2022 mint; pass
    TOKEN_PROGRAM_ID explicitly for a classic SPL-Token mint.
    """
    pda, _bump = Pubkey.find_program_address(
        [bytes(Pubkey.from_string(owner)), bytes(token_program), bytes(Pubkey.from_string(mint))],
        ASSOCIATED_TOKEN_PROGRAM_ID,
    )
    return str(pda)


def grid_mint_pda(energy_token_program_id: str) -> str:
    """Derive the GRID (energy-token) mint PDA = find_program_address([b"mint_2022"],
    energy_token_program_id). The mint is a program-derived account, so given the
    energy-token program id it is resolvable without bootstrap output (matches
    blockchain-core build_mint_to_wallet_instruction get_mint_pda)."""
    pda, _bump = Pubkey.find_program_address(
        [b"mint_2022"], Pubkey.from_string(energy_token_program_id)
    )
    return str(pda)


def token_balance_of(owner: str, mint: str, token_program: Pubkey = TOKEN_2022_PROGRAM_ID) -> int:
    """Convenience: base-unit GRID balance held by `owner` for `mint` (0 if the
    ATA does not exist yet). Defaults to the Token-2022 ATA derivation."""
    try:
        return get_token_account_balance(ata(owner, mint, token_program))["amount"]
    except ChainBridgeError:
        return 0


def escrow_pda(owner: str, mint: str, trading_program_id: str) -> str:
    """Derive a trading-program custodial escrow token account: PDA of
    [b"escrow", owner, mint] under the trading program (settle_offchain.rs:423-456
    — buyer/seller currency + energy escrows all share this seed scheme)."""
    pda, _bump = Pubkey.find_program_address(
        [b"escrow", bytes(Pubkey.from_string(owner)), bytes(Pubkey.from_string(mint))],
        Pubkey.from_string(trading_program_id),
    )
    return str(pda)


def escrow_balance_of(owner: str, mint: str, trading_program_id: str) -> int:
    """Convenience: base-unit balance in `owner`'s custodial escrow for `mint`
    (0 if the escrow account has not been funded/created yet)."""
    try:
        return get_token_account_balance(escrow_pda(owner, mint, trading_program_id))["amount"]
    except ChainBridgeError:
        return 0
