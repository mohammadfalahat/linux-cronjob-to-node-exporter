#!/bin/bash

# Script to collect cron job metrics for the last 61 seconds, including error details, execution times, and commands executed

# Get the timestamp for 61 seconds ago
start_time=$(date --date="61 seconds ago" "+%Y-%m-%dT%H:%M:%S")
# Get the current time
end_time=$(date "+%Y-%m-%dT%H:%M:%S")

# Filter cron logs using precise time comparison
log_entries=$(awk -v start_time="$start_time" -v end_time="$end_time" '
{
    # Extract the timestamp from the log
    match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/, timestamp);
    if (timestamp[0] >= start_time && timestamp[0] <= end_time && /CRON/) {
        print
    }
}
' /var/log/syslog)  # Change /var/log/syslog to the correct log file path

# Count the number of cron jobs that ran in the last 61 seconds (only non-empty CRON entries)
total_count=$(echo "$log_entries" | grep -c "CRON\[.*\]:.*CMD")

# Define the log file path
ERROR_LOGS="/var/log/cron.error.log"

# Collect detailed error information
error_details=""
error_count=0
while IFS= read -r line; do
    log_timestamp=$(echo "$line" | grep -oP "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}")
    if [[ "$log_timestamp" > "$start_time" && "$log_timestamp" < "$end_time" ]] && echo "$line" | grep -Eiq "(Error|Fail)"; then
        ((error_count++))
        cron_id=$(echo "$line" | grep -oP 'CRON\[\K\d+')
        error_msg=$(echo "$line" | sed -n 's/.*\[ERROR\]:\(.*\)CRON\[[0-9]*\] finished.*/\1/p' | sed 's/[[:space:]]*$//')
        exit_code=$(echo "$line" | grep -oP 'Exit Code: \K[0-9]+')
        error_details="$error_details
cronjob_error_details{timestamp=\"$log_timestamp\", cron_id=\"$cron_id\", message=\"$error_msg\", exit_code=\"$exit_code\"} $exit_code"
    fi
done < <(tail -n 500 "$ERROR_LOGS")

# Collect success details
SUCCESS_LOGS="/var/log/cron.success.log"
success_details=""
success_count=0
while IFS= read -r line; do
    log_timestamp=$(echo "$line" | grep -oP "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}")
    if [[ "$log_timestamp" > "$start_time" && "$log_timestamp" < "$end_time" ]] && echo "$line" | grep -q "\[SUCCESS\]"; then
        ((success_count++))
        cron_id=$(echo "$line" | grep -oP 'CRON\[\K\d+')
        success_msg=$(echo "$line" | sed -n 's/.*\[SUCCESS\]:\(.*\)CRON\[[0-9]*\] finished.*/\1/p' | sed 's/[[:space:]]*$//')
        success_details="$success_details
cronjob_success_details{timestamp=\"$log_timestamp\", cron_id=\"$cron_id\", message=\"$success_msg\", exit_code=\"0\"} 0"
    fi
done < <(tail -n 500 "$SUCCESS_LOGS")

# Initialize variables for execution times and commands
commands_executed=""
while IFS= read -r line; do
    log_timestamp=$(echo "$line" | grep -oP "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}")
    if echo "$line" | grep -q "CRON.*CMD"; then
        cmd=$(echo "$line" | sed -n 's/.*CMD \(.*\)/\1/p' | sed 's/"/\\"/g')
        cron_id=$(echo "$line" | grep -oP 'CRON\[\K\d+')
        commands_executed="$commands_executed
cronjob_commands_executed{timestamp=\"$log_timestamp\", cron_id=\"$cron_id\", commands=\"$cmd\"} 1"
    fi
done <<< "$log_entries"

# Write metrics to Node Exporter textfile collector
cat <<EOF > /var/lib/node_exporter/textfile_collector/cron_metrics.prom
# HELP cronjob_success_count Number of successful cron jobs in the last 61 seconds
# TYPE cronjob_success_count counter
cronjob_success_count $(($total_count - $error_count))

# HELP cronjob_failure_count Number of failed cron jobs in the last 61 seconds
# TYPE cronjob_failure_count counter
cronjob_failure_count $error_count

# HELP cronjob_error_details Details of errors in cron jobs (timestamp and message)
# TYPE cronjob_error_details gauge
$error_details

# HELP cronjob_commands_executed Details of commands executed by cron jobs (timestamp and command)
# TYPE cronjob_commands_executed gauge
$commands_executed

# HELP cronjob_success_details Success details of cron jobs (timestamp, success message, and exit code)
# TYPE cronjob_success_details gauge
$success_details
EOF

echo "See result with:"
echo "    cat /var/lib/node_exporter/textfile_collector/cron_metrics.prom"
