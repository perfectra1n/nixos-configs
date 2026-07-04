#!/bin/bash
# Interactive screenshot with markup

# Take screenshot to temp file
TEMP_FILE=$(mktemp --suffix=.png)
grim -g "$(slurp)" "$TEMP_FILE"

if [ -s "$TEMP_FILE" ]; then
    # Open in swappy for editing
    swappy -f "$TEMP_FILE"
else
    notify-send "Screenshot cancelled"
    rm -f "$TEMP_FILE"
fi