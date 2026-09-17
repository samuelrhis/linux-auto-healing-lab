#!/bin/bash

set -u

LOCK_FILE="/run/disk-guardian.lock"

TARGET="/mnt/disk-lab"
APP_LOG="$TARGET/app-logs/application.log"
LOGROTATE_CONFIG="/etc/logrotate.d/disk-guardian-lab"
GUARDIAN_LOG="/var/log/disk-guardian/disk-guardian.log"

WARNING_THRESHOLD=70
REMEDIATION_THRESHOLD=80
CRITICAL_THRESHOLD=85

GROWTH_INTERVAL=10
GROWTH_THRESHOLD_MB=10
PREEMPTIVE_SECONDS=60
RECENT_LINES=50000

LOG_GROWTH_MB=0
GROWTH_BYTES=0
LOG_ANOMALY=false
GROWTH_MEASURED=false
ETA_SECONDS=-1

if ! exec 200>"$LOCK_FILE"; then
    echo "[ERROR] Unable to create lock file: $LOCK_FILE"
    exit 1
fi

if ! flock -n 200; then
    echo "[INFO] Another Disk Guardian instance is already running."
    exit 0
fi

log_message() {
    local level="$1"
    local message="$2"
    local log_line

    log_line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $message"
    echo "$log_line" | tee -a "$GUARDIAN_LOG"
}

get_usage() {
    df -P "$TARGET" | awk 'NR==2 {gsub("%","",$5); print $5}'
}

get_free_bytes() {
    df -PB1 "$TARGET" | awk 'NR==2 {print $4}'
}

get_log_size_bytes() {
    if [ -f "$APP_LOG" ]; then
        stat -c%s "$APP_LOG"
    else
        echo 0
    fi
}

check_log_growth() {
    local initial_size
    local final_size

    if [ ! -f "$APP_LOG" ]; then
        LOG_GROWTH_MB=0
        GROWTH_BYTES=0
        LOG_ANOMALY=false
        GROWTH_MEASURED=true
        return
    fi

    initial_size=$(get_log_size_bytes)

    log_message "INFO" "Monitoring application log growth for ${GROWTH_INTERVAL}s"

    sleep "$GROWTH_INTERVAL"

    final_size=$(get_log_size_bytes)

    GROWTH_BYTES=$((final_size - initial_size))

    if [ "$GROWTH_BYTES" -lt 0 ]; then
        GROWTH_BYTES=0
    fi

    LOG_GROWTH_MB=$((GROWTH_BYTES / 1024 / 1024))
    GROWTH_MEASURED=true

    if [ "$LOG_GROWTH_MB" -ge "$GROWTH_THRESHOLD_MB" ]; then
        LOG_ANOMALY=true
    else
        LOG_ANOMALY=false
    fi
}

calculate_eta_to_full() {
    local free_bytes
    local growth_per_second

    ETA_SECONDS=-1

    if [ "$GROWTH_MEASURED" != true ] || [ "$GROWTH_BYTES" -le 0 ]; then
        return
    fi

    growth_per_second=$((GROWTH_BYTES / GROWTH_INTERVAL))

    if [ "$growth_per_second" -le 0 ]; then
        return
    fi

    free_bytes=$(get_free_bytes)
    ETA_SECONDS=$((free_bytes / growth_per_second))
}

collect_evidence() {
    local log_size
    local error_count
    local warn_count
    local process_pid
    local process_user
    local process_command

    log_message "INFO" "Collecting incident evidence"

    echo
    echo "------ Incident Evidence ------"

    if [ ! -f "$APP_LOG" ]; then
        echo "Application log not found."
        echo "-------------------------------"
        echo

        log_message "WARNING" "Application log was not found during evidence collection"
        return
    fi

    log_size=$(du -h "$APP_LOG" | awk '{print $1}')

    error_count=$(
        tail -n "$RECENT_LINES" "$APP_LOG" |
        grep -c "\[ERROR\]" || true
    )

    warn_count=$(
        tail -n "$RECENT_LINES" "$APP_LOG" |
        grep -c "\[WARN\]" || true
    )

    echo "Log file: $APP_LOG"
    echo "Log size: $log_size"

    if [ "$GROWTH_MEASURED" = true ]; then
        echo "Log growth: ${LOG_GROWTH_MB} MB in ${GROWTH_INTERVAL}s"

        if [ "$ETA_SECONDS" -ge 0 ]; then
            echo "Estimated time to filesystem exhaustion: ~${ETA_SECONDS}s"
        fi
    else
        echo "Log growth: not measured (immediate remediation priority)"
    fi

    echo "ERROR entries in last ${RECENT_LINES} lines: $error_count"
    echo "WARN entries in last ${RECENT_LINES} lines: $warn_count"

    echo
    echo "Process using log:"

    process_pid=$(lsof -t "$APP_LOG" 2>/dev/null | head -n 1 || true)

    if [ -n "$process_pid" ]; then
        process_user=$(ps -p "$process_pid" -o user= | xargs)
        process_command=$(ps -p "$process_pid" -o args=)

        echo "PID: $process_pid"
        echo "User: $process_user"
        echo "Command: $process_command"

        log_message "INFO" "Application log is being used by PID $process_pid ($process_command)"
    else
        echo "No process currently has the log file open."
        log_message "INFO" "No process currently has the application log open"
    fi

    echo
    echo "Recent relevant events:"

    tail -n "$RECENT_LINES" "$APP_LOG" |
        grep -E "\[ERROR\]|\[WARN\]" |
        tail -n 10 || true

    echo "-------------------------------"
    echo

    log_message "INFO" "Evidence summary: size=$log_size growth=${LOG_GROWTH_MB}MB errors=$error_count warnings=$warn_count"
}

run_log_rotation() {
    local action_name="$1"

    log_message "ACTION" "$action_name"
    logrotate -f "$LOGROTATE_CONFIG"
}

perform_remediation() {
    local remediation_type="$1"
    local before_usage
    local after_usage

    before_usage=$(get_usage)

    collect_evidence

    if run_log_rotation "$remediation_type"; then
        after_usage=$(get_usage)

        log_message "SUCCESS" "Log rotation completed"
        log_message "INFO" "Disk usage changed from ${before_usage}% to ${after_usage}%"

        if [ "$after_usage" -ge "$CRITICAL_THRESHOLD" ]; then
            log_message "ALERT" "Disk usage remains critical after remediation"
            log_message "ACTION_REQUIRED" "Manual investigation is required"
            return 2
        fi

        if [ "$after_usage" -ge "$REMEDIATION_THRESHOLD" ]; then
            log_message "WARNING" "Disk usage remains above remediation threshold"
            return 0
        fi

        log_message "RESOLVED" "Disk usage returned to a safe level"
        return 0
    fi

    log_message "ERROR" "Log rotation failed"
    log_message "ACTION_REQUIRED" "Manual investigation is required"
    return 1
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

if [ "$USAGE" -ge "$CRITICAL_THRESHOLD" ]; then
    log_message "CRITICAL" "Disk usage is above ${CRITICAL_THRESHOLD}%"

    perform_remediation "Attempting emergency log rotation"
    RESULT=$?

    log_message "INFO" "Disk Guardian execution finished"
    exit "$RESULT"
fi

if [ "$USAGE" -ge "$REMEDIATION_THRESHOLD" ]; then
    log_message "REMEDIATION" "Disk usage is above ${REMEDIATION_THRESHOLD}%"

    perform_remediation "Triggering preventive log rotation"
    RESULT=$?

    log_message "INFO" "Disk Guardian execution finished"
    exit "$RESULT"
fi

check_log_growth

USAGE=$(get_usage)

if [ "$LOG_ANOMALY" = true ]; then
    log_message "ANOMALY" "Abnormal log growth detected: ${LOG_GROWTH_MB} MB in ${GROWTH_INTERVAL}s"
fi

if [ "$USAGE" -ge "$CRITICAL_THRESHOLD" ]; then
    log_message "CRITICAL" "Disk usage reached ${USAGE}% during growth analysis"

    perform_remediation "Attempting emergency log rotation"
    RESULT=$?

    log_message "INFO" "Disk Guardian execution finished"
    exit "$RESULT"
fi

if [ "$USAGE" -ge "$REMEDIATION_THRESHOLD" ]; then
    log_message "REMEDIATION" "Disk usage reached ${USAGE}% during growth analysis"

    perform_remediation "Triggering preventive log rotation"
    RESULT=$?

    log_message "INFO" "Disk Guardian execution finished"
    exit "$RESULT"
fi

if [ "$LOG_ANOMALY" = true ]; then
    calculate_eta_to_full

    if [ "$ETA_SECONDS" -ge 0 ]; then
        log_message "PREDICTION" "Estimated time to filesystem exhaustion: ~${ETA_SECONDS}s"
    fi

    if [ "$ETA_SECONDS" -ge 0 ] && [ "$ETA_SECONDS" -le "$PREEMPTIVE_SECONDS" ]; then
        log_message "PREEMPTIVE" "Fast log growth may exhaust the filesystem within ${PREEMPTIVE_SECONDS}s"

        perform_remediation "Triggering preemptive log rotation"
        RESULT=$?

        log_message "INFO" "Disk Guardian execution finished"
        exit "$RESULT"
    fi
fi

if [ "$USAGE" -ge "$WARNING_THRESHOLD" ]; then
    log_message "WARNING" "Disk usage is above ${WARNING_THRESHOLD}%"

    collect_evidence

    log_message "INFO" "No automatic remediation triggered at warning level"

elif [ "$LOG_ANOMALY" = true ]; then
    log_message "WARNING" "Log growth anomaly detected while disk usage is still normal"

    collect_evidence

    log_message "INFO" "No automatic remediation triggered"
    log_message "INFO" "Early investigation is recommended"

else
    log_message "OK" "Disk usage and log growth are normal"
fi

log_message "INFO" "Disk Guardian execution finished"
