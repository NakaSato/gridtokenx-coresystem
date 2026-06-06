"""GridTokenX E2E — docker log scraping.

Some cross-service effects (generation-mint settlement, chain tx landing) are only
observable in service logs because the owning service (platform/api-services) is a
separate repo. Log assertion is the pragmatic E2E signal there.
"""
import subprocess
import time


def logs_since(container: str, since: str = "60s") -> str:
    """Return container logs emitted in the recent window (stdout+stderr)."""
    try:
        out = subprocess.run(
            ["docker", "logs", "--since", since, container],
            capture_output=True, text=True, timeout=15,
        )
        return out.stdout + out.stderr
    except Exception:
        return ""


def container_running(container: str) -> bool:
    try:
        out = subprocess.run(
            ["docker", "ps", "--format", "{{.Names}}"],
            capture_output=True, text=True, timeout=10,
        )
        return container in out.stdout.split()
    except Exception:
        return False


def wait_for_log(container: str, needle: str, timeout: float = 90.0, since: str = "120s") -> bool:
    """Poll container logs until `needle` appears or timeout."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if needle in logs_since(container, since):
            return True
        time.sleep(3)
    return False
