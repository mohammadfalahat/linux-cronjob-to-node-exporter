

# Install cron_metrics
```
sudo wget https://github.com/mohammadfalahat/linux-cronjob-to-node-exporter/raw/refs/heads/main/cron_metrics.sh
sudo chmod +x cron_metrics.sh
sudo mv mssqlbackup.sh /usr/bin/cron_metrics
sudo mkdir -p /var/lib/node_exporter/textfile_collector
```

# Add metrics updater to `crontab`
add cronjob with crontab -e or sudo vi /etc/crontab
```
*/5 * * * * /usr/bin/cron_metrics
```

# Config Node_Exporter
```
```
