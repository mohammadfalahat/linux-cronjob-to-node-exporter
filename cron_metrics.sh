#!/bin/bash
# Script to collect cron job metrics for the last 61 seconds, including error details, execution times, and commands executed

# Get the timestamp for 61 seconds ago
current_time=$(date "+%b %d %H:%M" -d "61 seconds ago")
now_time=$(date "+%b %d %H:%M")

# Get the timestamp for 61 seconds ago (for /var/log/syslog)
start_syslog_time=$(date --date="61 seconds ago" "+%Y-%m-%dT%H:%M:%S")
end_syslog_time=$(date "+%Y-%m-%dT%H:%M:%S")

detect_format() {
    # Read the first non-empty line of the syslog file
    local first_line=$(grep -m1 -v '^$' /var/log/syslog)

    if [[ $first_line =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
        echo "ISO8601"
    elif [[ $first_line =~ ^[A-Z][a-z]{2}\ +[0-9]+\ +[0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
        echo "Traditional"
    else
        echo "Unknown"
    fi
}

# Define function to process ISO 8601 formatted logs
process_iso8601_logs() {
    awk -v start_time="$start_syslog_time" -v end_time="$end_syslog_time" '
    {
        match($0, /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}/, timestamp);
        if (timestamp[0] >= start_time && timestamp[0] <= end_time && /CRON/) {
            print
        }
    }
    ' /var/log/syslog | sed 's/^<[^>]*>//'
}

# Define function to process traditional formatted logs
process_traditional_logs() {
    awk -v start_time="$start_syslog_time" -v end_time="$end_syslog_time" '
    BEGIN {
        # Convert start and end times to epoch seconds for comparison
        cmd = "date -d \"" start_time "\" +%s"
        cmd | getline start_epoch
        close(cmd)

        cmd = "date -d \"" end_time "\" +%s"
        cmd | getline end_epoch
        close(cmd)
    }
    {
        # Parse traditional syslog timestamp and convert to epoch seconds
        split($0, fields, " ")
        month = fields[1]
        day = fields[2]
        time = fields[3]
        year = strftime("%Y") # Assume current year
        cmd = "date -d \"" month " " day " " year " " time "\" +%s"
        cmd | getline log_epoch
        close(cmd)

        # Check if log is within the specified time range
        if (log_epoch >= start_epoch && log_epoch <= end_epoch && /CRON/) {
            print
        }
    }
    ' /var/log/syslog
}

# Main logic to detect and process logs
format=$(detect_format)
log_entries=""

if [[ $format == "ISO8601" ]]; then
    echo "Detected ISO 8601 format. Processing logs..."
    log_entries=$(process_iso8601_logs)
elif [[ $format == "Traditional" ]]; then
    echo "Detected Traditional format. Processing logs..."
    log_entries=$(process_traditional_logs)
else
    echo "Unknown log format. Exiting."
    exit 1
fi

# Count the number of cron jobs that ran in the last 61 seconds (only non-empty CRON entries)
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
        line="$last_line $line"
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
        error_msg=$(echo "$line" | sed -n 's/.*\[ERROR\]:\(.*\)CRON\[[0-9]*\] finished.*/\1/p' | sed 's/[[:space:]]*$//')
        exit_code=$(echo "$line" | grep -oP 'Exit Code: \K[0-9]+')

        # Format error details for Prometheus with the log timestamp and cron_id
        error_lines="$error_lines
cronjob_error_details{timestamp=\"$log_timestamp\", cron_id=\"$cron_id\", message=\"$error_msg\", exit_code=\"$exit_code\"} $exit_code"
    fi
done < <(tail -n 500 "$ERROR_LOGS")

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

# Collect success messages and success details
SUCCESS_LOGS="/var/log/cron.success.log"
success_details=""
success_count=0
success_lines=""

# Process the success logs and extract the entire section between success message and CRON finish
while IFS= read -r line || [[ -n "$line" ]]; do
    # If the line contains a success message and we have a previous line, merge it
    if [[ -n "$last_success_line" ]]; then
        # Merge last_success_line and current line
        line="$last_success_line $line"
        last_success_line=""  # Reset last_success_line
    fi

    # Store the current line as `last_success_line` for checking against the next line
    if [[ ! "$line" =~ CRON\[[0-9]+\] ]]; then
        last_success_line="$line"
        continue
    fi

    # Extract timestamp from the log entry
    log_timestamp=$(echo "$line" | awk '{print $1" "$2" "$3}')

    # Check if the log entry is within the time range (between current_time and now_time)
    if [[ "$log_timestamp" > "$current_time" && "$log_timestamp" < "$now_time" ]] && echo "$line" | grep -q "\[SUCCESS\]"; then
        # Increment the success count for each success
        ((success_count++))

        # Extract the success message and the CRON ID from the log entry
        cron_id=$(echo "$line" | grep -oP 'CRON\[\K\d+')
        success_msg=$(echo "$line" | sed -n 's/.*\[SUCCESS\]:\(.*\)CRON\[[0-9]*\] finished.*/\1/p' | sed 's/[[:space:]]*$//')

        # Collect all lines for success in the last 61 seconds
        success_lines="$success_lines
cronjob_success_details{timestamp=\"$log_timestamp\", cron_id=\"$cron_id\", message=\"$success_msg\", exit_code=\"0\"} 0"
    fi
done < <(tail -n 500 "$SUCCESS_LOGS")

success_details=${success_lines:-""}  # Handle empty successes

# Write the metrics to Node Exporter textfile collector
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

# Optional: Output the error details to the console (for debugging)
if [[ "$error_count" -gt 0 ]]; then
    echo "Number of errors for failed cron jobs in the last 61 seconds: $error_count"
else
    echo "No errors found in the last 61 seconds."
fi
echo "See result with:"
echo "    cat /var/lib/node_exporter/textfile_collector/cron_metrics.prom"
