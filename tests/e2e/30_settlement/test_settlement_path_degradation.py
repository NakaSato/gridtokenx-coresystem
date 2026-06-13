"""Settlement-path degradation (G2) — MINT_VIA_CHAIN_BRIDGE=true but NATS_URL unset.

Closes the meter→solana hardening plan's path-degradation assertion: when the mint
path is enabled but NATS_URL is missing, blockchain-core silently falls back to
gRPC-only submit (no durable async JetStream). The aggregator must make that LOUD:

  - log a WARN naming the unset NATS_URL, and
  - export the active path as `settlement_path{path="grpc"} 1` (Prometheus).

(The healthy case exports `path="nats"`; mint-off exports `path="http"`. See
gridtokenx-aggregator-bridge/src/main.rs ~L505-556 and its ARCHITECTURE.md
"Settlement path selection" table.)

Strategy: this is a STARTUP observability assertion — the running stack's aggregator
already has NATS_URL set (path=nats), so we can't mutate it in place. Instead we launch
a THROWAWAY aggregator container from the SAME image, mirroring the live container's
env / mounts / network but with NATS_URL stripped, scrape its /metrics + logs, then
tear it down. We derive everything from the live container via `docker inspect` so the
test tracks compose drift instead of hardcoding env.

OPT-IN: needs docker + the live `gridtokenx-aggregator-bridge` container running
(prerequisites — CHAIN_BRIDGE/IAM reachable on its network — must already hold, which
is why we clone the live container's wiring). Set E2E_PATH_DEGRADATION=1 to run.
"""
import json
import os
import shutil
import subprocess
import time

import pytest
import requests

LIVE = "gridtokenx-aggregator-bridge"        # container to clone wiring from
THROWAWAY = "gridtokenx-agg-degraded-test"   # ephemeral clone we create + destroy
HOST_PORT = int(os.getenv("E2E_DEGRADED_PORT", "4098"))
METRICS_URL = f"http://localhost:{HOST_PORT}/metrics"
BOOT_TIMEOUT = float(os.getenv("E2E_DEGRADED_BOOT_TIMEOUT", "30"))


def _docker_ok() -> bool:
    return shutil.which("docker") is not None


def _live_running() -> bool:
    try:
        r = subprocess.run(
            ["docker", "inspect", "-f", "{{.State.Running}}", LIVE],
            capture_output=True, text=True, timeout=10,
        )
        return r.returncode == 0 and r.stdout.strip() == "true"
    except Exception:
        return False


pytestmark = [
    pytest.mark.skipif(
        os.getenv("E2E_PATH_DEGRADATION", "") != "1",
        reason="opt-in: set E2E_PATH_DEGRADATION=1 (needs docker + live "
               "gridtokenx-aggregator-bridge container) — see module docstring",
    ),
    pytest.mark.skipif(not _docker_ok(), reason="docker CLI unavailable"),
    pytest.mark.skipif(
        not _live_running(),
        reason=f"live {LIVE} container not running — nothing to clone wiring from",
    ),
]


def _inspect(fmt: str) -> str:
    r = subprocess.run(
        ["docker", "inspect", "-f", fmt, LIVE],
        capture_output=True, text=True, timeout=10,
    )
    assert r.returncode == 0, f"docker inspect failed: {r.stderr}"
    return r.stdout.strip()


def _clone_wiring():
    """Pull image / env (minus NATS_URL) / mounts / networks off the live container."""
    image = _inspect("{{.Config.Image}}")
    env = json.loads(_inspect("{{json .Config.Env}}"))
    env = [e for e in env if not e.startswith("NATS_URL=")]
    mounts = json.loads(_inspect("{{json .Mounts}}"))
    networks = list(json.loads(_inspect("{{json .NetworkSettings.Networks}}")).keys())
    return image, env, mounts, networks


def _cleanup():
    subprocess.run(["docker", "rm", "-f", THROWAWAY],
                   capture_output=True, text=True, timeout=30)


def test_mint_without_nats_degrades_to_grpc_loudly():
    image, env, mounts, networks = _clone_wiring()
    assert not any(e.startswith("NATS_URL=") for e in env), "NATS_URL must be stripped"
    assert networks, "live container must be on at least one network"

    _cleanup()  # paranoia: remove a leftover from a crashed prior run

    cmd = ["docker", "run", "-d", "--name", THROWAWAY,
           "--network", networks[0], "-p", f"{HOST_PORT}:4010"]
    for e in env:
        cmd += ["--env", e]
    for m in mounts:
        if m.get("Type") == "bind":
            ro = "" if m.get("RW", True) else ":ro"
            cmd += ["-v", f'{m["Source"]}:{m["Destination"]}{ro}']
    cmd.append(image)

    try:
        run = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        assert run.returncode == 0, f"docker run failed: {run.stderr}"
        # Attach any additional networks (e.g. edge-tier) so CHAIN_BRIDGE/IAM resolve.
        for net in networks[1:]:
            subprocess.run(["docker", "network", "connect", net, THROWAWAY],
                           capture_output=True, text=True, timeout=15)

        # Poll /metrics until the gauge is exported (recorder inits a few lines in).
        deadline = time.time() + BOOT_TIMEOUT
        line = ""
        while time.time() < deadline:
            try:
                body = requests.get(METRICS_URL, timeout=3).text
                for ln in body.splitlines():
                    if ln.startswith("settlement_path"):
                        line = ln
                        break
            except Exception:
                pass
            if line:
                break
            time.sleep(2)

        assert line, f"no settlement_path metric within {BOOT_TIMEOUT}s"
        # The whole point: degraded path is grpc, NOT nats and NOT http.
        assert 'path="grpc"' in line, (
            f"expected settlement_path{{path=\"grpc\"}} when NATS_URL is unset, got: {line}"
        )
        assert line.strip().endswith("1"), f"gauge should be set to 1, got: {line}"

        logs = subprocess.run(["docker", "logs", THROWAWAY],
                              capture_output=True, text=True, timeout=15)
        combined = logs.stdout + logs.stderr
        assert "NATS_URL is unset" in combined, (
            "expected loud WARN naming the unset NATS_URL; not found in logs"
        )
        assert "Active settlement path: grpc" in combined, (
            "expected the active-path INFO line reporting grpc"
        )
    finally:
        _cleanup()
