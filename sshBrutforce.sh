apt update && apt install fail2ban -y
tee /etc/fail2ban/jail.local > /dev/null <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 77.37.196.166 194.33.35.82
maxretry = 3
findtime = 600
bantime  = 1h
[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/auth.log
bantime.increment = true
banaction = iptables-multiport
EOF

sudo systemctl restart fail2ban

