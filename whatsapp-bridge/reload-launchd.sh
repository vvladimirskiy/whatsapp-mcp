#!/bin/bash
# reload-launchd.sh — One-time script to fix the dual-plist problem.
# Run this MANUALLY (it needs launchctl unload which is blocked for automation).
#
# What it does:
#   1. Unloads the duplicate plist (com.vvladimirskiy.whatsapp-bridge)
#   2. Unloads the primary plist (com.whatsapp.bridge)
#   3. Kills any remaining bridge processes
#   4. Reloads only the primary plist (which now uses run-bridge.sh)
#
# After running this, only ONE bridge process should exist, managed by
# com.whatsapp.bridge via run-bridge.sh.

set -euo pipefail

echo "=== WhatsApp Bridge launchd Reload ==="

# Step 1: Unload the duplicate
echo "1. Unloading duplicate plist (com.vvladimirskiy.whatsapp-bridge)..."
launchctl unload ~/Library/LaunchAgents/com.vvladimirskiy.whatsapp-bridge.plist 2>/dev/null || true

# Step 2: Unload the primary (so we can reload it cleanly)
echo "2. Unloading primary plist (com.whatsapp.bridge)..."
launchctl unload ~/Library/LaunchAgents/com.whatsapp.bridge.plist 2>/dev/null || true

# Step 3: Kill any stragglers
echo "3. Killing any remaining bridge processes..."
pkill -f "whatsapp-bridge/whatsapp-bridge" 2>/dev/null || true
sleep 2

REMAINING=$(pgrep -f "whatsapp-bridge/whatsapp-bridge" 2>/dev/null || true)
if [ -n "$REMAINING" ]; then
    echo "   Force-killing stubborn processes: $REMAINING"
    kill -9 $REMAINING 2>/dev/null || true
    sleep 1
fi

# Step 4: Load only the primary plist
echo "4. Loading primary plist (com.whatsapp.bridge via run-bridge.sh)..."
launchctl load ~/Library/LaunchAgents/com.whatsapp.bridge.plist

# Step 5: Verify
sleep 5
echo ""
echo "=== Verification ==="
echo "Loaded services:"
launchctl list | grep -i whatsapp || echo "  (none found)"
echo ""
echo "Running processes:"
ps aux | grep whatsapp-bridge | grep -v grep || echo "  (none found)"
echo ""

# Step 6: Check API status
echo "Checking bridge API status..."
for i in $(seq 1 12); do
    STATUS=$(curl -s http://localhost:8080/api/status 2>/dev/null || true)
    if echo "$STATUS" | grep -q '"connected":true'; then
        echo "Bridge is CONNECTED and healthy."
        echo "Response: $STATUS"
        exit 0
    fi
    echo "  Attempt $i/12: not yet connected (waiting 5s)..."
    sleep 5
done

echo ""
echo "WARNING: Bridge did not report connected:true within 60 seconds."
echo "Check bridge.log for details:"
echo "  tail -50 ~/whatsapp-mcp/whatsapp-bridge/bridge.log"
