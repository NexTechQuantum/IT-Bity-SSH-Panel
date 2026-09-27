# IT Bity SSH Panel

![License](https://img.shields.io/github/license/NexTechQuantum/IT-Bity-SSH-Panel)
![Python](https://img.shields.io/badge/Python-3.10%2B-3776AB?logo=python&logoColor=white)
![Flask](https://img.shields.io/badge/Flask-3.x-000000?logo=flask&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Ubuntu%20%7C%20Debian-E95420?logo=ubuntu&logoColor=white)

IT Bity is a self-hosted web panel for managing SSH and WireGuard users on a Linux server. It combines account management, traffic accounting, connection limits, a dedicated user portal, encrypted-channel Telegram backups, SSL automation, and static website hosting in one responsive interface.

> [!IMPORTANT]
> This project changes SSH, PAM, firewall, Nginx, database, and systemd configuration. Install it only on a server you control. A fresh Ubuntu or Debian server is strongly recommended.

## Features

### Administration

- Create, edit, disable, synchronize, and delete Linux SSH users
- Configure traffic quotas, expiration dates, speed limits, and concurrent connection limits
- Monitor download, upload, total traffic, active connections, and connection history
- Choose a validated OpenSSH encryption profile
- Enable TOTP two-factor authentication for administrators and optionally enforce it for users
- Use responsive light and dark themes with multilingual UI support
- Keep the administrator interface behind a randomized path generated during installation

### WireGuard

- Install and configure a WireGuard UDP tunnel from the panel
- Create one WireGuard peer per user
- Enable, disable, or remove peers
- Copy, share, and download client configuration files
- Display, download, and share scannable QR codes
- Account WireGuard traffic together with SSH traffic

### User Portal

- Optional user portal controlled by the administrator
- Login with the user's managed account credentials
- View traffic consumption, quota, expiration, and active connections
- Browse connection history by date
- Download WireGuard configuration and QR code
- Change the account password
- Submit support tickets
- Open administrator-managed application recommendations for Android, iPhone, Windows, and Linux

### Server Operations

- Request and install Let's Encrypt certificates after validating domain DNS
- Automatic certificate renewal through Certbot
- Schedule full ZIP backups every 1, 2, 4, 8, or 12 hours, or once daily
- Deliver backups to a Telegram channel
- Validate and restore panel backups from the web interface
- Upload a static HTML website for the bare server IP or configured domain
- Keep the administration panel available at its separate randomized path

## Requirements

- A clean Ubuntu or Debian server
- Root or `sudo` access
- A public IPv4 address for public deployments
- Ports `22/tcp`, `80/tcp`, and `443/tcp`
- Port `51820/udp` when WireGuard is enabled
- A domain or subdomain pointing to the server when using SSL

The installer provisions the required services, including Python, MariaDB, Nginx, Gunicorn, Certbot, WireGuard tools, QR generation, traffic-monitoring tools, and systemd units.

## Quick Installation

```bash
git clone https://github.com/NexTechQuantum/IT-Bity-SSH-Panel.git
cd IT-Bity-SSH-Panel
sudo bash install.sh
```

The installer prints the generated panel URL and database credentials when it finishes. Save this output before closing the terminal.

### Initial administrator account

| Field | Default value |
| --- | --- |
| Username | `ITBity` |
| Password | `Admin` |

> [!CAUTION]
> Change the default administrator password immediately after the first login. Do not expose a production installation before changing it.

## Access Model

The administrator interface is not served from `/`. Installation generates a random path similar to:

```text
http://SERVER_IP/4f0a9c...random-value
```

The root IP or domain can serve an administrator-uploaded static website. The user portal has a separate login flow and disappears when the administrator disables user-panel access.

## Static Website Upload

Upload a ZIP archive from **Settings → Static Website**. The archive must contain an `index.html` file and may be no larger than 50 MB.

Before publishing, the panel rejects unsafe paths, symbolic links, and executable or server-side files. A new website replaces the previous version only after successful validation and extraction.

## SSL Setup

1. Create an `A` record for your domain or subdomain that points to the server's public IPv4 address.
2. Open **Settings → SSL Certificate**.
3. Enter the domain and run the DNS check.
4. Install the certificate after validation succeeds.

The server must be reachable from the internet on ports 80 and 443 for Let's Encrypt validation. Private or reserved IP addresses cannot receive a publicly trusted Let's Encrypt certificate.

## Backup and Recovery

To deliver backups through Telegram:

1. Create a Telegram bot and add it as an administrator of the destination channel.
2. Enter the bot token and channel identifier in **Settings → Telegram Full Backup**.
3. Select an interval or a fixed daily time.
4. Send a test message, then save the schedule.

Bot credentials and generated archives are stored in root-readable locations. Recovery validates an uploaded backup before replacing data and creates a safety snapshot first.

## Service Management

```bash
# Panel status
sudo systemctl status itbity-ssh-panel

# Panel logs
sudo journalctl -u itbity-ssh-panel -f

# Restart the panel
sudo systemctl restart itbity-ssh-panel

# Traffic accounting service
sudo systemctl status itbity-traffic

# Validate Nginx configuration
sudo nginx -t
```

The application is installed in:

```text
/var/www/itbity-ssh-panel
```

Runtime configuration and database credentials are stored in:

```text
/var/www/itbity-ssh-panel/.env
```

Protect this file and never publish its contents.

## Technology Stack

- Python and Flask
- MariaDB with SQLAlchemy and Alembic migrations
- Gunicorn and Nginx
- Bootstrap, JavaScript, and Font Awesome
- OpenSSH, PAM, nftables/iptables, and Linux traffic tools
- WireGuard and `qrencode`
- Certbot and Let's Encrypt

## Security Notes

- Administrative operations use narrowly scoped root helpers and sudoers rules.
- WireGuard client private keys remain in root-only server storage.
- Telegram bot tokens are stored in root-readable files.
- Uploaded static websites are served as files; server-side scripts are rejected.
- Keep the operating system and this project updated.
- Review firewall rules before exposing the server publicly.
- Use a unique administrator password and enable two-factor authentication.

## Updating

There is currently no unattended upgrade command. Back up the server before updating and review release notes and installation changes before replacing application files.

## Contributing

Issues and pull requests are welcome. When reporting a problem, include:

- Operating-system name and version
- Relevant service status and sanitized logs
- Steps required to reproduce the issue
- Screenshots when the problem affects the interface

Never include passwords, private keys, bot tokens, database credentials, backup archives, or complete `.env` files in an issue.

## License

This project is available under the [MIT License](LICENSE).

## Disclaimer

Use this software only on systems and networks you own or are authorized to administer. The maintainers are not responsible for misuse, data loss, service interruption, or configuration errors.
