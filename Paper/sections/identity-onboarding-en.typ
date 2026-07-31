= IDENTITY, ONBOARDING, AND THE BINDING OF A METER TO A WALLET <sec:identity-onboarding>

_How the trust root the settlement model presupposes is actually constructed: five distinct identities, a deliberately non-atomic registration, and an optimistic-submit path that must be confirmed rather than believed._

The threat model in @sec:threat-model assumes two facts and does not establish either of them: that every reading arrives signed by a key the platform has already registered for that device, and that every verified reading can be attributed to a wallet that may receive the minted surplus. Both are the output of an onboarding procedure, not a property of the runtime. This section describes that procedure, because its failure modes turn out to be the ones that actually cost the experiments in @sec:scale-onchain-validation, and because the way it is decomposed — into steps that are allowed to fail independently — is a design decision rather than an implementation accident.

== Five Identities, Not One

What informal descriptions call "registering a meter" is the construction of five separate identities, each with its own key material, its own store, and its own failure mode. They are summarized in @tbl:identity-stack.

The first is the *account*: an email and an Argon2 password hash held by the IAM Service, created by `POST /api/v1/auth/register` and activated by `POST /api/v1/auth/verify`. Email verification, not registration, is the pivotal step — it is where every subsequent identity is provisioned.

The second is the *wallet*. On verification the platform generates a Solana keypair, encrypts the full 64-byte key under AES-256-GCM with a PBKDF2 key-derivation at 600,000 iterations, and persists the ciphertext together with the wallet row in a single database transaction, so that a key without a wallet — or an address whose key is unrecoverable — is never observable, even across a crash. The derivation takes both of its inputs from service configuration; the user's password is not among them. That is a custody decision and is discussed in @sec:thbc-payment-leg.

The third is the *on-chain user*: a `UserAccount` created by the registry program's `register_user` at the Program Derived Address seeded by `[b"user", authority]`. The fourth is the *on-chain meter*: a `MeterAccount` created by `register_meter` at `[b"meter", owner, meter_id]`, where the identifier is capped at 32 bytes because the zero-copy account layout stores it as a fixed byte array rather than a `String`. The instruction refuses to create a meter whose `owner` is not the authority recorded on the referenced user account, so a meter can only ever be created beneath its true owner's registered account even though `owner` is a non-signing account in the custodial model.

The fifth is the *device*: a per-meter Ed25519 signing key and a separate 32-byte AES key, published to the Aggregator Bridge's device registry under two Redis keys per device. These are the keys the ingest path checks on every reading, and they are entirely distinct from the wallet keypair — a meter authenticates its telemetry with one key and is paid through another.

#figure(
  placement: top,
  scope: "parent",
  caption: [The five identities constructed during onboarding, and what fails when each is missing.],
  text(size: 8pt)[
    #table(
    columns: (auto, auto, auto, 1fr),
    inset: (x: 4pt, y: 3pt),
    align: (left + horizon, left + horizon, left + horizon, left + horizon),
    table.header([Identity], [Key material], [Store], [Consequence if absent]),
    [Account], [Argon2 password hash], [Postgres (IAM)], [No authenticated API surface; nothing else can be provisioned],
    [Wallet], [Ed25519 keypair, AES-256-GCM encrypted], [Postgres (IAM)], [Verified surplus has no mint destination — readings are retained, not settled],
    [On-chain user], [none (PDA `[b"user", authority]`)], [Solana], [`register_meter` and `claim_airdrop` fail with `AccountNotInitialized`],
    [On-chain meter], [none (PDA `[b"meter", owner, id]`)], [Solana], [No account for `submit_meter_reading` to write per-meter state into],
    [Device], [Ed25519 signing key + 32-byte AES key], [Redis (bridge registry)], [Ingest fails closed at signature verification — the reading is dropped],
    )
  ],
) <tbl:identity-stack>

== Registration Is Deliberately Not Atomic

The obvious design makes onboarding one transaction: verify the email, mint the welcome grant, register on-chain, return. The system does the opposite at three separate points, and each split is a response to a concrete failure.

The welcome airdrop is not minted inside `register_user`. Solana cannot swallow a failed Cross-Program Invocation — a failing mint would abort the enclosing transaction — so folding the grant into registration would make a token-program problem into a registration outage. The grant is therefore a separate `claim_airdrop` instruction (@sec:registry-program), idempotent and retryable, and registration succeeds independently of it.

On-chain registration is not awaited by the HTTP verification response. The submit path retries with backoff for roughly 14 seconds and the confirmation poll described below adds up to another 15, so awaiting it would hold the verification response for up to half a minute on an oversubscribed validator; in practice this tripped the end-to-end suite's 10-second client timeout. Registration is spawned as a detached task, and the wallet is already persisted and usable off-chain before it runs. The consequence is stated rather than hidden: a freshly verified account is off-chain-complete and on-chain-pending, and the pending half is separately retriable through an explicit endpoint.

The key-derivation step is bounded by the same CPU semaphore the password paths use. PBKDF2 at 600,000 iterations is several hundred milliseconds of pure computation; run inline on the async runtime it starves the worker threads for every other endpoint. The effect was measured during development as a collapse of verification latency from roughly 0.8 s serial to roughly 40 s at 64 concurrent onboards. Moving it to the blocking pool is necessary but not sufficient — without the semaphore, concurrency simply spawns unbounded blocking tasks — so onboarding throughput is capped deliberately at the configured limit.

== Optimistic Submission and the Confirmation Gate

Chain Bridge returns a transaction signature without confirming execution. This is the correct interface for a write path fronted by a durable queue, but it means a signature is evidence of submission and not of landing: a dropped or simulation-rejected transaction is indistinguishable, at the call site, from a successful one. Recording such a signature as "registered" produces a database that confidently disagrees with the chain.

The service therefore does not trust the return value. It derives the user PDA locally, then polls for the account's existence — twenty attempts at 750 ms, a window of about 15 seconds chosen to absorb both the roughly 1–2 s `confirmed` commitment lag and the provider-side retry that can land the transaction several seconds after the call returns — and marks the user registered only once the account is observable. The same derivation supplies idempotency at the other end: if the PDA already exists when onboarding is requested, the service heals its own flags and returns without spending a transaction, which is what makes the provider's retry safe against the registry program's `AccountAlreadyInUse`.

This is a general point about writing to a blockchain through an asynchronous bridge, and it recurs wherever the platform does so. The authoritative record of a write is the existence of the account it was supposed to create, not the acknowledgement of the request that created it.

== Shard Binding at Registration Time

Registration is also where an entity is assigned its position in the registry's Sealevel-parallelism scheme (@sec:sealevel-sharding). Both `register_user` and `register_meter` take a `shard_id` argument, and both refuse it unless it equals the value derived from the owner's key, `shard_for(k) = k[0] mod 16`. A meter is additionally required to co-locate on its owner's shard. Counters are incremented on that shard account; the global `Registry` account is held read-only on this path precisely so that registration does not take a write lock on a single global account and serialize every concurrent onboard, with the global total reconciled afterwards by `aggregate_shards`.

The derivation is not a hint the client may choose to follow. Because the required value is a pure function of a key the caller does not control, a caller cannot scatter counts across arbitrary shards, and the shard assignment is reproducible by any party that knows the key — including the settlement path, which must find the same accounts later.

== Attribution at Ingest

Onboarding produces the binding; the ingest path consumes it once per reading. After a frame has been decrypted and its signature verified, the Aggregator Bridge resolves the meter serial to an owner and a wallet through a three-tier lookup: a process-local cache, then Redis, then a Postgres owner read model that repopulates the tiers above it. A serial that misses every tier is recorded in a negative cache with its own expiry, so an unregistered device cannot turn each of its readings into a database round-trip.

An unresolved serial does not fail the reading — it de-attributes it. The reading is admitted, disseminated, and counted, but it has no wallet to settle into. This is the correct behavior for a metering system, in which discarding a physically valid measurement because the platform's records are incomplete is the worse error, and it is the mechanism behind the "no wallet registered, kept for retry" outcome reported in @sec:scale-onchain-validation, where surplus was withheld rather than lost and re-minted into its original settlement window once the wallet links were repaired. It also means that the *liveness* of attribution rests on an eventually-consistent projection: the ingest path reads a local read model, and a reading that arrives before that projection catches up is attributed on retry rather than at first sight.

== What Onboarding Does Not Establish

It is worth stating plainly what this procedure does and does not deliver. It establishes that a reading came from a device the platform enrolled, and that the device belongs to an account the platform verified. It does not establish that the device measures what it claims to measure — meter tampering is outside the cryptographic boundary, as noted in @sec:threat-model — and it does not establish user custody of the wallet it provisions. The keypair is generated by the platform, encrypted under platform secrets with no user-supplied input to the derivation, and stored beside its salt. The platform can therefore reconstruct any user's key. This is a settled architectural posture rather than a latent gap, and it is treated as such in @sec:thbc-payment-leg, where it appears as a disclosed and violated invariant rather than as a caveat.
