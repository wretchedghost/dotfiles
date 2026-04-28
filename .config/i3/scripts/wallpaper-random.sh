#!/usr/bin/env bash

WALLPAPER_DIR="${1:-$HOME/Pictures/Portugal}"

# Exit if directory doesn't exist or is empty
if [[ ! -d "$WALLPAPER_DIR" ]]; then
    notify-send "Wallpaper" "Directory not found: $WALLPAPER_DIR"
    exit 1
fi

# Pick a random image from the directory (searches subdirectories too)
WALLPAPER=$(find "$WALLPAPER_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" \
    -o -iname "*.png" -o -iname "*.gif" \) | shuf -n 1)

if [[ -z "$WALLPAPER" ]]; then
    notify-send "Wallpaper" "No images found in $WALLPAPER_DIR"
    exit 1
fi

# Set the wallpaper and update .fehbg so it persists on next login
feh --bg-fill "$WALLPAPER"

notify-send "Wallpaper changed" "$(basename "$WALLPAPER")"
