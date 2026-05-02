#!/bin/bash
# Verify the distribution of events across Redis zone streams

REDIS_HOST=${REDIS_HOST:-localhost}
REDIS_PORT=${REDIS_PORT:-7010}
ZONE_COUNT=10

echo "========================================================================"
echo "    GridTokenX - Persistence Distribution Verifier"
echo "========================================================================"

for i in $(seq 0 $((ZONE_COUNT - 1))); do
    STREAM="gridtokenx:events:zone_$i"
    LEN=$(redis-cli -h $REDIS_HOST -p $REDIS_PORT XLEN $STREAM 2>/dev/null || echo "0")
    printf "Zone %2d: %s events\n" $i "$LEN"
done

GLOBAL_LEN=$(redis-cli -h $REDIS_HOST -p $REDIS_PORT XLEN "gridtokenx:events:v1" 2>/dev/null || echo "0")
echo "------------------------------------------------------------------------"
echo "Global : $GLOBAL_LEN events"
echo "========================================================================"
