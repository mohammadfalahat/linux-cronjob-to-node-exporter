#!/bin/bash
# Script to collect cron job metrics for the last 5 minutes, including error details, execution times, and commands executed

# Get the timestamp for 5 minutes ago
current_time=$(date "+%b %d %H:%M" -d "5 minutes ago")

# Get the current time for logging the current log's entries
now_time=$(date "+%b %d %H:%M")

# Filter syslog entries from the last 5 minutes and only get CRON-related lines
log_entries=$(awk -v start_time="$current_time" -v end_time="$now_time" '
  BEGIN { found=0 }
  $0 ~ start_time { found=1 }
  $0 ~ end_time && found { found=0 }
  found && /CRON/ { print }
' /var/log/syslog)

# Remove empty lines
log_entries=$(echo "$log_entries" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d')

# Count the number of cron jobs that ran in the last 5 minutes (only non-empty CRON entries)
total_count=$(echo "$log_entries" | wc -l)

# Count the number of successful cron jobs (exit code 0, assuming success)
success_count=$(echo "$log_entries" | grep "CRON.*CMD" | wc -l)

# Calculate failure count (difference between total and successful cron jobs)
failure_count=$((total_count - success_count))

# Collect detailed error information for failed cron jobs (based on common error messages)
error_details=$(echo "$log_entries" | grep -i -E "error|failed|exit code" | sed 's/"/\\"/g')
error_details=${error_details:-""}  # Handle empty errors

# Initialize variables for execution times and commands
execution_times=""
commands_executed=""

# Loop through each line of cron logs to extract command execution times and commands
while IFS= read -r line; do
    # Check if the line contains a CRON job start (CMD entry)
    if echo "$line" | grep -q "CRON.*CMD"; then
        # Extract the command executed (after CMD)
        cmd=$(echo "$line" | sed -n 's/.*CMD \(.*\)/\1/p' | sed 's/"/\\"/g')

        # Find the next CRON entry timestamp (next job timestamp)
        next_line=$(echo "$log_entries" | grep -A 1 "$line" | tail -n 1)
        next_timestamp=$(echo "$next_line" | awk '{print $1" "$2" "$3}')

        # Get the timestamp for the current line (start time)
        current_timestamp=$(echo "$line" | awk '{print $1" "$2" "$3}')

        # Calculate the duration (difference in seconds between start and end times)
        start_seconds=$(date -d "$current_timestamp" +%s)
        end_seconds=$(date -d "$next_timestamp" +%s)

        # Ensure no negative durations
        if [[ $start_seconds -gt $end_seconds ]]; then
            duration=0
        else
            duration=$((end_seconds - start_seconds))
        fi

        # Store the execution time and command
        execution_times="$execution_times $duration"
        commands_executed="$commands_executed \"$cmd\""
    fi
done <<< "$log_entries"

# Write the metrics to Node Exporter textfile collector
cat <<EOF > /var/lib/node_exporter/textfile_collector/cron_metrics.prom
# HELP cronjob_success_count Number of successful cron jobs in the last 5 minutes
# TYPE cronjob_success_count counter
cronjob_success_count $success_count

# HELP cronjob_failure_count Number of failed cron jobs in the last 5 minutes
# TYPE cronjob_failure_count counter
cronjob_failure_count $failure_count

# HELP cronjob_error_details Detailed error descriptions for failed cron jobs in the last 5 minutes
# TYPE cronjob_error_details gauge
cronjob_error_details{errors="$error_details"} 1

# HELP cronjob_execution_time_seconds Execution time of cron jobs in the last 5 minutes (in seconds)
# TYPE cronjob_execution_time_seconds gauge
cronjob_execution_time_seconds{execution_times="$execution_times"} 1

# HELP cronjob_commands_executed The exact commands executed by cron jobs in the last 5 minutes
# TYPE cronjob_commands_executed gauge
cronjob_commands_executed{commands="$commands_executed"} 1
EOF

# Echo all variables to the console for debugging
echo "Total Cron Jobs Processed in the Last 5 Minutes: $total_count"
echo "Successful Cron Jobs: $success_count"
echo "Failed Cron Jobs: $failure_count"
echo "Error Details for Failed Cron Jobs: $error_details"
echo "Execution Times (in seconds) for Cron Jobs: $execution_times"
echo "Commands Executed by Cron Jobs: $commands_executed"

# Optional: Output the error details to the console (for debugging)
if [[ -n "$error_details" ]]; then
    echo "Error details for failed cron jobs in the last 5 minutes:"
    echo "$error_details"
else
    echo "No errors found in the last 5 minutes."
fi

# Optional: Output execution times and commands for debugging purposes
echo "Cron job execution times in the last 5 minutes (in seconds):"
echo "$execution_times"
echo "Cron job commands executed in the last 5 minutes:"
echo "$commands_executed"
