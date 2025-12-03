# Sysadmin Scripts

A collection of Bash scripts for Linux system administration and automation.

## Scripts

### backup.sh
Automated backup script with rotation and Telegram notifications.
- Compressed backups (tar.gz)
- Automatic rotation (configurable retention)
- Disk space checking
- Telegram alerts

### system_monitor.sh
System health monitoring with alerting.
- CPU, Memory, Disk monitoring
- Service status checks
- Docker container status
- HTML report generation
- Telegram alerts
- Daemon mode support

### docker_manager.sh
Docker container management utility.
- Container status overview
- Logs, shell access, restart
- Cleanup unused resources
- Container backup
- Docker Compose shortcuts

## Usage
```bash
chmod +x *.sh
./backup.sh
./system_monitor.sh
./docker_manager.sh status
```

## Author

Mikhail Miasnikou — System Administrator / DevOps Engineer

## License

MIT
