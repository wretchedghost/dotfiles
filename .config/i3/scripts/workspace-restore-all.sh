#!/usr/bin/env bash

SAVE_DIR="$HOME/.config/i3-resurrect"

if [[ ! -d "$SAVE_DIR" ]] || [[ -z "$(ls -A $SAVE_DIR)" ]]; then
    notify-send "i3-resurrect" "No saved workspaces found"
    exit 1
fi

count=0
# Each workspace has two files: programs_NAME.json and layout_NAME.json
# We just need the unique workspace names
for f in "$SAVE_DIR"/programs_*.json; do
    [[ -f "$f" ]] || continue
    # Extract workspace name from filename
    ws=$(basename "$f" | sed 's/^programs_//;s/\.json$//')
    i3-resurrect restore -w "$ws"
    ((count++))
done

notify-send "i3-resurrect" "Restored $count workspaces"
