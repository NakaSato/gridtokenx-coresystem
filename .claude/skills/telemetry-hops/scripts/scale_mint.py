#!/usr/bin/env python3
"""Fleet-scale e2e mint benchmark: onboard N meters, force N surplus bins, count mints.

Drives the full Path-A pipeline at scale and measures each hop:
  A. onboard  — IAM register→verify→login + meter claim (onboard_fleet, concurrent),
                then pipeline the Ed25519 pubkeys + AES enckeys into the bridge Redis
                device registry (raw RESP SETs, fast at any fleet size).
  B. ingest   — one signed (and AES-256-GCM sealed, secure stack) surplus reading per
                meter, all binned into the SAME already-completed 15-min window so the
                settlement sweep flushes every bin within ~30s of ingest finishing.
  C. mint     — poll Prometheus `aggregator_mint_total` deltas (settled/queued/failed)
                until settled >= expected or progress stalls; report mint throughput.

Serials are deterministic (`scalemeter:{i}`), so tiers nest: a 10_000-meter run reuses
the 1_000-meter tier's already-onboarded fleet and only onboards the delta (owner cache
+ IAM login-first idempotency). Each run MUST use a fresh settlement window per meter
set — chain-bridge dedups on `mint:<meter>:<window_ms>` — so pass a unique
--window-offset per run (auto-bumped via the state file by default).

Run from gridtokenx-smartmeter-simulator/backend:
  AGGREGATOR_BRIDGE_URL=https://localhost:4030 \
  AGGREGATOR_API_KEY=engineering-department-api-key-2025 \
  REDIS_URL=redis://localhost:7010 \
    uv run python <this> --meters 1000
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.append(os.path.join(os.getcwd(), "src"))

import httpx  # noqa: E402

from smart_meter_simulator.config import get_config  # noqa: E402
from smart_meter_simulator.models.reading import EnergyReading  # noqa: E402
from smart_meter_simulator.transport.aggregator_bridge import (  # noqa: E402
    AggregatorBridgeClient,
    MeterKey,
    register_enckeys_redis,
    register_meter_owners_redis,
    register_pubkeys_redis,
)
from smart_meter_simulator.transport.iam_onboarding import (  # noqa: E402
    IamOnboardingClient,
    load_owner_cache,
    onboard_fleet,
    save_owner_cache,
)

WINDOW_MIN = 15
GRACE_S = 120
SERIAL_NS = uuid.uuid5(uuid.NAMESPACE_DNS, "gridtokenx-scale-mint")
STATE_DIR = Path(__file__).resolve().parent / ".scale-state"
OWNER_CACHE = STATE_DIR / "owners.json"
RUN_STATE = STATE_DIR / "run-state.json"
RESULTS = STATE_DIR / "results.jsonl"


def serials_for(n: int) -> list[str]:
    return [str(uuid.uuid5(SERIAL_NS, f"scalemeter:{i:07d}")) for i in range(n)]


def _auto_mtls(bridge_url: str) -> dict:
    if not bridge_url.lower().startswith("https"):
        return {}
    crt = os.getenv("E2E_TLS_CERT")
    key = os.getenv("E2E_TLS_KEY")
    ca = os.getenv("E2E_TLS_CA")
    if not (crt and key):
        root = os.path.abspath(os.path.join(os.path.dirname(__file__), *([".."] * 4)))
        certs = os.path.join(root, "infra", "certs")
        dc = os.path.join(certs, "clients", "smartmeter-simulator.crt")
        dk = os.path.join(certs, "clients", "smartmeter-simulator.key")
        dca = os.path.join(certs, "ca.crt")
        if os.path.exists(dc) and os.path.exists(dk):
            crt, key = dc, dk
            ca = ca or (dca if os.path.exists(dca) else None)
    if crt and key:
        return {"client_cert": (crt, key), "verify": ca if ca else False}
    return {}


def _next_window_offset() -> int:
    """Monotonic per-run window offset so no two runs share a settlement window."""
    state = {}
    if RUN_STATE.is_file():
        try:
            state = json.loads(RUN_STATE.read_text())
        except ValueError:
            state = {}
    offset = int(state.get("next_window_offset", 0))
    state["next_window_offset"] = offset + 1
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    RUN_STATE.write_text(json.dumps(state))
    return offset


def _window_ts(offset: int) -> datetime:
    """A timestamp inside a 15-min window already closed past grace, offset windows back."""
    t = (
        datetime.now(timezone.utc)
        - timedelta(seconds=GRACE_S)
        - timedelta(minutes=WINDOW_MIN * (offset + 1))
    )
    floored = (t.minute // WINDOW_MIN) * WINDOW_MIN
    return t.replace(minute=floored, second=30, microsecond=0)


MINT_LOG_RE = None  # compiled lazily


async def _minted_serials_since(since: str) -> dict[str, tuple[str, int, datetime | None]]:
    """Parse aggregator logs since `since` → {serial: (sig, slot, log_ts)} for minted lines.

    Uses `docker logs -t` so every line carries a host-side RFC3339Nano timestamp,
    independent of the service's own log format — that timestamp is the mint-confirmed
    moment (aggregator logs the line only after chain-bridge replies CONFIRMED).
    """
    global MINT_LOG_RE
    import re

    if MINT_LOG_RE is None:
        MINT_LOG_RE = re.compile(
            r"minted [\d.]+ kWh surplus for meter ([0-9a-f-]{36}) \(sig=(\w+), slot=(\d+)\)"
        )
    proc = await asyncio.create_subprocess_exec(
        "docker", "logs", "-t", "gridtokenx-aggregator-bridge", "--since", since,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    out, _ = await proc.communicate()
    found: dict[str, tuple[str, int, datetime | None]] = {}
    for line in out.decode(errors="replace").splitlines():
        m = MINT_LOG_RE.search(line)
        if not m:
            continue
        ts: datetime | None = None
        try:
            # docker -t prefix: 2026-07-03T00:16:00.123456789Z <line>
            raw = line.split(" ", 1)[0].strip()
            ts = datetime.fromisoformat(raw[:26] + "+00:00" if raw.endswith("Z") else raw)
        except ValueError:
            pass
        found[m.group(1)] = (m.group(2), int(m.group(3)), ts)
    return found


NO_WALLET_LOG_RE = None  # compiled lazily


async def _no_wallet_serials_since(since: str) -> set[str]:
    """Parse aggregator logs since `since` for "no wallet registered" warnings.

    These are meters whose *owner* has no linked wallet in Postgres, so
    settlement can never mint for them no matter how many times the durable
    outbox retries the (unresolvable) lookup — a onboard_fleet caching gap
    (owner cached on user_id alone; see iam_onboarding.onboard_fleet), not a
    stale-reject / congestion issue. Distinct from `_chain_bridge_churn`
    (chain-bridge-side dedup/staleness), this is aggregator-side owner
    resolution failure.
    """
    global NO_WALLET_LOG_RE
    import re

    if NO_WALLET_LOG_RE is None:
        NO_WALLET_LOG_RE = re.compile(
            r"no wallet registered for meter ([0-9a-f-]{36})"
        )
    proc = await asyncio.create_subprocess_exec(
        "docker", "logs", "gridtokenx-aggregator-bridge", "--since", since,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    out, _ = await proc.communicate()
    found: set[str] = set()
    for line in out.decode(errors="replace").splitlines():
        m = NO_WALLET_LOG_RE.search(line)
        if m:
            found.add(m.group(1))
    return found


async def phase_repair_wallets(serials: list[str], iam_url: str, concurrency: int) -> dict:
    """Re-attempt IAM wallet-link only, for meters already onboarded (have a
    user_id) but whose owner never got a primary wallet — the specific gap
    `onboard_fleet` leaves open (it caches on user_id alone, so a wallet-link
    failure during a prior fleet-scale onboard is never retried on later
    runs). Cheap: login-first (existing verified account), then the same
    idempotent `_link_primary_wallet` onboarding already does — no register,
    no meter re-claim.
    """
    if not serials:
        return {"attempted": 0, "wallet_ok": 0, "wallet_failed": 0}
    print(f"[repair] re-linking wallets for {len(serials)} stuck meters")
    sem = asyncio.Semaphore(max(1, concurrency))
    ok = 0
    failed: list[str] = []

    async with IamOnboardingClient(iam_url) as client:

        async def _one(serial: str) -> None:
            nonlocal ok
            async with sem:
                try:
                    res = await client.onboard_meter(serial)
                except httpx.HTTPError as exc:
                    failed.append(serial)
                    print(f"[repair]   {serial}: transport error {exc}")
                    return
            if res.wallet_address:
                ok += 1
            else:
                failed.append(serial)

        await asyncio.gather(*(_one(s) for s in serials))

    print(f"[repair] wallet_ok={ok}/{len(serials)} wallet_failed={len(failed)}")
    return {
        "attempted": len(serials),
        "wallet_ok": ok,
        "wallet_failed": len(failed),
        "failed_sample": failed[:10],
    }


async def _chain_bridge_churn(window_ms: int, since: str) -> dict:
    """Count stale-rejects / duplicate detections / dedup replays for OUR window
    in chain-bridge logs (its Prometheus recorder is NoopMetrics — logs are truth)."""
    proc = await asyncio.create_subprocess_exec(
        "docker", "logs", "gridtokenx-chain-bridge", "--since", since,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    out, _ = await proc.communicate()
    tag = f":{window_ms}"
    stale = dup = replay = 0
    for line in out.decode(errors="replace").splitlines():
        if tag not in line:
            continue
        if "Rejecting stale mint" in line:
            stale += 1
        elif "Duplicate mint detected" in line:
            dup += 1
        elif "Dedup hit" in line:
            replay += 1
    return {"stale_rejected": stale, "duplicate_detected": dup, "dedup_replayed": replay}


async def _prom_mint_totals(prom_url: str) -> dict[str, float]:
    """Snapshot aggregator_mint_total{outcome,reason} via the Prometheus API.
    NOTE: polluted by the background simulator — use deltas, label as noisy."""
    try:
        async with httpx.AsyncClient(timeout=5.0) as c:
            r = await c.get(
                f"{prom_url}/api/v1/query", params={"query": "aggregator_mint_total"}
            )
            r.raise_for_status()
            out: dict[str, float] = {}
            for row in r.json()["data"]["result"]:
                lbl = row["metric"]
                key = f"{lbl.get('outcome', '?')}/{lbl.get('reason', '')}".rstrip("/")
                out[key] = out.get(key, 0.0) + float(row["value"][1])
            return out
    except Exception as exc:  # prom down must never kill a multi-hour run
        print(f"[prom] snapshot failed ({exc!r}) — continuing without")
        return {}


def _tps_stats(minted: dict[str, tuple[str, int, datetime | None]]) -> dict:
    """On-chain TPS + spread stats from per-mint (sig, slot, log_ts)."""
    tss = sorted(ts for _, _, ts in minted.values() if ts is not None)
    slots = [slot for _, slot, _ in minted.values() if slot]
    n = len(minted)
    stats: dict = {"mints_with_ts": len(tss)}
    if len(tss) >= 2:
        span = (tss[-1] - tss[0]).total_seconds()
        stats["first_mint_utc"] = tss[0].isoformat()
        stats["last_mint_utc"] = tss[-1].isoformat()
        stats["span_seconds"] = round(span, 1)
        stats["overall_tps"] = round(n / span, 2) if span > 0 else float(n)
        # 10s buckets → steady-state TPS = median non-empty bucket rate
        buckets: dict[int, int] = {}
        for ts in tss:
            b = int((ts - tss[0]).total_seconds() // 10)
            buckets[b] = buckets.get(b, 0) + 1
        rates = sorted(v / 10.0 for v in buckets.values())
        stats["steady_tps_median_10s"] = round(rates[len(rates) // 2], 2)
        stats["peak_tps_10s"] = round(rates[-1], 2)
        # completion spread percentiles (s after first mint)
        stats["spread_p50_s"] = round(
            (tss[len(tss) // 2] - tss[0]).total_seconds(), 1
        )
        stats["spread_p95_s"] = round(
            (tss[min(len(tss) - 1, int(len(tss) * 0.95))] - tss[0]).total_seconds(), 1
        )
    if len(slots) >= 2 and max(slots) > min(slots):
        stats["slot_span"] = max(slots) - min(slots)
        # ~400ms/slot on the local validator → independent on-chain cross-check
        stats["slot_span_tps"] = round(n / ((max(slots) - min(slots)) * 0.4), 2)
    return stats


async def phase_onboard(serials: list[str], iam_url: str, concurrency: int) -> dict:
    cache = load_owner_cache(str(OWNER_CACHE))
    todo = [s for s in serials if s not in cache]
    print(
        f"[onboard] fleet={len(serials)} cached={len(serials) - len(todo)} "
        f"new={len(todo)} concurrency={concurrency}"
    )
    t0 = time.monotonic()
    new_owners: dict[str, str] = {}
    # Chunked so the owner cache survives a mid-onboard crash (IAM OOM etc.) —
    # a killed run resumes from the last saved chunk instead of re-logging
    # every already-created user.
    CHUNK = 500
    for i in range(0, len(todo), CHUNK):
        chunk = todo[i : i + CHUNK]
        got = await onboard_fleet(iam_url, chunk, concurrency=concurrency)
        new_owners.update(got)
        cache.update(got)
        save_owner_cache(str(OWNER_CACHE), cache)
        el = time.monotonic() - t0
        done_n = i + len(chunk)
        print(
            f"[onboard]   {done_n}/{len(todo)} ({len(new_owners)} ok, "
            f"{len(new_owners)/el if el else 0:.1f}/s, cache saved)"
        )
    dt = time.monotonic() - t0
    ok = len(new_owners)
    rate = ok / dt if dt > 0 and ok else 0.0
    print(
        f"[onboard] new_ok={ok}/{len(todo)} in {dt:.1f}s "
        f"({rate:.1f} onboards/s); total_owned={sum(1 for s in serials if s in cache)}"
    )
    return {
        "fleet": len(serials),
        "new_attempted": len(todo),
        "new_ok": ok,
        "cached": len(serials) - len(todo),
        "seconds": round(dt, 2),
        "onboards_per_sec": round(rate, 2),
        "owners": {s: cache[s] for s in serials if s in cache},
    }


def phase_register_keys(serials: list[str], redis_url: str, owners: dict) -> dict:
    t0 = time.monotonic()
    keys = [MeterKey(s) for s in serials]
    n_pub = register_pubkeys_redis(redis_url, keys)
    n_enc = register_enckeys_redis(redis_url, keys)
    # Warm the bridge owner cache so 500k+ ingest doesn't stampede Postgres.
    n_own = register_meter_owners_redis(redis_url, owners) if owners else 0
    dt = time.monotonic() - t0
    print(f"[keys] pubkeys={n_pub} enckeys={n_enc} owners_seeded={n_own} in {dt:.1f}s")
    return {"pubkeys": n_pub, "enckeys": n_enc, "owners_seeded": n_own, "seconds": round(dt, 2)}


async def phase_ingest(
    serials: list[str],
    kwh: float,
    zones: int,
    concurrency: int,
    window_offset: int,
) -> dict:
    cfg = get_config()
    ts = _window_ts(window_offset)
    win = ts.replace(second=0)
    encrypt = cfg.aggregator_bridge_url.lower().startswith("https")
    print(
        f"[ingest] n={len(serials)} window={win.isoformat()} encrypt={encrypt} "
        f"concurrency={concurrency} url={cfg.aggregator_bridge_url}"
    )
    client = AggregatorBridgeClient(
        base_url=cfg.aggregator_bridge_url,
        api_key=cfg.aggregator_api_key,
        **_auto_mtls(cfg.aggregator_bridge_url),
    )
    base_counter = int(datetime.now(timezone.utc).timestamp() * 1000)
    sem = asyncio.Semaphore(concurrency)
    ok = 0
    fails: dict[str, int] = {}
    done = 0
    t0 = time.monotonic()

    async def _one(i: int, serial: str) -> None:
        nonlocal ok, done
        reading = EnergyReading(
            meter_id=serial,
            timestamp=ts,
            energy_generated=kwh,
            energy_consumed=0.0,
            surplus_energy=kwh,
            deficit_energy=0.0,
            interval_seconds=WINDOW_MIN * 60,
            voltage=232.0,
            frequency=50.0,
            power_factor=0.99,
            location="scale-mint",
            meter_type="solar",
            user_type="prosumer",
        )
        key = MeterKey(serial)
        kwargs = {"zone_code": (i % zones) + 1}
        if encrypt:
            kwargs["encrypt"] = True
            kwargs["counter"] = base_counter + i
        async with sem:
            try:
                resp = await client.send_reading(reading, key, **kwargs)
                if resp.status_code == 202:
                    ok += 1
                else:
                    fails[str(resp.status_code)] = fails.get(str(resp.status_code), 0) + 1
            except httpx.HTTPStatusError as exc:
                code = str(exc.response.status_code)
                fails[code] = fails.get(code, 0) + 1
            except httpx.HTTPError as exc:
                fails[type(exc).__name__] = fails.get(type(exc).__name__, 0) + 1
        done += 1
        if done % 5000 == 0:
            el = time.monotonic() - t0
            print(f"[ingest]   {done}/{len(serials)} ({done/el:.0f}/s)")

    try:
        await asyncio.gather(*(_one(i, s) for i, s in enumerate(serials)))
    finally:
        await client.close()
    dt = time.monotonic() - t0
    rate = len(serials) / dt if dt else 0.0
    print(
        f"[ingest] accepted={ok}/{len(serials)} fails={fails or 'none'} "
        f"in {dt:.1f}s ({rate:.0f} readings/s)"
    )
    return {
        "sent": len(serials),
        "accepted": ok,
        "fails": fails,
        "seconds": round(dt, 2),
        "readings_per_sec": round(rate, 1),
        "window": win.isoformat(),
        "encrypted": encrypt,
    }


async def phase_watch_mints(
    serials: list[str],
    run_start_utc: str,
    expected: int,
    stall_after_s: int,
    poll_s: int,
    iam_url: str | None = None,
    repair_concurrency: int = 16,
) -> dict:
    """Count OUR serials' minted lines in aggregator logs (exact, immune to
    background simulator traffic polluting the Prometheus counters).

    On stall, checks whether any still-missing serials are stuck on
    "no wallet registered" (an onboard_fleet caching gap — see
    phase_repair_wallets) rather than genuine chain-bridge congestion, and
    self-heals by re-linking those wallets once before giving up. Bounded to
    one repair attempt so a genuinely-broken IAM/bridge still stalls out
    instead of looping forever.
    """
    ours = set(serials)
    minted: dict[str, tuple[str, int, datetime | None]] = {}
    since = run_start_utc
    print(f"[mint] watching aggregator logs for {expected} mints of our serials")
    t0 = time.monotonic()
    last_progress = t0
    first_mint_t: float | None = None
    repair: dict | None = None
    repaired_once = False
    while True:
        await asyncio.sleep(poll_s)
        now = time.monotonic()
        # 30s overlap so the incremental --since window can't drop lines.
        found = await _minted_serials_since(since)
        since = (datetime.now(timezone.utc) - timedelta(seconds=30)).isoformat()
        new = {s: v for s, v in found.items() if s in ours and s not in minted}
        if new:
            minted.update(new)
            last_progress = now
            if first_mint_t is None:
                first_mint_t = now - poll_s  # mints landed within this poll window
        el = now - t0
        rate = (
            len(minted) / (now - first_mint_t)
            if first_mint_t and now > first_mint_t
            else 0.0
        )
        print(f"[mint]   +{el:5.0f}s minted={len(minted)}/{expected} ({rate:.1f} mints/s)")
        if len(minted) >= expected:
            break
        if now - last_progress > stall_after_s:
            missing = ours - set(minted.keys())
            no_wallet = (
                (await _no_wallet_serials_since(run_start_utc)) & missing
                if iam_url and not repaired_once
                else set()
            )
            if no_wallet:
                repaired_once = True
                repair = await phase_repair_wallets(
                    sorted(no_wallet), iam_url, repair_concurrency
                )
                last_progress = now  # give the outbox's next drain tick a chance
                continue
            print(f"[mint] STALL: no mint progress for {stall_after_s}s — stopping watch")
            break
    dt = time.monotonic() - t0
    sample = [(m, sig) for m, (sig, _, _) in list(minted.items())[:3]]
    tps = _tps_stats(minted)
    print(f"[mint] tps={json.dumps(tps)}")
    result = {
        "expected": expected,
        "minted": len(minted),
        "watch_seconds": round(dt, 1),
        "complete": len(minted) >= expected,
        "tps": tps,
        "sample_sigs": [{"meter": m, "sig": s} for m, s in sample],
    }
    if repair is not None:
        result["wallet_repair"] = repair
    return result


async def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--meters", type=int, required=True)
    ap.add_argument("--kwh", type=float, default=0.25)
    ap.add_argument("--zones", type=int, default=8)
    ap.add_argument("--iam-url", default=os.getenv("IAM_GATEWAY_URL", "http://localhost:4001"))
    ap.add_argument("--prom-url", default="http://localhost:6001")
    ap.add_argument("--onboard-concurrency", type=int, default=32)
    ap.add_argument("--ingest-concurrency", type=int, default=128)
    ap.add_argument("--skip-onboard", action="store_true", help="fleet already onboarded")
    ap.add_argument(
        "--onboard-only", action="store_true",
        help="onboard + keys, then exit (pre-warm a tier's fleet without minting)",
    )
    ap.add_argument("--skip-ingest", action="store_true", help="only watch mints")
    ap.add_argument("--window-offset", type=int, default=None, help="override auto offset")
    ap.add_argument("--stall-after", type=int, default=300, help="stop watch after s of no progress")
    ap.add_argument("--poll", type=int, default=15)
    args = ap.parse_args()

    # IAM OOM guard: Argon2::default() = 19 MiB per concurrent hash; the IAM
    # container is capped at 768 MiB. Concurrency 64 OOM-killed IAM during the
    # first tier-10k attempt (86 restarts). 16 leaves ~2x headroom.
    if args.onboard_concurrency > 16:
        print(
            f"[guard] onboard-concurrency {args.onboard_concurrency} → 16 "
            "(Argon2 19MiB/hash vs IAM 768MiB limit; >16 OOM-kills IAM)"
        )
        args.onboard_concurrency = 16

    serials = serials_for(args.meters)
    report: dict = {
        "tier": args.meters,
        "started_utc": datetime.now(timezone.utc).isoformat(),
        "kwh": args.kwh,
    }
    phase = "onboard"
    try:
        if not args.skip_onboard:
            report["onboard"] = await phase_onboard(
                serials, args.iam_url, args.onboard_concurrency
            )
            owners = report["onboard"].pop("owners")
        else:
            cache = load_owner_cache(str(OWNER_CACHE))
            owners = {s: cache[s] for s in serials if s in cache}
            print(f"[onboard] skipped; {len(owners)}/{len(serials)} in owner cache")

        phase = "keys"
        cfg = get_config()
        report["keys"] = phase_register_keys(serials, cfg.redis_url, owners)

        if args.onboard_only:
            report["mint"] = {"complete": True, "skipped": "onboard-only"}
            phase = "done"
            return 0

        prom_before = await _prom_mint_totals(args.prom_url)

        phase = "ingest"
        if not args.skip_ingest:
            offset = (
                args.window_offset if args.window_offset is not None else _next_window_offset()
            )
            report["window_offset"] = offset
            report["ingest"] = await phase_ingest(
                serials, args.kwh, args.zones, args.ingest_concurrency, offset
            )
            expected = report["ingest"]["accepted"]
        else:
            expected = args.meters

        phase = "mint"
        report["mint"] = await phase_watch_mints(
            serials, report["started_utc"], expected, args.stall_after, args.poll,
            iam_url=args.iam_url, repair_concurrency=args.onboard_concurrency,
        )

        phase = "churn"
        if "ingest" in report:
            win_ms = int(
                datetime.fromisoformat(report["ingest"]["window"]).timestamp() * 1000
            )
            report["churn"] = await _chain_bridge_churn(win_ms, report["started_utc"])
            print(f"[churn] {json.dumps(report['churn'])}")
        prom_after = await _prom_mint_totals(args.prom_url)
        if prom_before and prom_after:
            report["prom_mint_total_delta_noisy"] = {
                k: round(prom_after[k] - prom_before.get(k, 0.0), 0)
                for k in prom_after
                if prom_after[k] - prom_before.get(k, 0.0) != 0
            }
        phase = "done"
    except BaseException as exc:  # crash-safe: never lose a multi-hour run's data
        report["aborted"] = phase
        report["error"] = repr(exc)
        raise
    finally:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        with RESULTS.open("a") as f:
            f.write(json.dumps(report) + "\n")
        print(f"\n[report] {json.dumps(report, indent=2)}")
        print(f"[report] appended to {RESULTS}")
    ok = report["mint"]["complete"]
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
