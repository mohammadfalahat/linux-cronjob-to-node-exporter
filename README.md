
# Enable Cron logs
```
sudo sed -i 's/^#cron\.\*/cron.*/' /etc/rsyslog.d/50-default.conf
sudo systemctl restart rsyslog
```

# Install cron_metrics
```
sudo mkdir -p /var/lib/node_exporter/textfile_collector && cd /var/lib/node_exporter/textfile_collector
sudo wget https://github.com/mohammadfalahat/linux-cronjob-to-node-exporter/raw/refs/heads/main/cron_metrics.sh
sudo chmod +x cron_metrics.sh
sudo mv mssqlbackup.sh /usr/bin/cron_metrics
```

# Add metrics updater to `crontab`
add cronjob with `crontab -e` or `sudo vi /etc/crontab`
```
* * * * * /usr/bin/cron_metrics      >> /var/log/cron.error.log 2>&1; echo " CRON[$$] finished " >> /var/log/cron.error.log;
```

# Config Node_Exporter
```
/usr/local/bin/node_exporter \
  --web.config.file=/etc/node_exporter/web.yml \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```
