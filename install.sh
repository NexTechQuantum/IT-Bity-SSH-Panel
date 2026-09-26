#!/bin/bash

#===========================================
# IT Bity SSH Panel - Auto Installer
# Ubuntu/Debian Only
#===========================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="/var/www/itbity-ssh-panel"
VENV_DIR="$PROJECT_DIR/venv"
DB_NAME="itbitysshpanel"

echo "========================================"
echo "  IT Bity SSH Panel - Installation"
echo "========================================"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: Please run as root (sudo ./install.sh)${NC}"
    exit 1
fi

# Check if requirements.txt exists
if [ ! -f "$SCRIPT_DIR/requirements.txt" ]; then
    echo -e "${RED}Error: requirements.txt not found in $SCRIPT_DIR${NC}"
    exit 1
fi

# Check if app directory exists
if [ ! -d "$SCRIPT_DIR/app" ]; then
    echo -e "${RED}Error: app/ directory not found in $SCRIPT_DIR${NC}"
    exit 1
fi

# Get server IP
SERVER_IP=$(hostname -I | awk '{print $1}')

echo -e "${GREEN}[1/14] Updating system...${NC}"
apt update && apt upgrade -y

echo -e "${GREEN}[2/14] Installing MariaDB...${NC}"
apt install -y mariadb-server mariadb-client

echo -e "${GREEN}[3/14] Starting MariaDB...${NC}"
systemctl start mariadb
systemctl enable mariadb

# Generate random MySQL password
DB_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 24)

echo -e "${GREEN}[4/14] Creating database and user...${NC}"

# Drop user if exists
mysql -e "DROP USER IF EXISTS 'itbity'@'localhost';" 2>/dev/null || true

# Create database
mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

# Create user - MariaDB syntax
mysql -e "CREATE USER 'itbity'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"

# Grant privileges
mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO 'itbity'@'localhost';"

# Flush privileges
mysql -e "FLUSH PRIVILEGES;"

# Test connection
echo "Testing database connection..."
if mysql -u itbity -p"${DB_PASSWORD}" -e "USE ${DB_NAME};" 2>/dev/null; then
    echo -e "${GREEN}✓ Database connection successful${NC}"
else
    echo -e "${RED}✗ Database connection failed!${NC}"
    exit 1
fi

echo -e "${GREEN}[5/14] Installing Python and dependencies...${NC}"
apt install -y python3 python3-pip python3-venv python3-dev libmariadb-dev build-essential pkg-config libssl-dev libffi-dev

echo -e "${GREEN}[5.1/14] Installing network monitoring tools...${NC}"

export DEBIAN_FRONTEND=noninteractive
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

# Install all monitoring tools non-interactively
apt install -y nethogs vnstat iftop conntrack iptables-persistent
apt install -y wireguard-tools qrencode

# Enable vnstat service (for interface traffic persistence)
systemctl enable vnstat
systemctl start vnstat

# Verify installation
for cmd in nethogs vnstat iftop conntrack; do
    if command -v $cmd >/dev/null 2>&1; then
        echo -e "${GREEN}✓ $cmd installed successfully${NC}"
    else
        echo -e "${RED}✗ $cmd installation failed${NC}"
    fi
done

# ✅ Add sudo permission for traffic tools
echo -e "${GREEN}Granting sudo permissions for www-data...${NC}"
if ! grep -q "www-data ALL=(ALL) NOPASSWD: /usr/sbin/nethogs, /usr/sbin/conntrack" /etc/sudoers; then
    echo "www-data ALL=(ALL) NOPASSWD: /usr/sbin/nethogs, /usr/sbin/conntrack" >> /etc/sudoers
fi

echo -e "${GREEN}[6/14] Installing Nginx...${NC}"
apt install -y nginx certbot python3-certbot-nginx
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow 80/tcp
    ufw allow 443/tcp
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --reload
fi

echo -e "${GREEN}[6.1/14] Configuring sudo permissions for www-data...${NC}"

# Install a narrow root helper for the Settings page. It accepts only known
# profiles, validates the complete sshd configuration and rolls back on error.
cat > /usr/local/sbin/itbity-ssh-profile << 'SSH_PROFILE_HELPER'
#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile

CONFIG_FILE = '/etc/ssh/sshd_config.d/60-itbity-crypto.conf'
PROFILES = {
    'automatic': None,
    'modern': (
        'chacha20-poly1305@openssh.com,'
        'aes256-gcm@openssh.com,aes128-gcm@openssh.com'
    ),
    'compatible': (
        'chacha20-poly1305@openssh.com,'
        'aes256-gcm@openssh.com,aes128-gcm@openssh.com,'
        'aes256-ctr,aes128-ctr'
    ),
}


def ensure_sshd_runtime():
    os.makedirs('/run/sshd', mode=0o755, exist_ok=True)
    os.chmod('/run/sshd', 0o755)


def output(success, message, **extra):
    print(json.dumps({'success': success, 'message': message, **extra}))


def read_state():
    ensure_sshd_runtime()
    profile = 'automatic'
    compression = False
    try:
        with open(CONFIG_FILE, encoding='utf-8') as handle:
            for raw_line in handle:
                line = raw_line.strip()
                if line.startswith('# Profile:'):
                    candidate = line.split(':', 1)[1].strip()
                    if candidate in PROFILES:
                        profile = candidate
                elif line.lower().startswith('compression '):
                    compression = line.split(None, 1)[1].lower() == 'yes'
    except FileNotFoundError:
        pass

    effective = subprocess.run(
        ['/usr/sbin/sshd', '-T'], capture_output=True, text=True, timeout=8
    )
    ciphers = ''
    if effective.returncode == 0:
        for line in effective.stdout.splitlines():
            if line.startswith('ciphers '):
                ciphers = line.split(None, 1)[1]
                break
    output(True, 'SSH configuration loaded', profile=profile,
           compression=compression, effective_ciphers=ciphers)


def apply(profile, compression):
    ensure_sshd_runtime()
    if profile not in PROFILES or compression not in ('yes', 'no'):
        output(False, 'Invalid profile or compression value')
        return 2

    lines = [
        '# Managed by IT Bity SSH Panel',
        f'# Profile: {profile}',
        f'Compression {compression}',
    ]
    if PROFILES[profile]:
        lines.append(f'Ciphers {PROFILES[profile]}')
    content = '\n'.join(lines) + '\n'

    os.makedirs(os.path.dirname(CONFIG_FILE), mode=0o755, exist_ok=True)
    previous = None
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, 'rb') as handle:
            previous = handle.read()

    descriptor, candidate = tempfile.mkstemp(
        prefix='.60-itbity-crypto.', dir=os.path.dirname(CONFIG_FILE)
    )
    try:
        with os.fdopen(descriptor, 'w', encoding='utf-8') as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(candidate, 0o644)
        os.replace(candidate, CONFIG_FILE)

        validation = subprocess.run(
            ['/usr/sbin/sshd', '-t'], capture_output=True, text=True, timeout=8
        )
        if validation.returncode != 0:
            if previous is None:
                os.unlink(CONFIG_FILE)
            else:
                with open(CONFIG_FILE, 'wb') as handle:
                    handle.write(previous)
                os.chmod(CONFIG_FILE, 0o644)
            output(False, validation.stderr.strip() or 'sshd validation failed')
            return 1

        reload_result = subprocess.run(
            ['/usr/bin/systemctl', 'reload', 'ssh'],
            capture_output=True, text=True, timeout=8,
        )
        if reload_result.returncode != 0:
            if previous is None:
                os.unlink(CONFIG_FILE)
            else:
                with open(CONFIG_FILE, 'wb') as handle:
                    handle.write(previous)
                os.chmod(CONFIG_FILE, 0o644)
            subprocess.run(
                ['/usr/bin/systemctl', 'reload', 'ssh'],
                capture_output=True, text=True, timeout=8,
            )
            output(False, reload_result.stderr.strip() or 'SSH reload failed')
            return 1
        output(True, 'SSH profile validated and applied', profile=profile,
               compression=(compression == 'yes'))
        return 0
    finally:
        if os.path.exists(candidate):
            os.unlink(candidate)


if __name__ == '__main__':
    if os.geteuid() != 0:
        output(False, 'This helper must run as root')
        sys.exit(1)
    if len(sys.argv) == 2 and sys.argv[1] == 'get':
        read_state()
    elif len(sys.argv) == 4 and sys.argv[1] == 'apply':
        sys.exit(apply(sys.argv[2], sys.argv[3]))
    else:
        output(False, 'Usage: itbity-ssh-profile get|apply PROFILE yes|no')
        sys.exit(2)
SSH_PROFILE_HELPER

chmod 750 /usr/local/sbin/itbity-ssh-profile
chown root:root /usr/local/sbin/itbity-ssh-profile
cat > /etc/tmpfiles.d/itbity-sshd.conf << 'SSHD_TMPFILES'
d /run/sshd 0755 root root -
SSHD_TMPFILES
systemd-tmpfiles --create /etc/tmpfiles.d/itbity-sshd.conf

# WireGuard is managed by a restricted helper. Client private keys remain in
# /etc/itbity-wireguard (root-only) and are never stored in the panel database.
install -o root -g root -m 750 "$SCRIPT_DIR/scripts/itbity-wireguard" /usr/local/sbin/itbity-wireguard
mkdir -p /etc/itbity-wireguard/peers /etc/wireguard
chmod 700 /etc/itbity-wireguard /etc/itbity-wireguard/peers /etc/wireguard
cat > /etc/sysctl.d/60-itbity-wireguard.conf << 'WIREGUARD_SYSCTL'
net.ipv4.ip_forward=1
WIREGUARD_SYSCTL
sysctl --system >/dev/null

# Start WireGuard with a ready-to-use default endpoint. Administrators can
# replace this IP with a hostname later from the panel settings.
if /usr/local/sbin/itbity-wireguard configure true "$SERVER_IP" 51820 >/tmp/itbity-wireguard-install.json 2>&1; then
    echo -e "${GREEN}✓ WireGuard enabled on ${SERVER_IP}:51820/udp${NC}"
else
    echo -e "${YELLOW}⚠ WireGuard could not be started automatically${NC}"
    cat /tmp/itbity-wireguard-install.json 2>/dev/null || true
fi
rm -f /tmp/itbity-wireguard-install.json

# Telegram full-backup helper. Credentials and archives are root-only.
install -o root -g root -m 750 "$SCRIPT_DIR/scripts/itbity-backup" /usr/local/sbin/itbity-backup
install -o root -g root -m 750 "$SCRIPT_DIR/scripts/itbity-ssl" /usr/local/sbin/itbity-ssl
install -o root -g root -m 750 "$SCRIPT_DIR/scripts/itbity-static-site" /usr/local/sbin/itbity-static-site
mkdir -p /etc/itbity-ssl
chmod 700 /etc/itbity-ssl
mkdir -p /etc/itbity-backup /var/lib/itbity-backup
chown root:root /etc/itbity-backup /var/lib/itbity-backup
chmod 700 /etc/itbity-backup /var/lib/itbity-backup
install -o root -g root -m 644 "$SCRIPT_DIR/systemd/itbity-backup.service" /etc/systemd/system/itbity-backup.service

# Create or overwrite sudoers file safely
cat > /etc/sudoers.d/itbity-panel <<'EOF'
# ITBity Panel restricted sudo permissions for www-data
# Do NOT edit this file manually unless you know what you're doing.
www-data ALL=(ALL) NOPASSWD: \
    /usr/sbin/useradd, \
    /usr/sbin/userdel, \
    /usr/sbin/usermod, \
    /usr/sbin/chpasswd, \
    /usr/bin/systemctl reload ssh, \
    /usr/bin/systemctl reload sshd, \
    /usr/bin/tee -a /etc/ssh/sshd_config, \
    /usr/bin/rm, \
    /usr/bin/pkill, \
    /usr/bin/ss, \
    /usr/bin/ps, \
    /usr/bin/sed, \
    /usr/local/sbin/itbity-ssh-profile, \
    /usr/local/sbin/itbity-wireguard
EOF

install -o root -g root -m 440 "$SCRIPT_DIR/systemd/itbity-backup.sudoers" /etc/sudoers.d/itbity-backup
install -o root -g root -m 440 "$SCRIPT_DIR/systemd/itbity-ssl.sudoers" /etc/sudoers.d/itbity-ssl
install -o root -g root -m 440 "$SCRIPT_DIR/systemd/itbity-static-site.sudoers" /etc/sudoers.d/itbity-static-site

# Secure permissions
chmod 440 /etc/sudoers.d/itbity-panel

# Validate sudoers syntax before proceeding
if visudo -cf /etc/sudoers.d/itbity-panel >/dev/null 2>&1 && visudo -cf /etc/sudoers.d/itbity-backup >/dev/null 2>&1 && visudo -cf /etc/sudoers.d/itbity-ssl >/dev/null 2>&1 && visudo -cf /etc/sudoers.d/itbity-static-site >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Sudoers file validated successfully${NC}"
else
    echo -e "${RED}✗ Invalid sudoers file! Aborting installation.${NC}"
    rm -f /etc/sudoers.d/itbity-panel /etc/sudoers.d/itbity-backup /etc/sudoers.d/itbity-ssl /etc/sudoers.d/itbity-static-site
    exit 1
fi


echo -e "${GREEN}[6.2/14] Configuring PAM for connection limits...${NC}"

# Backup original sshd PAM file
if [ ! -f /etc/pam.d/sshd.backup ]; then
    cp /etc/pam.d/sshd /etc/pam.d/sshd.backup
    echo -e "${GREEN}✓ Backup created: /etc/pam.d/sshd.backup${NC}"
fi

# Always refresh the guard so installer upgrades fix older PAM configurations.
cat > /usr/local/bin/check_user_limit.py << 'LIMIT_SCRIPT'
#!/usr/bin/env python3

import fcntl
import os
import re
import sys
import subprocess
from datetime import datetime

LOG_FILE = '/var/log/ssh_connection_limits.log'
ENV_FILE = '/var/www/itbity-ssh-panel/.env'

def log_message(message):
    try:
        with open(LOG_FILE, 'a') as f:
            f.write(f"[{datetime.now()}] {message}\n")
    except:
        pass

def load_env():
    env_vars = {}
    try:
        with open(ENV_FILE, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    env_vars[key.strip()] = value.strip().strip("'\"")
        return env_vars
    except Exception as e:
        log_message(f"ERROR: Failed to load .env: {e}")
        return None

def get_user_policy(username):
    env = load_env()
    if not env:
        return None
    
    try:
        import pymysql
        
        conn = pymysql.connect(
            host=env.get('DB_HOST', 'localhost'),
            user=env.get('DB_USER'),
            password=env.get('DB_PASSWORD'),
            database=env.get('DB_NAME'),
            charset='utf8mb4'
        )
        
        with conn.cursor() as cursor:
            query = """
                SELECT u.is_active, ul.max_connections, ul.expires_at,
                       ul.traffic_limit_gb, ul.download_used_bytes
                FROM users u 
                JOIN user_limits ul ON u.id = ul.user_id 
                WHERE u.username = %s
            """
            cursor.execute(query, (username,))
            result = cursor.fetchone()
            
            conn.close()
            
            if result:
                return {
                    'is_active': bool(result[0]),
                    'max_connections': int(result[1]),
                    'expires_at': result[2],
                    'traffic_limit_gb': int(result[3]),
                    'download_used_bytes': int(result[4] or 0),
                }
            return None
            
    except Exception as e:
        log_message(f"ERROR: Database query failed: {e}")
        return None

def count_user_sessions(username):
    try:
        result = subprocess.run(
            ['/usr/bin/ss', '-tnp', 'state', 'established', '( sport = :22 )'],
            capture_output=True,
            text=True,
            timeout=5
        )
        
        if result.returncode != 0:
            return 0
        
        pids = re.findall(r'pid=(\d+)', result.stdout)
        
        count = 0
        for pid in set(pids):
            try:
                ps_result = subprocess.run(
                    ['/usr/bin/ps', '-o', 'user=', '-p', pid],
                    capture_output=True,
                    text=True,
                    timeout=2
                )
                if ps_result.returncode == 0 and ps_result.stdout.strip() == username:
                    count += 1
            except:
                continue
        
        return count
        
    except Exception as e:
        log_message(f"ERROR: Failed to count sessions: {e}")
        return 0

def main():
    username = os.environ.get('PAM_USER')
    pam_type = os.environ.get('PAM_TYPE')

    # Enforce immediately after password authentication, before SSH accepts
    # the connection. Session-stage failures may not close forwarding clients.
    if pam_type not in (None, 'auth'):
        sys.exit(0)

    if not username:
        log_message("ERROR: PAM_USER not found")
        sys.exit(0)

    # Serialize decisions per user so two simultaneous logins cannot both pass.
    safe_username = re.sub(r'[^a-zA-Z0-9_.-]', '_', username)
    lock_file = open(f'/run/lock/itbity-ssh-{safe_username}.lock', 'w')
    fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
    
    policy = get_user_policy(username)
    
    if policy is None:
        log_message(f"INFO: No limit configured for user '{username}', allowing login")
        sys.exit(0)

    if not policy['is_active']:
        log_message(f"DENIED: {username} is inactive")
        sys.exit(1)

    expires_at = policy['expires_at']
    if expires_at is not None and datetime.utcnow() >= expires_at:
        log_message(f"DENIED: {username} expired at {expires_at} UTC")
        sys.exit(1)

    limit_bytes = policy['traffic_limit_gb'] * (1024 ** 3)
    if policy['download_used_bytes'] >= limit_bytes:
        log_message(
            f"DENIED: {username} exhausted download quota "
            f"({policy['download_used_bytes']}/{limit_bytes} bytes)"
        )
        sys.exit(1)

    max_connections = policy['max_connections']
    
    current_sessions = count_user_sessions(username)
    
    log_message(f"USER: {username}, CURRENT: {current_sessions}, MAX: {max_connections}")
    
    if current_sessions >= max_connections:
        log_message(f"DENIED: {username} reached limit ({current_sessions}/{max_connections})")
        sys.exit(1)
    else:
        log_message(f"ALLOWED: {username} connection ({current_sessions + 1}/{max_connections})")
        sys.exit(0)

if __name__ == '__main__':
    main()
LIMIT_SCRIPT

chmod +x /usr/local/bin/check_user_limit.py
chown root:root /usr/local/bin/check_user_limit.py

touch /var/log/ssh_connection_limits.log
chown root:adm /var/log/ssh_connection_limits.log
chmod 640 /var/log/ssh_connection_limits.log

echo -e "${GREEN}✓ Connection limit guard created${NC}"

# Remove older ineffective hooks and install a fail-fast authentication hook.
sed -i '\|check_user_limit.py|d; /# ITBity Panel - Check user connection limit/d; /# ITBity Panel - Enforce user connection limit/d' /etc/pam.d/sshd
sed -i '/^@include common-auth/a # ITBity Panel - Enforce user connection limit\nauth       requisite    pam_exec.so /usr/local/bin/check_user_limit.py' /etc/pam.d/sshd

if grep -Eq '^auth[[:space:]]+requisite[[:space:]]+pam_exec\.so[[:space:]]+/usr/local/bin/check_user_limit\.py$' /etc/pam.d/sshd; then
    echo -e "${GREEN}✓ PAM authentication guard configured successfully${NC}"
else
    echo -e "${RED}✗ Failed to configure PAM authentication guard${NC}"
    echo -e "${YELLOW}Restoring backup...${NC}"
    cp /etc/pam.d/sshd.backup /etc/pam.d/sshd
    exit 1
fi

echo -e "${GREEN}[6.2.1/14] Installing expiry and inactive-user enforcer...${NC}"

cat > /usr/local/bin/itbity_access_enforcer.py << 'ENFORCER_SCRIPT'
#!/usr/bin/env python3

import os
import subprocess
import time
from datetime import datetime

import pymysql

ENV_FILE = '/var/www/itbity-ssh-panel/.env'
LOG_FILE = '/var/log/itbity-access-enforcer.log'
POLL_SECONDS = 5


def log(message):
    try:
        with open(LOG_FILE, 'a') as handle:
            handle.write(f'[{datetime.now()}] {message}\n')
    except Exception:
        pass


def load_env():
    values = {}
    with open(ENV_FILE, 'r') as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, value = line.split('=', 1)
                values[key.strip()] = value.strip().strip("'\"")
    return values


def get_blocked_users():
    env = load_env()
    connection = pymysql.connect(
        host=env.get('DB_HOST', 'localhost'),
        user=env['DB_USER'],
        password=env['DB_PASSWORD'],
        database=env['DB_NAME'],
        charset='utf8mb4',
        connect_timeout=3,
    )
    try:
        with connection.cursor() as cursor:
            cursor.execute("""
                SELECT u.id, u.username, u.is_active, ul.expires_at,
                       ul.traffic_limit_gb, ul.download_used_bytes, wp.id
                FROM users u
                JOIN user_limits ul ON ul.user_id = u.id
                LEFT JOIN wireguard_peers wp ON wp.user_id = u.id
                WHERE u.role <> 'admin'
                  AND (u.is_active = 0
                       OR ul.expires_at <= UTC_TIMESTAMP()
                       OR ul.download_used_bytes >= ul.traffic_limit_gb * 1073741824)
            """)
            return cursor.fetchall()
    finally:
        connection.close()


def disconnect_user(username, reason):
    probe = subprocess.run(
        ['/usr/bin/pgrep', '-u', username],
        capture_output=True,
        text=True,
        timeout=3,
    )
    pids = probe.stdout.split()
    if probe.returncode != 0 or not pids:
        return

    result = subprocess.run(
        ['/usr/bin/pkill', '-KILL', '-u', username],
        capture_output=True,
        text=True,
        timeout=3,
    )
    if result.returncode in (0, 1):
        log(f'DISCONNECTED: {username}; reason={reason}; pids={",".join(pids)}')
    else:
        log(f'ERROR: failed to disconnect {username}: {result.stderr.strip()}')


def disable_wireguard(user_id, peer_id, username, reason):
    if peer_id is None:
        return
    result = subprocess.run(
        ['/usr/local/sbin/itbity-wireguard', 'disable', str(user_id)],
        capture_output=True, text=True, timeout=5,
    )
    if result.returncode == 0:
        env = load_env()
        connection = pymysql.connect(
            host=env.get('DB_HOST', 'localhost'), user=env['DB_USER'],
            password=env['DB_PASSWORD'], database=env['DB_NAME'],
            charset='utf8mb4', autocommit=True,
        )
        try:
            with connection.cursor() as cursor:
                cursor.execute('UPDATE wireguard_peers SET enabled=0 WHERE id=%s', (peer_id,))
        finally:
            connection.close()
        log(f'WIREGUARD DISABLED: {username}; reason={reason}')


def main():
    log('Access enforcer started')
    while True:
        try:
            for user_id, username, is_active, expires_at, traffic_limit_gb, download_used_bytes, peer_id in get_blocked_users():
                if not is_active:
                    reason = 'inactive'
                elif expires_at is not None and datetime.utcnow() >= expires_at:
                    reason = f'expired_at={expires_at}_UTC'
                else:
                    reason = f'download_quota={download_used_bytes}/{traffic_limit_gb}_GiB'
                disconnect_user(username, reason)
                disable_wireguard(user_id, peer_id, username, reason)
        except Exception as error:
            log(f'ERROR: {error}')
        time.sleep(POLL_SECONDS)


if __name__ == '__main__':
    main()
ENFORCER_SCRIPT

chmod 750 /usr/local/bin/itbity_access_enforcer.py
chown root:root /usr/local/bin/itbity_access_enforcer.py
touch /var/log/itbity-access-enforcer.log
chown root:adm /var/log/itbity-access-enforcer.log
chmod 640 /var/log/itbity-access-enforcer.log

cat > /etc/systemd/system/itbity-access-enforcer.service << 'ENFORCER_SERVICE'
[Unit]
Description=ITBity SSH access expiry and inactive-user enforcer
After=network.target mariadb.service
Requires=mariadb.service

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/itbity_access_enforcer.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
ENFORCER_SERVICE

systemctl daemon-reload
systemctl enable itbity-access-enforcer
echo -e "${GREEN}✓ Access enforcer installed${NC}"

echo -e "${GREEN}[6.3/14] Removing legacy NFTables traffic accounting...${NC}"

# Older releases used a UID-based nftables input rule. It cannot attribute
# tunneled download traffic correctly, so upgrades remove the dedicated table
# and PAM hook. The old installer block is retained below only as inert upgrade
# context and can never execute.
sed -i '\|register_session.py|d; /# ITBity Panel - Register traffic session/d' /etc/pam.d/sshd
if nft list table inet itbity_traffic >/dev/null 2>&1; then
    nft delete table inet itbity_traffic
fi
echo -e "${GREEN}✓ Legacy traffic accounting removed${NC}"

if false; then

# Ensure nftables is installed
apt install -y nftables

# Enable nftables service
systemctl enable nftables
systemctl start nftables

# Create traffic table if not exists
if ! nft list tables 2>/dev/null | grep -q "itbity_traffic"; then
    echo "Creating nftables table inet itbity_traffic..."
    nft add table inet itbity_traffic
fi

# Create traffic chain if not exists
if ! nft list chain inet itbity_traffic users >/dev/null 2>&1; then
    echo "Creating nftables chain itbity_traffic users..."
    nft add chain inet itbity_traffic users '{ type filter hook input priority 0; policy accept; }'
fi

echo -e "${GREEN}✓ NFTables traffic table & chain configured${NC}"


echo -e "${GREEN}[6.4/14] Configuring PAM for traffic session tracking (UID-based)...${NC}"

# Create traffic session registration script
cat > /usr/local/bin/register_session.py << 'TRAFFIC_SCRIPT'
#!/usr/bin/env python3

import os
import sys
import subprocess
import json
import pwd
from datetime import datetime, UTC

LOG_FILE = "/var/log/ssh_session_register.log"
ENV_FILE = "/var/www/itbity-ssh-panel/.env"
NFT_BIN = "/usr/sbin/nft"   # nft path on Ubuntu


# ===========================================================
# SAFE LOGGER
# ===========================================================
def log(msg: str) -> None:
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"[{datetime.now(UTC)}] {msg}\n")
    except Exception:
        # never break PAM on logging failure
        pass


# ===========================================================
# LOAD .env
# ===========================================================
def load_env():
    env = {}
    try:
        with open(ENV_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                env[key.strip()] = value.strip().strip("'\"")
    except Exception as e:
        log(f"Failed to load .env: {e}")
    return env


# ===========================================================
# NFT HELPERS (UID rule)
# ===========================================================
def uid_rule_exists(uid: int) -> bool:
    """Check if we already have a uid-based rule for this uid."""
    try:
        result = subprocess.run(
            [NFT_BIN, "-j", "list", "chain", "inet", "itbity_traffic", "users"],
            capture_output=True,
            text=True,
            timeout=2
        )
        if result.returncode != 0:
            log(f"NFT LIST ERROR: {result.stderr.strip()}")
            return False

        data = json.loads(result.stdout)
        comment = f"user_uid_{uid}"
        for rule in data.get("rules", []):
            if rule.get("comment") == comment:
                return True
    except Exception as e:
        log(f"NFT uid_rule_exists ERROR: {e}")
    return False


def add_uid_rule(uid: int) -> None:
    """Add nftables counter rule for this UID if not exists."""
    comment = f"user_uid_{uid}"

    if uid_rule_exists(uid):
        log(f"NFT UID RULE EXISTS: UID={uid} rule={comment}")
        return

    try:
        subprocess.run(
            [
                NFT_BIN,
                "add", "rule",
                "inet", "itbity_traffic", "users",
                "meta", "skuid", str(uid),
                "counter",
                "comment", comment
            ],
            timeout=2,
            capture_output=True,
            text=True,
        )
        log(f"NFT UID RULE CREATED: UID={uid} rule={comment}")
    except Exception as e:
        log(f"NFT ADD UID RULE ERROR: {e}")


# ===========================================================
# REGISTER SESSION (DB + UID RULE)
# ===========================================================
def register_session(username: str, ip: str) -> None:
    env = load_env()
    if not env:
        log("Env not loaded — skipping DB insert")
        return

    # resolve Linux UID for this ssh/vpn user
    try:
        pw = pwd.getpwnam(username)
        uid = pw.pw_uid
    except Exception as e:
        log(f"Failed to get uid for user={username}: {e}")
        return

    # create UID rule (if needed)
    add_uid_rule(uid)
    nft_rule_name = f"user_uid_{uid}"

    try:
        import pymysql

        conn = pymysql.connect(
            host=env.get("DB_HOST", "localhost"),
            user=env.get("DB_USER"),
            password=env.get("DB_PASSWORD"),
            database=env.get("DB_NAME"),
            charset="utf8mb4"
        )
        cur = conn.cursor()

        # Fetch panel user_id
        cur.execute("SELECT id FROM users WHERE username=%s", (username,))
        row = cur.fetchone()
        if not row:
            log(f"Panel user not found: {username}")
            conn.close()
            return

        user_id = row[0]

        ts = int(datetime.now(UTC).timestamp())
        session_id = f"{username}-{uid}-{ts}"

        # Insert session row; all sessions of same UID share same nft_rule_name
        cur.execute(
            """
            INSERT INTO user_ip_sessions
                (user_id, ip_address, session_id, nft_rule_name, created_at, bytes_in, bytes_out)
            VALUES
                (%s, %s, %s, %s, NOW(), 0, 0)
            """,
            (user_id, ip, session_id, nft_rule_name),
        )
        conn.commit()
        conn.close()

        log(
            f"DB session added: user={username}, uid={uid}, "
            f"ip={ip}, session={session_id}, rule={nft_rule_name}"
        )
    except Exception as e:
        log(f"DB ERROR: {e}")


# ===========================================================
# MAIN ENTRY POINT
# ===========================================================
def main() -> None:
    username = os.environ.get("PAM_USER")
    ip = os.environ.get("PAM_RHOST")

    # TTY برای ما مهم نیست در نسخه UID، ولی اگر خواستی برای دیباگ:
    # tty = os.environ.get("PAM_TTY", "notty")

    if not username or not ip:
        log(f"Missing PAM_USER or PAM_RHOST (user={username}, ip={ip})")
        sys.exit(0)

    # Ignore root (not managed by panel)
    if username == "root":
        log("Skipping root session")
        sys.exit(0)

    register_session(username, ip)
    sys.exit(0)


if __name__ == "__main__":
    main()
TRAFFIC_SCRIPT

chmod +x /usr/local/bin/register_session.py
chown root:root /usr/local/bin/register_session.py

touch /var/log/ssh_session_register.log
chmod 666 /var/log/ssh_session_register.log

# Add PAM session hook if not exists
if ! grep -q "register_session.py" /etc/pam.d/sshd; then
    sed -i '/^@include common-session/a # ITBity Panel - Register traffic session\nsession    required    pam_exec.so /usr/local/bin/register_session.py' /etc/pam.d/sshd
fi

# TCP telemetry discovers SSH sockets directly. Remove the legacy PAM/nft hook
# on both fresh installs and upgrades so one login never creates duplicate rows.
sed -i '\|register_session.py|d; /# ITBity Panel - Register traffic session/d' /etc/pam.d/sshd
echo -e "${GREEN}✓ Legacy PAM traffic hook disabled (TCP telemetry enabled)${NC}"
fi



echo -e "${GREEN}[6.5/14] Installing Traffic Daemon...${NC}"

# Create traffic daemon script
cat > /usr/local/bin/traffic_daemon.py << 'TRAFFIC_DAEMON'
#!/usr/bin/env python3
import re
import subprocess
import time
from datetime import datetime

import pymysql

ENV_FILE = "/var/www/itbity-ssh-panel/.env"
LOG_FILE = "/var/log/traffic_daemon.log"


def log(msg):
    try:
        with open(LOG_FILE, "a") as f:
            f.write(f"[{datetime.now()}] {msg}\n")
    except Exception:
        pass


def load_env():
    env = {}
    try:
        with open(ENV_FILE, "r") as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    key, value = line.split("=", 1)
                    env[key.strip()] = value.strip().strip("'\"")
    except Exception as e:
        log(f"Failed to load .env: {e}")
    return env


def db():
    env = load_env()
    return pymysql.connect(
        host=env.get("DB_HOST", "localhost"),
        user=env.get("DB_USER"),
        password=env.get("DB_PASSWORD"),
        database=env.get("DB_NAME"),
        charset="utf8mb4",
        autocommit=True,
    )


def socket_snapshot():
    """Return every established SSH socket and its TCP byte counters.

    Linux reports bytes_acked from server to client (the user's download) and
    bytes_received from client to server (the user's upload). Each socket is
    sampled independently, so concurrent connections are naturally summed.
    """
    result = subprocess.run(
        ["/usr/bin/ss", "-Htinpe", "state", "established", "( sport = :22 )"],
        capture_output=True,
        text=True,
        timeout=5,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "ss failed")

    records = []
    current = None
    for line in result.stdout.splitlines():
        # ss starts each record with Recv-Q and Send-Q. Continuation lines are
        # indented and contain process/inode/TCP information.
        match = re.match(r"^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\S+)(.*)$", line)
        if match:
            if current:
                records.append(current)
            current = {
                "local": match.group(3),
                "remote": match.group(4),
                "detail": match.group(5),
            }
        elif current:
            current["detail"] += " " + line.strip()
    if current:
        records.append(current)

    snapshot = []
    for record in records:
        detail = record["detail"]
        inode = re.search(r"\bino:(\d+)", detail)
        acked = re.search(r"\bbytes_acked:(\d+)", detail)
        received = re.search(r"\bbytes_received:(\d+)", detail)
        pids = re.findall(r"\bpid=(\d+)", detail)
        if not (inode and acked and received and pids):
            continue

        remote = record["remote"]
        if remote.startswith("[") and "]:" in remote:
            remote_ip, remote_port = remote[1:].rsplit("]:", 1)
        else:
            remote_ip, remote_port = remote.rsplit(":", 1)

        snapshot.append({
            "inode": inode.group(1),
            "remote_ip": remote_ip,
            "remote_port": remote_port,
            "pids": sorted(set(pids)),
            "download": int(acked.group(1)),
            "upload": int(received.group(1)),
        })
    return snapshot


def pid_users(pids):
    if not pids:
        return {}
    result = subprocess.run(
        ["/usr/bin/ps", "-o", "pid=,user=", "-p", ",".join(sorted(set(pids)))],
        capture_output=True,
        text=True,
        timeout=5,
    )
    users = {}
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            users[parts[0]] = parts[1]
    return users


def wireguard_snapshot():
    result = subprocess.run(
        ["/usr/bin/wg", "show", "wg0", "dump"],
        capture_output=True, text=True, timeout=5,
    )
    if result.returncode != 0:
        return []
    peers = []
    for index, line in enumerate(result.stdout.splitlines()):
        if index == 0:
            continue
        fields = line.split("\t")
        if len(fields) < 8:
            continue
        peers.append({
            "public_key": fields[0],
            "last_handshake": int(fields[4] or 0),
            "upload": int(fields[5] or 0),
            "download": int(fields[6] or 0),
        })
    return peers


def main_loop():
    log("TCP traffic daemon started")

    while True:
        try:
            sockets = socket_snapshot()
            wireguard_peers = wireguard_snapshot()
            conn = db()
            try:
                with conn.cursor() as cur:
                    cur.execute("SELECT id, username FROM users WHERE role <> 'admin'")
                    managed = {username: user_id for user_id, username in cur.fetchall()}
                    all_pids = [pid for item in sockets for pid in item["pids"]]
                    users_by_pid = pid_users(all_pids)
                    seen_ids = []

                    for item in sockets:
                        username = next(
                            (users_by_pid.get(pid) for pid in item["pids"]
                             if users_by_pid.get(pid) in managed),
                            None,
                        )
                        if not username:
                            continue

                        user_id = managed[username]
                        key = (f"tcp:{username}:{item['remote_ip']}:"
                               f"{item['remote_port']}:{item['inode']}")
                        cur.execute(
                            """SELECT id, bytes_in, bytes_out
                               FROM user_ip_sessions
                               WHERE session_id=%s AND closed_at IS NULL
                               ORDER BY id DESC LIMIT 1 FOR UPDATE""",
                            (key,),
                        )
                        row = cur.fetchone()
                        if row:
                            session_id, old_download, old_upload = row
                            old_download = old_download or 0
                            old_upload = old_upload or 0
                            if item["download"] < old_download or item["upload"] < old_upload:
                                # A rapidly reconnected socket can reuse the same
                                # inode/port. Preserve the completed counters and
                                # start a new history row instead of overwriting
                                # them with the reset TCP counters.
                                cur.execute(
                                    "UPDATE user_ip_sessions SET closed_at=NOW() WHERE id=%s",
                                    (session_id,),
                                )
                                cur.execute(
                                    """INSERT INTO user_ip_sessions
                                       (user_id, ip_address, session_id, nft_rule_name,
                                        bytes_in, bytes_out, created_at)
                                       VALUES (%s,%s,%s,'tcp_info',%s,%s,NOW())""",
                                    (user_id, item["remote_ip"], key,
                                     item["download"], item["upload"]),
                                )
                                session_id = cur.lastrowid
                                delta_download = item["download"]
                                delta_upload = item["upload"]
                            else:
                                delta_download = item["download"] - old_download
                                delta_upload = item["upload"] - old_upload
                                cur.execute(
                                    "UPDATE user_ip_sessions SET bytes_in=%s, bytes_out=%s WHERE id=%s",
                                    (item["download"], item["upload"], session_id),
                                )
                        else:
                            # Counters already include the bytes used during authentication.
                            delta_download = item["download"]
                            delta_upload = item["upload"]
                            cur.execute(
                                """INSERT INTO user_ip_sessions
                                   (user_id, ip_address, session_id, nft_rule_name,
                                    bytes_in, bytes_out, created_at)
                                   VALUES (%s,%s,%s,'tcp_info',%s,%s,NOW())""",
                                (user_id, item["remote_ip"], key,
                                 item["download"], item["upload"]),
                            )
                            session_id = cur.lastrowid

                        seen_ids.append(session_id)
                        if delta_download or delta_upload:
                            cur.execute(
                                """UPDATE user_limits
                                   SET download_used_bytes=download_used_bytes+%s,
                                       upload_used_bytes=upload_used_bytes+%s
                                   WHERE user_id=%s""",
                                (delta_download, delta_upload, user_id),
                            )

                    if seen_ids:
                        placeholders = ",".join(["%s"] * len(seen_ids))
                        cur.execute(
                            f"""UPDATE user_ip_sessions SET closed_at=NOW()
                                WHERE closed_at IS NULL AND id NOT IN ({placeholders})""",
                            seen_ids,
                        )
                    else:
                        cur.execute(
                            "UPDATE user_ip_sessions SET closed_at=NOW() WHERE closed_at IS NULL"
                        )

                    for item in wireguard_peers:
                        cur.execute(
                            """SELECT id, user_id, rx_bytes, tx_bytes
                               FROM wireguard_peers WHERE public_key=%s FOR UPDATE""",
                            (item["public_key"],),
                        )
                        row = cur.fetchone()
                        if not row:
                            continue
                        peer_id, user_id, old_upload, old_download = row
                        delta_upload = (item["upload"] - old_upload
                                        if item["upload"] >= old_upload else item["upload"])
                        delta_download = (item["download"] - old_download
                                          if item["download"] >= old_download else item["download"])
                        cur.execute(
                            """UPDATE wireguard_peers
                               SET rx_bytes=%s, tx_bytes=%s,
                                   last_handshake_at=IF(%s>0,FROM_UNIXTIME(%s),last_handshake_at)
                               WHERE id=%s""",
                            (item["upload"], item["download"], item["last_handshake"],
                             item["last_handshake"], peer_id),
                        )
                        if delta_download or delta_upload:
                            cur.execute(
                                """UPDATE user_limits
                                   SET download_used_bytes=download_used_bytes+%s,
                                       upload_used_bytes=upload_used_bytes+%s
                                   WHERE user_id=%s""",
                                (delta_download, delta_upload, user_id),
                            )
                conn.commit()
            finally:
                conn.close()
        except Exception as e:
            log(f"MAIN LOOP ERROR: {e}")

        time.sleep(5)


if __name__ == "__main__":
    main_loop()
TRAFFIC_DAEMON

chmod +x /usr/local/bin/traffic_daemon.py
touch /var/log/traffic_daemon.log
chmod 666 /var/log/traffic_daemon.log

# Create systemd service
cat > /etc/systemd/system/itbity-traffic.service << 'SERVICE'
[Unit]
Description=ITBity Traffic Daemon
After=network.target mariadb.service

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/local/bin/traffic_daemon.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable itbity-traffic
systemctl start itbity-traffic

echo -e "${GREEN}✓ Traffic Daemon installed and running${NC}"





echo -e "${GREEN}[7/14] Setting up project directory...${NC}"
mkdir -p $PROJECT_DIR
echo "Copying files from $SCRIPT_DIR to $PROJECT_DIR..."
rsync -av --exclude='venv' --exclude='__pycache__' --exclude='*.pyc' --exclude='.git' --exclude='migrations' "$SCRIPT_DIR/" "$PROJECT_DIR/"

cd $PROJECT_DIR

echo -e "${GREEN}[8/14] Creating virtual environment...${NC}"
python3 -m venv $VENV_DIR
source $VENV_DIR/bin/activate

echo -e "${GREEN}[9/14] Installing Python packages...${NC}"
pip install --upgrade pip setuptools wheel
pip install --no-cache-dir -r $PROJECT_DIR/requirements.txt

# Install gunicorn
pip install gunicorn

# Generate random secret key and panel path
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
PANEL_PATH=$(python3 -c "import secrets; print(secrets.token_hex(16))")

echo -e "${GREEN}[9.1/14] Installing system-wide Python packages for PAM...${NC}"
apt install -y python3-pymysql

# Verify installation
if python3 -c "import pymysql" 2>/dev/null; then
    echo -e "${GREEN}✓ pymysql installed successfully${NC}"
else
    echo -e "${RED}✗ pymysql installation failed${NC}"
    exit 1
fi

echo -e "${GREEN}[10/14] Creating .env file...${NC}"
cat > $PROJECT_DIR/.env << EOF
SECRET_KEY='$SECRET_KEY'
PANEL_PATH='$PANEL_PATH'

DB_HOST='localhost'
DB_USER='itbity'
DB_PASSWORD='$DB_PASSWORD'
DB_NAME='$DB_NAME'

HOST='127.0.0.1'
PORT=5000
DEBUG=False
EOF

chmod 600 $PROJECT_DIR/.env

echo -e "${GREEN}[11/14] Creating WSGI entry point...${NC}"

# Create wsgi.py file
cat > $PROJECT_DIR/wsgi.py << 'WSGI_PY'
from app import create_app, db
from app.models import User

# Create Flask application instance
application = create_app()
app = application

@app.cli.command()
def init_db():
    """Initialize database with default admin user"""
    db.create_all()
    
    admin = User.query.filter_by(username='ITBity').first()
    if not admin:
        admin = User(username='ITBity', user_type='admin')
        admin.set_password('Admin')
        db.session.add(admin)
        db.session.commit()
        print('Default admin user created: ITBity / Admin')
    else:
        print('Admin user already exists')

if __name__ == '__main__':
    with app.app_context():
        db.create_all()
    app.run(
        host=app.config.get('HOST', '127.0.0.1'),
        port=app.config.get('PORT', 5000),
        debug=app.config.get('DEBUG', False)
    )
WSGI_PY

chmod +x $PROJECT_DIR/wsgi.py
echo -e "${GREEN}✓ wsgi.py created${NC}"

echo -e "${GREEN}[12/14] Testing application structure...${NC}"
cd $PROJECT_DIR

# Test 1: Check if app package exists
if [ ! -f "$PROJECT_DIR/app/__init__.py" ]; then
    echo -e "${RED}✗ app/__init__.py not found!${NC}"
    exit 1
fi

# Test 2: Check if models exist
if [ ! -f "$PROJECT_DIR/app/models.py" ]; then
    echo -e "${RED}✗ app/models.py not found!${NC}"
    exit 1
fi

# Test 3: Try to import app module
echo -e "${BLUE}Testing app import...${NC}"
if ! $VENV_DIR/bin/python3 -c "from app import create_app; print('Import successful')" 2>&1; then
    echo -e "${RED}✗ Failed to import app module!${NC}"
    echo -e "${YELLOW}Checking app structure:${NC}"
    ls -la $PROJECT_DIR/app/
    exit 1
fi

# Test 4: Try to create app instance
echo -e "${BLUE}Testing app creation...${NC}"
if ! $VENV_DIR/bin/python3 -c "from app import create_app; app = create_app(); print('App created successfully')" 2>&1; then
    echo -e "${RED}✗ Failed to create app instance!${NC}"
    exit 1
fi

# Test 5: Check if wsgi.py works
echo -e "${BLUE}Testing wsgi.py...${NC}"
if ! $VENV_DIR/bin/python3 -c "import wsgi; print('✓ wsgi.py works')" 2>&1; then
    echo -e "${RED}✗ wsgi.py import failed!${NC}"
    exit 1
fi

echo -e "${GREEN}✓ All application tests passed${NC}"

echo -e "${GREEN}[13/14] Initializing database...${NC}"
source $VENV_DIR/bin/activate
export FLASK_APP=wsgi.py

if [ ! -d "$PROJECT_DIR/migrations" ]; then
    flask db init
fi

flask db migrate -m "Initial migration" 2>/dev/null || echo "Migration already exists"
flask db upgrade

# Create default admin user
$VENV_DIR/bin/python3 << 'PYTHON_SCRIPT'
from app import create_app, db
from app.models import User, UserLimit

app = create_app()
with app.app_context():
    admin = User.query.filter_by(username='ITBity').first()
    if not admin:
        admin = User(username='ITBity', role='admin', is_active=True)
        admin.set_password('Admin')
        db.session.add(admin)
        db.session.flush()
        
        admin_limits = UserLimit(
            user_id=admin.id,
            traffic_limit_gb=999999,
            max_connections=999,
            download_speed_mbps=0
        )
        db.session.add(admin_limits)
        db.session.commit()
        print('✓ Admin user created')
    else:
        print('✓ Admin user already exists')
PYTHON_SCRIPT

echo -e "${GREEN}[14/14] Configuring services...${NC}"

# Nginx configuration
cat > /etc/nginx/sites-available/itbity-ssh-panel << 'NGINX_CONFIG'
server {
    listen 80;
    server_name _;

    location /PANEL_PATH_PLACEHOLDER {
        client_max_body_size 51m;
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_redirect off;
    }

    # Static files - without panel path prefix
    location /static {
        alias /var/www/itbity-ssh-panel/static/;
        expires 30d;
        access_log off;
        add_header Cache-Control "public, immutable";
    }

    # IT Bity static website
    root /var/www/itbity-static-site;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
NGINX_CONFIG

# Replace placeholder with actual panel path
sed -i "s|PANEL_PATH_PLACEHOLDER|${PANEL_PATH}|g" /etc/nginx/sites-available/itbity-ssh-panel

ln -sf /etc/nginx/sites-available/itbity-ssh-panel /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

if nginx -t 2>&1; then
    systemctl reload nginx
    echo -e "${GREEN}✓ Nginx configured successfully${NC}"
else
    echo -e "${RED}✗ Nginx configuration failed!${NC}"
    exit 1
fi

# Systemd service
echo -e "${BLUE}Creating systemd service...${NC}"
cat > /etc/systemd/system/itbity-ssh-panel.service << 'SERVICE'
[Unit]
Description=IT Bity SSH Panel
After=network.target mariadb.service

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/var/www/itbity-ssh-panel
Environment="PATH=/var/www/itbity-ssh-panel/venv/bin"
ExecStart=/var/www/itbity-ssh-panel/venv/bin/gunicorn --no-control-socket --workers 3 --bind 127.0.0.1:5000 --timeout 120 --access-logfile /var/log/itbity-panel-access.log --error-logfile /var/log/itbity-panel-error.log wsgi:app
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE

# Set proper permissions
chown -R www-data:www-data $PROJECT_DIR
chmod +x $PROJECT_DIR/wsgi.py
[ -f "$PROJECT_DIR/app.py" ] && chmod +x $PROJECT_DIR/app.py

# Create log files with proper permissions
touch /var/log/itbity-panel-access.log /var/log/itbity-panel-error.log
chown www-data:www-data /var/log/itbity-panel-access.log /var/log/itbity-panel-error.log

# Final test: Run gunicorn as www-data for 3 seconds
echo -e "${BLUE}Testing Gunicorn with wsgi.py...${NC}"
sudo -u www-data $VENV_DIR/bin/gunicorn --bind 127.0.0.1:5001 --timeout 5 wsgi:app --daemon --pid /tmp/test-gunicorn.pid
sleep 3

if [ -f /tmp/test-gunicorn.pid ]; then
    TEST_PID=$(cat /tmp/test-gunicorn.pid)
    if ps -p $TEST_PID > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Gunicorn test successful${NC}"
        kill $TEST_PID 2>/dev/null || true
        rm -f /tmp/test-gunicorn.pid
    else
        echo -e "${RED}✗ Gunicorn test failed - process died${NC}"
        echo -e "${YELLOW}Check error log:${NC}"
        tail -n 20 /var/log/itbity-panel-error.log 2>/dev/null || echo "No error log"
        exit 1
    fi
else
    echo -e "${RED}✗ Gunicorn test failed - no PID file${NC}"
    exit 1
fi

# Start the actual service
echo -e "${BLUE}Starting panel service...${NC}"
systemctl daemon-reload
systemctl enable itbity-ssh-panel
systemctl start itbity-ssh-panel
systemctl restart itbity-access-enforcer

# Wait for service to start
sleep 5

# Check service status
if systemctl is-active --quiet itbity-ssh-panel; then
    echo -e "${GREEN}✓ Panel service started successfully${NC}"
else
    echo -e "${RED}✗ Panel service failed to start${NC}"
    echo ""
    echo "=== Service Status ==="
    systemctl status itbity-ssh-panel --no-pager -l
    echo ""
    echo "=== Recent Logs ==="
    journalctl -u itbity-ssh-panel -n 50 --no-pager
    echo ""
    echo "=== Error Log ==="
    tail -n 30 /var/log/itbity-panel-error.log 2>/dev/null || echo "No error log yet"
    exit 1
fi

# Configure firewall
echo -e "${GREEN}Configuring firewall...${NC}"
if command -v ufw &> /dev/null; then
    echo -e "${BLUE}Setting up firewall rules...${NC}"
    ufw allow 22/tcp       # SSH - CRITICAL!
    ufw allow 80/tcp       # HTTP
    ufw allow 443/tcp      # HTTPS
    ufw allow 51820/udp    # WireGuard
    ufw --force enable 2>/dev/null || true
    echo -e "${GREEN}✓ Firewall configured (SSH, HTTP, HTTPS, WireGuard allowed)${NC}"
    ufw status numbered
else
    echo -e "${YELLOW}⚠ UFW not found, skipping firewall configuration${NC}"
fi

echo ""
echo "========================================"
echo -e "${GREEN}✓✓✓ Installation Completed! ✓✓✓${NC}"
echo "========================================"
echo ""
echo -e "${BLUE}Panel Access Information:${NC}"
echo -e "  Panel URL: ${YELLOW}http://${SERVER_IP}/${PANEL_PATH}${NC}"
echo -e "  Default Username: ${YELLOW}ITBity${NC}"
echo -e "  Default Password: ${YELLOW}Admin${NC}"
echo ""
echo -e "${BLUE}Database Information:${NC}"
echo -e "  Database Name: ${YELLOW}${DB_NAME}${NC}"
echo -e "  Database User: ${YELLOW}itbity${NC}"
echo -e "  Database Password: ${YELLOW}${DB_PASSWORD}${NC}"
echo -e "  Database Host: ${YELLOW}localhost${NC}"
echo ""
echo -e "${BLUE}Configuration File:${NC}"
echo -e "  Location: ${YELLOW}${PROJECT_DIR}/.env${NC}"
echo -e "  View credentials: ${YELLOW}cat ${PROJECT_DIR}/.env${NC}"
echo ""
echo -e "${BLUE}SSH Connection Limits:${NC}"
echo -e "  Limit script: ${YELLOW}/usr/local/bin/check_user_limit.py${NC}"
echo -e "  Limit logs:   ${YELLOW}tail -f /var/log/ssh_connection_limits.log${NC}"
echo -e "  PAM config:   ${YELLOW}/etc/pam.d/sshd${NC}"
echo -e "  PAM backup:   ${YELLOW}/etc/pam.d/sshd.backup${NC}"
echo ""
echo -e "${RED}⚠️  CRITICAL SECURITY WARNINGS:${NC}"
echo "  1. Change admin password IMMEDIATELY after first login"
echo "  2. Save the panel URL (it's randomly generated and won't be shown again)"
echo "  3. Keep database credentials safe (stored in .env file)"
echo "  4. Database credentials are stored in: ${PROJECT_DIR}/.env"
echo ""
echo -e "${BLUE}Database Tables Created:${NC}"
echo -e "  ${GREEN}✓${NC} users (User accounts and authentication)"
echo -e "  ${GREEN}✓${NC} user_limits (Traffic limits and restrictions)"
echo ""
echo -e "${BLUE}Service Management:${NC}"
echo "  Status:  systemctl status itbity-ssh-panel"
echo "  Logs:    journalctl -u itbity-ssh-panel -f"
echo "  Errors:  tail -f /var/log/itbity-panel-error.log"
echo "  Restart: systemctl restart itbity-ssh-panel"
echo "  Stop:    systemctl stop itbity-ssh-panel"
echo ""
echo -e "${BLUE}Debug Commands:${NC}"
echo "  Test import: cd $PROJECT_DIR && sudo -u www-data ./venv/bin/python3 -c 'from app import create_app; app = create_app()'"
echo "  Manual run:  cd $PROJECT_DIR && sudo -u www-data ./venv/bin/gunicorn --bind 127.0.0.1:5000 wsgi:app"
echo "  View .env:   cat ${PROJECT_DIR}/.env"
echo ""
echo "========================================"
echo -e "${GREEN}Installation Summary:${NC}"
echo "========================================"
echo -e "${GREEN}✓${NC} MariaDB installed and configured"
echo -e "${GREEN}✓${NC} Database '${DB_NAME}' created"
echo -e "${GREEN}✓${NC} Database user 'itbity' created"
echo -e "${GREEN}✓${NC} Admin user 'ITBity' created in database"
echo -e "${GREEN}✓${NC} Python environment configured"
echo -e "${GREEN}✓${NC} Nginx reverse proxy configured"
echo -e "${GREEN}✓${NC} WireGuard configured on ${SERVER_IP}:51820/udp"
echo -e "${GREEN}✓${NC} Systemd service running"
echo -e "${GREEN}✓${NC} Firewall configured (SSH, HTTP, HTTPS)"
echo -e "${GREEN}✓${NC} PAM connection limits configured"
echo ""
echo -e "${YELLOW}Save these credentials before closing this terminal!${NC}"
echo "========================================"
