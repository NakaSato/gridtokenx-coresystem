#!/usr/bin/env bash
# Suite 25 — IoT gateway transport-level mTLS (Aggregator Bridge :4030).
#
# Replaces the deleted test_envoy_mtls.py, which covered the removed Envoy :4002
# edge and was never re-pointed at the aggregator after TLS termination moved
# into the service itself.
#
# Cases live in test_iot_mtls.py; they skip unless the stack is running the
# secure profile (`just secure-up`), because mTLS is deliberately OFF by default
# so plain dev/e2e keep their conveniences.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/../lib/assert.sh"
pytest_suite "$HERE"
