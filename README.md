## Track how cronjobs are going with Grafana 

![Screenshot from 2024-12-14 16-32-54](https://github.com/user-attachments/assets/a970736a-3ce7-42db-a830-d50188b018ce)

1.  install Cronjob Tracker ([https://github.com/mohammadfalahat/cronjob-tracker](https://github.com/mohammadfalahat/cronjob-tracker))
2.  enable cron logs in syslog
3. install cron metrics
4. add collector directory flag to node exporter
5. update cronjob tasks

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
sudo mv cron_metrics.sh /usr/bin/cron_metrics
```

# Add metrics updater to `crontab`
add cronjob with `crontab -e` or `sudo vi /etc/crontab`
```
* * * * * /usr/bin/cron_metrics  > /tmp/cron_$$.log 2>&1; /usr/bin/cron_tracker $? $$ < /tmp/cron_$$.log
```

# Config Node_Exporter
```
/usr/local/bin/node_exporter \
  --web.config.file=/etc/node_exporter/web.yml \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
```

# Update Cronjob tasks
you have to add this code to end of each cronjob command: 
```
> /tmp/cron_$$.log 2>&1; /usr/bin/cron_tracker $? $$ < /tmp/cron_$$.log
```
```
# for example turn:
* * * * * /usr/bin/cron_metrics
to
* * * * * /usr/bin/cron_metrics  > /tmp/cron_$$.log 2>&1; /usr/bin/cron_tracker $? $$ < /tmp/cron_$$.log
```
