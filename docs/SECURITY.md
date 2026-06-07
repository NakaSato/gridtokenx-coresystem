# Security (Engineering Deep-Dive)

> Policy, reporting, and the defense-in-depth overview live in the root
> [`../SECURITY.md`](../SECURITY.md). **This** doc is the engineering threat model — the assets,
> adversaries, and the trust boundaries that drive design.

## Assets to Protect

| Asset | Why it matters | Primary control |
| :--- | :--- | :--- |
| Wallet private keys | Control of user funds/energy assets | AES-256-GCM at rest; Vault Transit signing in prod |
| Telemetry integrity | False readings → false money | Ed25519 sig verified at Oracle Bridge |
| On-chain settlement | Final value movement | Single door (Chain Bridge); idempotent tx |
| PII | PDPA / legal | Tagged at ingest; Vault-encrypted; erasure tooling |
| Service identity | Lateral movement | SPIFFE/SVID + mTLS |

## Trust Boundaries

```
Untrusted: public internet, edge devices
   │  APISIX :4001 (user, HTTPS/WSS) ── authn/JWT, rate limit, CORS
   │  Envoy  :4002 (device, mTLS)    ── per-device cert, Ed25519 verify
   ▼
Semi-trusted: service mesh (mTLS + SPIFFE)
   ▼
Guarded: Chain Bridge ── sole holder of RPC creds + signing keys
   ▼
Trusted root: Solana ledger
```

A request earns trust by crossing each boundary's check. Nothing skips a boundary.

## Adversary Model

| Adversary | Capability | Mitigation |
| :--- | :--- | :--- |
| Malicious edge device | Forge / replay telemetry | Sig verification + dedup; reject unsigned |
| Sybil flooder | Exhaust on-chain resources | Off-chain filtering before settlement |
| Compromised service | Sign rogue tx | Only Chain Bridge signs; SVID-scoped mesh authz |
| Network MITM | Intercept traffic | mTLS device-side and service-side |
| SQL injection | Exfiltrate / corrupt DB | SQLx compile-time checked, parameterized only |
| Log scraper | Harvest secrets from logs | `#[instrument(skip(...))]`; no key/token logging |

## Invariants (must never break)

1. A private key never appears in plaintext at rest, in logs, or on the wire.
2. Unsigned or signature-invalid telemetry never reaches settlement.
3. No service other than Chain Bridge holds Solana RPC credentials or signs transactions.
4. All SQL is parameterized — no string-built queries, ever.
5. Value-moving operations are idempotent and safe to replay.

## Contributor Rules

See the checklist in the root [`../SECURITY.md`](../SECURITY.md#security-best-practices-for-contributors)
and the enforced conventions in [`../CLAUDE.md`](../CLAUDE.md).

> ℹ️ **Chain Bridge bind address:** it binds `0.0.0.0` (verified `main.rs:102`), **not** loopback.
> Do not treat a loopback bind as the isolation control — the boundary is **mTLS + role/RBAC**. Dev
> reads require `CHAIN_BRIDGE_INSECURE=true`.
