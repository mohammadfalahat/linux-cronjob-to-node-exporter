#!/bin/bash
# Script to collect cron job metrics for the last 65 seconds, including error details, execution times, and commands executed

# Get the timestamp for 65 seconds ago
current_time=$(date "+%b %d %H:%M" -d "65 seconds ago")

# Get the current time for logging the current log's entries
now_time=$(date "+%b %d %H:%M")

# Filter cron.log entries from the last 65 seconds and only get CRON-related lines
log_entries=$(awk -v start_time="$current_time" -v end_time="$now_time" '
    {
        log_timestamp = $1" "$2" "$3
        if (log_timestamp >= start_time && log_timestamp <= end_time && /CRON/) {
            print
        }
    }
' /var/log/cron.log)

# Count the number of cron jobs that ran in the last 65 seconds (only non-empty CRON entries)
total_count=$(echo "$log_entries" | tr -s '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' | wc -l)

# Define the log file path
ERROR_LOGS="/var/log/cron.error.log"

# Collect detailed error information from cron.error.log (filtering by time range)
error_details=""
error_count=0
error_lines=""

while IFS= read -r line || [[ -n "$line" ]]; do
    # If the line contains a CRON entry and we have a previous line, merge it
    if [[ -n "$last_line" ]]; then
        # Merge last_line and current line, removing the newline from last_line
        line="$last_line$line"
        last_line=""  # Reset last_line
    fi

    # Store the current line as `last_line` for checking against the next line
    if [[ ! "$line" =~ CRON\[[0-9]+\] ]]; then
        last_line="$line"
        continue
    fi

    # Extract timestamp from the log entry
    log_timestamp=$(echo "$line" | awk '{print $1" "$2" "$3}')

    # Check if the log entry is within the time range (between current_time and now_time)
    if [[ "$log_timestamp" > "$current_time" && "$log_timestamp" < "$now_time" ]] && echo "$line" | grep -Eiq "(Error|Fail)"; then
        # Increment the error count for each error
        ((error_count++))

        # Extract the error message and the CRON ID from the log entry
        cron_id=$(echo "$line" | grep -oP 'CRON\[\K\d+')
        error_msg=$(echo "$line" | sed -n 's/.*\(Error\|Fail\): \(.*\)/\2/pI')
        
        # Format error details for Prometheus with the log timestamp and cron_id
        error_lines="$error_lines
cronjob_error_details{timestamp=\"$log_timestamp\", cron_id=\"$cron_id\", errors=\"$error_msg\"} 1"
    fi
done < "$ERROR_LOGS"

error_details=${error_lines:-""}  # Handle empty errors

# Initialize variables for execution times and commands
execution_times=""
commands_executed=""

# Loop through each line of cron logs to extract command execution times and commands
while IFS= read -r line; do
    # Extract the log timestamp for this entry
    log_timestamp=$(echo "$line" | awk '{print $1" "$2" "$3}')
    
    # Check if the line contains a CRON job start (CMD entry)
    if echo "$line" | grep -q "CRON.*CMD"; then
        # Extract the command executed (after CMD)
        cmd=$(echo "$line" | sed -n 's/.*CMD \(.*\)/\1/p' | sed 's/"/\\"/g')

        # Extract CRON ID
        cron_id=$(echo "$line" | grep -oP 'CRON\[\K\d+')

        # Format the command details for Prometheus with the log timestamp and cron_id
        commands_executed="$commands_executed
cronjob_commands_executed{timestamp=\"$log_timestamp\", cron_id=\"$cron_id\", commands=\"$cmd\"} 1"
    fi
done <<< "$log_entries"

# Write the metrics to Node Exporter textfile collector
cat <<EOF > /var/lib/node_exporter/textfile_collector/cron_metrics.prom
# HELP cronjob_success_count Number of successful cron jobs in the last 65 seconds
# TYPE cronjob_success_count counter
cronjob_success_count $(($total_count - $error_count))

# HELP cronjob_failure_count Number of failed cron jobs in the last 65 seconds
# TYPE cronjob_failure_count counter
cronjob_failure_count $error_count

# HELP cronjob_error_details Details of errors in cron jobs (timestamp and message)
# TYPE cronjob_error_details gauge
$error_details

# HELP cronjob_commands_executed Details of commands executed by cron jobs (timestamp and command)
# TYPE cronjob_commands_executed gauge
$commands_executed
EOF

# Optional: Output the error details to the console (for debugging)
if [[ "$error_count" -gt 0 ]]; then
    echo "Number of errors for failed cron jobs in the last 65 seconds: $error_count"
else
    echo "No errors found in the last 65 seconds."
fi
echo "See result with:"
echo "    cat /var/lib/node_exporter/textfile_collector/cron_metrics.prom"
