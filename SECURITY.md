# Security Policy

> Last reviewed: 2026-04-16

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
- **API keys** for service-to-service authentication
- **argon2id** password hashing (with bcrypt fallback)
- **RBAC** (Role-Based Access Control) enforced at the API gateway and service level

### Wallet & Key Security
- **Private keys** encrypted at rest with AES-256-GCM using a master secret
- **Never stored in plaintext** — encrypted before database persistence
- **Chain Bridge** loads signing keys from **HashiCorp Vault Transit** (not from disk or environment variables in production)

### Edge Device Security
- **Ed25519 signature verification** on every telemetry packet at the Aggregator Bridge IoT gateway — the primary device-authentication boundary
- **Per-device key identity** verified cryptographically on ingest
- **Note:** the former Envoy mTLS edge (`:4002`) has been removed; IoT devices now ingress directly to the Aggregator Bridge. Transport-level mTLS for the edge path is no longer enforced — see `docs/exec-plans/tech-debt-tracker.md` (TD-003)

### Service Mesh Security
- **SPIFFE/SPIRE** workload identity — services authenticate via cryptographic SVIDs
- **mTLS between services** via Istio service mesh
- **SPIFFE URI format**: `spiffe://gridtokenx.th/prod/<service>`

### Data Security
- **SQLx compile-time query verification** — prevents SQL injection by design
- **Parameterized queries** everywhere — no string concatenation for SQL
- **PDPA compliance** — PII tagged at ingest, purpose tracking, right-to-erasure tooling
- **Vault-encrypted PII** at rest

### Infrastructure Security
- **Chain Bridge isolation is mTLS + role/RBAC, not bind address** — it binds `0.0.0.0`
  (verified `main.rs:102`); network exposure is gated by mutual TLS and per-role authorization,
  not by a loopback-only bind
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
- [gridtokenx-iam-service/README.md](gridtokenx-iam-service/README.md) — IAM security model
