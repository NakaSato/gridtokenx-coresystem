= SYSTEM MODEL AND THREAT MODEL <sec:threat-model>

_Actors, trust assumptions, and adversaries — forged meter readings, replay, and unauthorized mint or settlement — with residual trust made explicit before the settlement model._

This section defines the system model, the actors, the trust assumptions, and the adversary model of the simulated system, so that the security boundaries of the layered architecture are clear before the discussion of the settlement model in @sec:settlement-model. Since the scope of this work is a design on a simulated system, the analysis below states, in a straightforward manner, both the threats that the current mechanisms mitigate and the trust that still remains (residual trust).

== System Model and Actors
The system comprises the following principal actors:
- Smart Meter (edge device): an endpoint device that holds a per-device Ed25519 key pair and signs energy readings before transmitting them.
- Aggregator Bridge: the off-chain validation and aggregation layer. It verifies the Ed25519 signature of every reading against the device's public key, decrypts the payload according to the DLMS/COSEM standard, and evaluates the surplus-energy and grid-stability conditions.
- Trading Service: matches buy/sell orders using a Continuous Double Auction (CDA).
- Chain Bridge: acts as the Reference Monitor and is the only service that holds the signing key and calls Solana RPC directly. Every transaction written to the chain is forced through a single signing path.
- Anchor Programs: the on-chain rule-enforcement layer that accepts only already-validated order pairs and serves as the settlement and audit layer.
- PoA / Governance Authority: the principal policy authority of the consortium that controls REC certification, authority permissions, and the aggregator allow-list.

== Trust Assumptions
The system's trust assumptions are enforced across three boundaries: the device-to-bridge boundary, the service-to-service boundary, and the service-to-chain boundary.

At the device-to-bridge boundary, each device's identity is bound to a registered Ed25519 public key. The Aggregator Bridge verifies the signature of every reading (64-byte signature, 32-byte public key), both per-reading and in batch, using a fail-closed policy: when a key is not found or the key store is unresponsive, the system rejects (errors) rather than implicitly accepting the reading. The binary DLMS/COSEM payload is encrypted with AES-256-GCM using the per-device key. In production mode, if a device has no encryption key, that frame is skipped (fail-closed), and the plaintext path is enabled only in development mode through an explicit configuration.

At the service-to-service boundary for chain writes (in particular the path to the Chain Bridge), communication uses ConnectRPC over mutually authenticated TLS (mTLS), binding service identity with a SPIFFE @spiffe2018 X.509 identity verified from the client-side certificate during the handshake. Access permissions are derived from the SPIFFE URI of the verified certificate, mapped to a service role such as `AggregatorBridge`, `TradingMatcher`, or `SettlementService`. Identity is considered from the transport layer (L4), not from application headers (L7); an unverified caller is assigned the role `Unknown`. Note that the meter-data ingest path at the Aggregator Bridge uses request-level authentication via an API key (verified through IAM with a static key fallback) combined with the per-reading Ed25519 signature, not mTLS/SPIFFE. The authentication bypass (insecure mode) that grants full permissions is intended for development mode only.

At the service-to-chain boundary, the Chain Bridge is the only service that holds the key and submits transactions. The signing key is stored in HashiCorp Vault Transit (Ed25519) and never enters process memory; signing is restricted to the explicitly authorized key name only. For the asynchronous write path over NATS JetStream @natsio2024, the publisher must sign the message envelope with an ECDSA P-256 signature over the canonical bytes of the envelope, which is verified against the public key in the publisher's client certificate. The Chain Bridge verifies the chain (certificate → CA → SPIFFE SAN → service identity → signature) before the RBAC step, and value-moving subjects, such as minting energy tokens, are always required to carry a signed envelope.

== Adversary Model and Mitigations
The adversary model considers an attacker who can craft, intercept, or replay messages on the network and may attempt to impersonate a device or service identity, but cannot access the private keys stored in Vault or the per-device keys. The threats considered and their mitigating mechanisms are summarized in @tbl:threats.

#figure(
  placement: top,
  scope: "parent",
  caption: [Threats considered and the mechanism that mitigates each.],
  text(size: 8pt)[
    #table(
    columns: (auto, 1fr, 1fr),
    inset: (x: 4pt, y: 3pt),
    align: (left + horizon, left + horizon, left + horizon),
    table.header([Threat], [Description], [Mitigation]),
    [T1 Forged/replayed reading], [Forge or replay a meter reading], [Per-reading Ed25519 signature verification (fail-closed) + the per-`(meter_id, window)` `gen_mint` PDA, which absorbs a replayed reading into the window it belongs to],
    [T2 Service impersonation], [Impersonate a service in the mesh], [mTLS + SPIFFE identity → service role; unverified callers get `Unknown`],
    [T3 Forged publisher / mint], [Submit a forged chain-write command over NATS], [Signed envelope bound to the certificate; mint subjects require a signature],
    [T4 Replayed on-chain order pair], [Settle the same order pair twice], [Order nullifier account (PDA) — settle only once],
    [T5 Duplicate/over-authorized mint], [Mint more tokens than actual production], [Idempotency key `(meter_id, window)` + PDA + REC co-signing],
    )
  ],
) <tbl:threats>

== Residual Trust and Out-of-Scope
The system retains residual trust that must be stated explicitly. First, the Aggregator Bridge and the governance/oracle authority attest to the surplus-energy and grid-stability conditions in the off-chain layer, and these conditions are not re-verified on-chain; users must therefore trust the correctness of this off-chain validation layer. Compromise or collusion of the Aggregator Bridge or the oracle authority is not yet prevented by cryptographic mechanisms in the current prototype; approaches to further reduce trust, such as multi-oracle attestation or cryptographic proof, are future work (see @sec:discussion_limitations). Second, the security of the consensus layer (PoH combined with Tower BFT) rests on the assumption of a permissioned network that controls validator participation via PoA, where validators are authorized entities behaving according to policy — an architectural assumption that has not yet been quantitatively evaluated. Third, the authentication bypasses for development mode (insecure mode and plaintext fallback) must be disabled in production; otherwise they would break all of the above trust assumptions.

== Bounding the Trust Graph: the ERP Direction Invariant <sec:erp-direction-invariant>
The residual trust stated above has a specific shape: the unconditionally trusted set is small — the Aggregator Bridge, which attests that a reading is genuine, and the Chain Bridge, which holds the only signing key. A design that keeps this set small is worth more than one that merely adds mechanisms, because every additional service holding mint or settlement authority enlarges the set of principals whose compromise is unrecoverable. This subsection states the rule the architecture uses to integrate an enterprise system without enlarging it.

Integrating the utility's own billing system is operationally necessary — the utility's ERP, not this platform, remains the authority for the customer invoice — but a naive integration would take the unconditionally trusted set from two principals to three. The architecture instead constrains the ERP connector to be a *strictly downstream consumer*: no response, acknowledgement, or read-back originating from the ERP may influence a mint, a settlement, or any on-chain write. The ERP is a sink and a witness, never an oracle.

The invariant is enforced in depth rather than by convention. The connector holds no signing key and has no policy binding to the Vault Transit backend, so it cannot produce a signature the Chain Bridge would accept; its only secret-store access is a read of the client credential for the enterprise gateway. Its advisory publisher accepts a closed enumeration of subjects rather than an arbitrary subject string and refuses any subject outside its own namespace, so the chain-write subjects are not merely unused but unaddressable. Most usefully for review, the constraint is checked against the build artifact rather than asserted in prose: a test reads the resolved dependency lockfile and fails if the shared blockchain crate, the Solana client libraries, or the Anchor client libraries appear anywhere in the transitive graph, and a companion test scans every source file for a chain-write subject literal. A future revision that reintroduced a path to the chain would fail the build rather than silently widen the trust boundary. A complementary control — omitting the connector's service identity from the Chain Bridge authorization list, so that a publish would be refused at the bridge even if the code were changed — is specified but lives in bridge configuration and is not exercised here.

The security consequence is worth stating precisely, because it is easy to overclaim. Compromising the ERP connector yields *false enterprise records*, which reconciliation against the chain detects; it does not yield fraudulent minting. The attack surface grows, but the mint trust graph does not. The gain runs in the other direction: because the utility's system holds an independently sourced meter reading, divergence between the three records — meter, chain, and ERP — becomes observable. This is the first *detective* control the architecture has against a compromised Aggregator Bridge, which is otherwise trusted unconditionally at the point where a reading is admitted. It is detective and not preventive: it reports a discrepancy after the fact rather than preventing a forged attestation, and it does not close the attestation gap identified above, for which hardware-backed or multi-party attestation remains future work.

Two limits apply to this claim in the present prototype. The connector's first phase is implemented against a mock enterprise adapter; the adapter for a real enterprise system builds its payload but deliberately refuses to transmit, and the downstream posting and certificate-registry paths remain switched off by configuration flags. Furthermore, the enterprise-side interface model is written against a canonical utilities schema and would require per-utility validation before deployment, since the module footprint of a specific utility is not established from public sources. The three-way divergence check is therefore a property of the design and of the enforced direction invariant, not a measured result, and it is not evaluated in @sec:evaluation.
