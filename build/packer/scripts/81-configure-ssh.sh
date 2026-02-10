#!/usr/bin/env bash
# Harden SSH after Packer provisioning (reverts insecure build-time settings)

set -e

sed -i \
    -e 's/^PasswordAuthentication.*/PasswordAuthentication no/' \
    -e 's/^PermitRootLogin.*/PermitRootLogin without-password/' \
    /etc/ssh/sshd_config

if ! grep -q '^UseDNS' /etc/ssh/sshd_config; then
    echo 'UseDNS no' >> /etc/ssh/sshd_config
else
    sed -i 's/^UseDNS.*/UseDNS no/' /etc/ssh/sshd_config
fi

systemctl reload sshd || true
