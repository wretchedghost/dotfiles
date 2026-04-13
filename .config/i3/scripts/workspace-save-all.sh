#!/usr/bin/env bash

SAVE_DIR="$HOME/.config/i3-resurrect"
mkdir -p "$SAVE_DIR"

# Get list of all current workspace names
workspaces=$(i3-msg -t get_workspaces | python3 -c \
    "import sys, json; [print(w['name']) for w in json.load(sys.stdin)]")

count=0
while IFS= read -r ws; do
    i3-resurrect save -w "$ws" --swallow-criteria "class,instance"
    ((count++))
done <<< "$workspaces"

notify-send "i3-resurrect" "Saved $count workspaces"
