# Terraform (local Docker provider)

Infrastructure-as-code mirror of the root `docker-compose.yml` — all 35 services,
3 networks, 16 volumes — targeting the local Docker daemon (OrbStack) via the
[kreuzwerker/docker](https://registry.terraform.io/providers/kreuzwerker/docker/latest)
provider. Works with OpenTofu (`tofu`) or Terraform (`terraform`) ≥ 1.6.

## Relationship to docker-compose.yml

- **Configuration source is identical**: the repo's `.env` is parsed in
  `locals.tf`, so Compose and Terraform read the same values.
  `coalesce(lookup(...))` mirrors compose `${VAR:-default}` semantics.
  Limitation: no inline `# comments` after values in `.env`.
- **Container/volume/network names are identical** — Terraform adopts the
  Compose-created volumes (`gridtokenx-coresystem_*`), so data survives the
  switch. Consequence: **the two stacks cannot run at the same time**, and
  `tofu destroy` deletes the same data volumes Compose was using.
- **App images are still built by Compose** (`docker compose build`). The
  Docker provider builds BuildKit Dockerfiles poorly, so Terraform manages
  runtime only and references `gridtokenx-coresystem-<service>:latest`.
- Compose `condition: service_healthy` → `depends_on` + `wait = true` on the
  dependency (Terraform blocks until the container reports healthy).
- Compose `deploy.resources.limits` → `memory` / `cpu_period`+`cpu_quota`.
  Reservations are dropped (scheduler hints only; provider doesn't support them).

## Usage

```bash
# 1. Build app images (once, or after code changes)
docker compose build

# 2. Stop the compose-managed stack (same container names!)
docker compose down

# 3. Bring the stack up under Terraform
cd terraform
tofu init
tofu plan
tofu apply
```

Back to Compose: `tofu destroy` (or `tofu state rm` everything to orphan the
containers), then `docker compose up -d`.

## Files

| File | Contents |
| --- | --- |
| `versions.tf` | provider requirements + docker host |
| `locals.tf` | `.env` parsing, shared env groups (Kafka brokers, RabbitMQ URL, Chain-Bridge mTLS client set) |
| `network_storage.tf` | 3 networks, 16 named volumes (Compose-compatible names) |
| `images.tf` | pinned registry images |
| `infra.tf` | postgres, pgdog, redis, kafka×3 (for_each), rabbitmq, nats, vault, mailpit, influxdb |
| `apps.tf` | apisix, chain-bridge, iam, meter, trading, aggregator, noti |
| `frontends.tf` | trading-ui, explorer, smartmeter sim + ui, openleadr vtn/db/seed |
| `observability.tf` | prometheus, exporters×4, cadvisor, grafana, loki, alloy, tempo |
| `outputs.tf` | service URLs |

## Gotchas

- **DNS aliases**: Compose auto-aliases each service by service name; here every
  container declares `networks_advanced.aliases = ["<service>"]` explicitly.
  Removing an alias breaks inter-service URLs (`pgdog:6432`, `chain-bridge:5040`, …).
- The Solana validator stays **native on the host** (`host.docker.internal:8899`),
  exactly as with Compose.
- `no-new-privileges` is applied everywhere except cadvisor (privileged) and
  vault (needs the `cap_ipc_lock` file capability) — same as Compose.
- The one-shot `openleadr-vtn-seed` container has `must_run = false`; it exits 0
  after seeding.
