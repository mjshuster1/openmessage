#!/bin/sh
# One-time setup of a Debian 12 VM for the OpenMessage cloud test.
# Run as root from the folder holding the openmessage binary and these files:
#   sudo sh setup-vm.sh
# It does not start OpenMessage or pair it. See README.md, steps 4 and 5.
set -eu
cd "$(dirname "$0")"

[ -f openmessage ] || { echo "openmessage binary not found here"; exit 1; }

apt-get update -q
apt-get install -y -q curl jq

# 1 GB swap: the e2-micro has 1 GB of memory.
if [ ! -f /swapfile ]; then
  fallocate -l 1G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

id openmessage >/dev/null 2>&1 || useradd --system --home-dir /var/lib/openmessage --shell /usr/sbin/nologin openmessage
install -d -m 700 -o openmessage -g openmessage /var/lib/openmessage

install -m 755 openmessage /usr/local/bin/openmessage
install -m 755 om-status-log.sh /usr/local/bin/om-status-log.sh
install -m 755 om-alert.sh /usr/local/bin/om-alert.sh
install -m 755 om-notify.sh /usr/local/bin/om-notify
install -m 755 om-weekly.sh /usr/local/bin/om-weekly.sh
install -m 755 om-update.sh /usr/local/sbin/om-update
install -m 755 startup.sh /usr/local/sbin/om-install-release
# Alert config (set-alerts.sh writes alert.env): root writes, openmessage reads.
install -d -m 750 -o root -g openmessage /etc/openmessage
install -m 644 openmessage.service om-status-log.service om-status-log.timer \
  om-update.service om-update.timer om-weekly.service om-weekly.timer /etc/systemd/system/

systemctl daemon-reload
systemctl enable openmessage.service
systemctl enable --now om-status-log.timer om-weekly.timer
# Daily update check; it does nothing unless metadata om-release=latest.
systemctl enable --now om-update.timer

echo "Done. Next: pair (README step 5), then: systemctl start openmessage"
