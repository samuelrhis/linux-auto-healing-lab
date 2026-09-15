#!/bin/bash

TARGET="/mnt/disk-lab/app-logs"
LOG_FILE="$TARGET/application.log"

mkdir -p "$TARGET"

echo "Starting fast log generation..."
echo "Log file: $LOG_FILE"
echo "Press CTRL+C to stop."
echo

while true
do
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    {
        for _  in {1..20000}
        do
            echo "$TIMESTAMP [INFO] Processing application request successfully"
            echo "$TIMESTAMP [WARN] Response time above expected threshold"
            echo "$TIMESTAMP [ERROR] Database connection timeout while processing transaction"
            echo "$TIMESTAMP [ERROR] Retry operation failed after multiple attempts"
        done
    } >> "$LOG_FILE"

    df -h /mnt/disk-lab | tail -1
done
