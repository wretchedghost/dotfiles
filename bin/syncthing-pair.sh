#!/usr/bin/env bash
############################################
# syncthing-pair.sh
# Version: 1.0.0
#
# Pairs this host's Syncthing instance with a
# designated "hub" node via the REST API:
#   - exchanges device IDs (no manual entry)
#   - marks the hub as an introducer, so the
#     hub's other paired devices get added to
#     this node automatically
#   - enables autoAcceptFolders on both sides,
#     so folder shares don't need a GUI click
#
# Requires: curl, jq
# Requires: hub's Syncthing GUI reachable at
#           HUB_ADDR (not just 127.0.0.1)
#
# Changelog:
#   1.0.0 - initial version
############################################
set -euo pipefail

# --- Config: edit these for your environment ---
HUB_ADDR="https://hub.tailnet-name.ts.net:8384"
HUB_API_KEY="REPLACE_ME"
HUB_SYNC_ADDR="tcp://hub.tailnet-name.ts.net:22000"
LOCAL_API="http://127.0.0.1:8384"
LOCAL_CONFIG="${HOME}/.config/syncthing/config.xml"
# ------------------------------------------------

if [[ ! -f "$LOCAL_CONFIG" ]]; then
    echo "Error: local syncthing config not found at $LOCAL_CONFIG" >&2
    exit 1
fi

LOCAL_API_KEY=$(grep -oP '(?<=<apikey>).*(?=</apikey>)' "$LOCAL_CONFIG")

# 1. Resolve device IDs on both ends
LOCAL_ID=$(curl -sf -H "X-API-Key: $LOCAL_API_KEY" \
    "$LOCAL_API/rest/system/status" | jq -r .myID)
HUB_ID=$(curl -sf -H "X-API-Key: $HUB_API_KEY" \
    "$HUB_ADDR/rest/system/status" | jq -r .myID)

if [[ -z "$LOCAL_ID" || -z "$HUB_ID" ]]; then
    echo "Error: failed to resolve device ID(s)" >&2
    exit 1
fi

# 2. Add hub as a trusted introducer on this node
curl -sf -X PUT -H "X-API-Key: $LOCAL_API_KEY" -H "Content-Type: application/json" \
    "$LOCAL_API/rest/config/devices/$HUB_ID" \
    -d "{\"deviceID\":\"$HUB_ID\",\"name\":\"hub\",\"addresses\":[\"$HUB_SYNC_ADDR\"],\"introducer\":true,\"autoAcceptFolders\":true}"

# 3. Add this node on the hub (reciprocal, so hub can introduce it onward)
curl -sf -X PUT -H "X-API-Key: $HUB_API_KEY" -H "Content-Type: application/json" \
    "$HUB_ADDR/rest/config/devices/$LOCAL_ID" \
    -d "{\"deviceID\":\"$LOCAL_ID\",\"name\":\"$(hostname)\",\"autoAcceptFolders\":true}"

echo "Paired $(hostname) ($LOCAL_ID) with hub ($HUB_ID) as introducer."
