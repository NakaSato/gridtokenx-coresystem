# Security Policy

> Last reviewed: 2026-07-17

## Reporting a Vulnerability

If you discover a security vulnerability in GridTokenX, please report it responsibly.

**DO NOT** create a public GitHub issue for security vulnerabilities.

### Contact

- **Email**: security@gridtokenx.com
- **Response Time**: We aim to acknowledge reports within 48 hours and provide a resolution timeline within 7 days.

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Potential impact assessment
- Suggested remediation (if any)

---

## Supported Versions

| Version | Supported |
|:---|:---|
| 0.1.x (current) | ✅ Active development |

---

## Security Model Overview

GridTokenX implements defense-in-depth across all layers:

### Authentication & Authorization

- **JWT tokens** with scoped claims and configurable expiration
- **API keys** for service-to-service authentication (IAM-verified, including Aggregator Bridge ingest)
- **argon2id** password hashing (with bcrypt fallback)
- **RBAC** (Role-Based Access Control) enforced at the API gateway and service level

### Wallet & Key Security

- **Private keys** encrypted at rest with AES-256-GCM using a master secret
- **Never stored in plaintext** — encrypted before database persistence
- **Chain Bridge** signs via **HashiCorp Vault Transit** (not from disk or environment variables in production; dev mode supports keypair files)

### Edge Device Security

- **Ed25519 signature verification** on every telemetry packet at the Aggregator Bridge IoT gateway — the primary device-authentication boundary
- **Per-device key identity** verified cryptographically on ingest
- **Optional telemetry hardening (off by default, `just secure-up` to enable):** the smart-meter → Aggregator Bridge DLMS path layers TLS, **mutual TLS** (client-cert auth), per-meter **AES-256-GCM** payload encryption with a replay counter (`dlms-enc` envelope; secure mode rejects plaintext downgrade), **Vault-KEK-wrapped key rotation** (raw key never at rest), and an **ingest lockdown** that rejects every bypass. This restores transport-level mTLS for the meter path that the former Envoy edge (`:4002`) gave up — see [docs/telemetry-security.md](docs/telemetry-security.md) and `docs/exec-plans/tech-debt-tracker.md` (TD-003)

### Service Mesh Security

- **SPIFFE workload identity** — services authenticate via X.509 SVIDs (SPIFFE URIs embedded in mTLS certificates), issued from the dev CA by `just gen-certs`
- **mTLS between services** on the sensitive paths (Chain Bridge gRPC + signed NATS envelopes; Aggregator Bridge `/metrics` scrape)
- **SPIFFE URI format**: `spiffe://gridtokenx.th/prod/<service>`
- **Signed NATS envelopes** — Chain Bridge authenticates async submissions by cert → CA → SPIFFE SAN → P256 signature (enforced when `CHAIN_BRIDGE_REQUIRE_SIGNED_NATS=true`)

### Data Security

- **SQLx compile-time query verification** — prevents SQL injection by design
- **Parameterized queries** everywhere — no string concatenation for SQL
- **PDPA compliance** — PII tagged at ingest, purpose tracking, right-to-erasure tooling
- **Vault-encrypted PII** at rest

### Infrastructure Security

- **Chain Bridge isolation is mTLS + role/RBAC, not bind address** — it binds `0.0.0.0`
  (verified `gridtokenx-chain-bridge/crates/chain-bridge-api/src/main.rs:251`); network
  exposure is gated by mutual TLS and per-role authorization, not by a loopback-only bind
- **Single signing path** — all Solana transactions flow through Chain Bridge; no other service holds signing keys or speaks Solana RPC
- **No debug logging of keys or instructions** in production
- **Rate limiting** at gateway (APISIX) and service level
- **CORS** properly configured per environment

---

## Security Best Practices for Contributors

1. **Never commit secrets.** Check `.env` is in `.gitignore`. Use environment variables.
2. **Never log sensitive data.** Use `#[instrument(skip(password, token, key))]` with tracing.
3. **Never use `.unwrap()` on user input.** Always validate and return proper errors.
4. **Always use parameterized queries.** SQLx enforces this at compile time.
5. **Review crypto operations carefully.** Key generation, encryption, and signing must use constant-time operations.

---

## References

- [ARCHITECTURE.md](ARCHITECTURE.md) — System map, hard architecture rules, component index
- [docs/SECURITY.md](docs/SECURITY.md) — Security plane details and invariants
- [docs/telemetry-security.md](docs/telemetry-security.md) — Meter-path hardening (mTLS, dlms-enc, key rotation)
- [gridtokenx-iam-service/README.md](gridtokenx-iam-service/README.md) — IAM security model
