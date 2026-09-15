#!/bin/bash

set -u

LOCK_FILE="/run/disk-guardian.lock"

if ! exec 200>"$LOCK_FILE"; then
    echo "[ERROR] Unable to create lock file: $LOCK_FILE"
    exit 1
fi

if ! flock -n 200; then
    echo "[INFO] Another Disk Guardian instance is already running."
    exit 0
fi

TARGET="/mnt/disk-lab"
APP_LOG="$TARGET/app-logs/application.log"
LOGROTATE_CONFIG="/etc/logrotate.d/disk-guardian-lab"
GUARDIAN_LOG="/var/log/disk-guardian/disk-guardian.log"

WARNING_THRESHOLD=70
REMEDIATION_THRESHOLD=80
CRITICAL_THRESHOLD=85

GROWTH_INTERVAL=10
GROWTH_THRESHOLD_MB=10
RECENT_LINES=50000


log_message() {
    LEVEL="$1"
    MESSAGE="$2"

    LOG_LINE="$(date '+%Y-%m-%d %H:%M:%S') [$LEVEL] $MESSAGE"

    echo "$LOG_LINE" | tee -a "$GUARDIAN_LOG"
}


get_usage() {
    df -P "$TARGET" | awk 'NR==2 {gsub("%","",$5); print $5}'
}


get_log_size_bytes() {
    if [ -f "$APP_LOG" ]; then
        stat -c%s "$APP_LOG"
    else
        echo 0
    fi
}


check_log_growth() {
    if [ ! -f "$APP_LOG" ]; then
        LOG_GROWTH_MB=0
        LOG_ANOMALY=false
        return
    fi

    INITIAL_SIZE=$(get_log_size_bytes)

    log_message "INFO" \
        "Monitoring application log growth for ${GROWTH_INTERVAL}s"

    sleep "$GROWTH_INTERVAL"

    FINAL_SIZE=$(get_log_size_bytes)

    GROWTH_BYTES=$((FINAL_SIZE - INITIAL_SIZE))

    if [ "$GROWTH_BYTES" -lt 0 ]; then
        GROWTH_BYTES=0
    fi

    LOG_GROWTH_MB=$((GROWTH_BYTES / 1024 / 1024))

    if [ "$LOG_GROWTH_MB" -ge "$GROWTH_THRESHOLD_MB" ]; then
        LOG_ANOMALY=true
    else
        LOG_ANOMALY=false
    fi
}


collect_evidence() {
    log_message "INFO" "Collecting incident evidence"

    echo
    echo "------ Incident Evidence ------"

    if [ ! -f "$APP_LOG" ]; then
        echo "Application log not found."
        echo "-------------------------------"

        log_message "WARNING" \
            "Application log was not found during evidence collection"

        return
    fi

    LOG_SIZE=$(du -h "$APP_LOG" | awk '{print $1}')

    ERROR_COUNT=$(
        tail -n "$RECENT_LINES" "$APP_LOG" |
        grep -c "\[ERROR\]" || true
    )

    WARN_COUNT=$(
        tail -n "$RECENT_LINES" "$APP_LOG" |
        grep -c "\[WARN\]" || true
    )

    echo "Log file: $APP_LOG"
    echo "Log size: $LOG_SIZE"
    echo "Log growth: ${LOG_GROWTH_MB} MB in ${GROWTH_INTERVAL}s"
    echo "ERROR entries in last ${RECENT_LINES} lines: $ERROR_COUNT"
    echo "WARN entries in last ${RECENT_LINES} lines: $WARN_COUNT"

    echo
    echo "Process using log:"

    PROCESS_PID=$(lsof -t "$APP_LOG" 2>/dev/null | head -n 1 || true)

    if [ -n "$PROCESS_PID" ]; then
        PROCESS_USER=$(
            ps -p "$PROCESS_PID" -o user= |
            xargs
        )

        PROCESS_COMMAND=$(
            ps -p "$PROCESS_PID" -o args=
        )

        echo "PID: $PROCESS_PID"
        echo "User: $PROCESS_USER"
        echo "Command: $PROCESS_COMMAND"

        log_message "INFO" \
            "Application log is being used by PID $PROCESS_PID ($PROCESS_COMMAND)"
    else
        echo "No process currently has the log file open."

        log_message "INFO" \
            "No process currently has the application log open"
    fi

    echo
    echo "Recent relevant events:"

    grep -E "\[ERROR\]|\[WARN\]" "$APP_LOG" |
        tail -n 10 || true

    echo "-------------------------------"
    echo

    log_message "INFO" \
        "Evidence summary: size=$LOG_SIZE growth=${LOG_GROWTH_MB}MB errors=$ERROR_COUNT warnings=$WARN_COUNT"
}


run_log_rotation() {
    ACTION_NAME="$1"

    log_message "ACTION" "$ACTION_NAME"

    if logrotate -f "$LOGROTATE_CONFIG"; then
        return 0
    else
        return 1
    fi
}


log_message "INFO" "Disk Guardian execution started"

USAGE=$(get_usage)

echo
echo "=============================="
echo " Linux Disk Guardian"
echo "=============================="
echo "Target: $TARGET"
echo "Disk usage: ${USAGE}%"
echo

log_message "INFO" "Filesystem usage is ${USAGE}%"

check_log_growth

if [ "$LOG_ANOMALY" = true ]; then
    log_message "ANOMALY" \
        "Abnormal log growth detected: ${LOG_GROWTH_MB} MB in ${GROWTH_INTERVAL}s"
fi


if [ "$USAGE" -ge "$CRITICAL_THRESHOLD" ]; then

    log_message "CRITICAL" \
        "Disk usage is above ${CRITICAL_THRESHOLD}%"

    collect_evidence

    BEFORE_USAGE="$USAGE"

    if run_log_rotation "Attempting emergency log rotation"; then

        AFTER_USAGE=$(get_usage)

        log_message "SUCCESS" \
            "Emergency log rotation completed"

        log_message "INFO" \
            "Disk usage changed from ${BEFORE_USAGE}% to ${AFTER_USAGE}%"

        if [ "$AFTER_USAGE" -ge "$CRITICAL_THRESHOLD" ]; then

            log_message "ALERT" \
                "Disk usage remains critical after remediation"

            log_message "ACTION_REQUIRED" \
                "Manual investigation is required"

            exit 2

        else

            log_message "RESOLVED" \
                "Disk usage returned below critical threshold"
        fi

    else

        log_message "ERROR" \
            "Emergency log rotation failed"

        log_message "ACTION_REQUIRED" \
            "Manual investigation is required"

        exit 1
    fi


elif [ "$USAGE" -ge "$REMEDIATION_THRESHOLD" ]; then

    log_message "REMEDIATION" \
        "Disk usage is above ${REMEDIATION_THRESHOLD}%"

    collect_evidence

    BEFORE_USAGE="$USAGE"

    if run_log_rotation "Triggering preventive log rotation"; then

        AFTER_USAGE=$(get_usage)

        log_message "SUCCESS" \
            "Preventive log rotation completed"

        log_message "INFO" \
            "Disk usage changed from ${BEFORE_USAGE}% to ${AFTER_USAGE}%"

        if [ "$AFTER_USAGE" -ge "$REMEDIATION_THRESHOLD" ]; then

            log_message "WARNING" \
                "Disk usage remains above remediation threshold"

        else

            log_message "RESOLVED" \
                "Disk usage returned to a safe level"
        fi

    else

        log_message "ERROR" \
            "Preventive log rotation failed"

        exit 1
    fi


elif [ "$USAGE" -ge "$WARNING_THRESHOLD" ]; then

    log_message "WARNING" \
        "Disk usage is above ${WARNING_THRESHOLD}%"

    collect_evidence

    log_message "INFO" \
        "No automatic remediation triggered at warning level"


elif [ "$LOG_ANOMALY" = true ]; then

    log_message "WARNING" \
        "Log growth anomaly detected while disk usage is still normal"

    collect_evidence

    log_message "INFO" \
        "No automatic remediation triggered"

    log_message "INFO" \
        "Early investigation is recommended"


else

    log_message "OK" \
        "Disk usage and log growth are normal"

fi

log_message "INFO" "Disk Guardian execution finished"
