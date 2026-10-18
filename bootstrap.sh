#!/usr/bin/env bash

set -euo pipefail

log() { echo "[bootstrap] $*"; }

TEMP_KEY_PATH="/tmp/ansible-key.pub"

# ---------------------------------------------------------------------------
# 1. SSH key for Ansible
# ---------------------------------------------------------------------------
install -d -m 700 -o vagrant -g vagrant /home/vagrant/.ssh
touch /home/vagrant/.ssh/authorized_keys
if ! grep -qF -f $TEMP_KEY_PATH /home/vagrant/.ssh/authorized_keys; then
  cat $TEMP_KEY_PATH >> /home/vagrant/.ssh/authorized_keys
  log "Public key of Ansible added"
else
  log "Public key already exists, skipping"
fi
chown vagrant:vagrant /home/vagrant/.ssh/authorized_keys
chmod 600 /home/vagrant/.ssh/authorized_keys
rm -f $TEMP_KEY_PATH

# ---------------------------------------------------------------------------
# 2. Python for Ansible
# ---------------------------------------------------------------------------
if ! command -v apt-get >/dev/null 2>&1; then
  log "[ERROR] no apt-get, Ansible cannot manage this node"
  exit 1
fi

apt-get update -qq

if command -v python3 >/dev/null 2>&1; then
  log "python3 already present: $(python3 --version 2>&1), skipping install"
else
  apt-get install -y -qq python3
  log "python3 installed: $(python3 --version 2>&1)"
fi

# ---------------------------------------------------------------------------
# 3. Sudoers for vagrant user (no password prompt)
# ---------------------------------------------------------------------------
echo 'vagrant ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-vagrant
chmod 440 /etc/sudoers.d/99-vagrant
visudo -cf /etc/sudoers.d/99-vagrant    
