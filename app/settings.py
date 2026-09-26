from flask import Blueprint, render_template, request, jsonify, flash, redirect, url_for
from flask_login import login_required, current_user
from flask_babel import gettext as _
from functools import wraps
import json
import subprocess

settings_bp = Blueprint('settings', __name__)

# Decorator to check if user is admin
def admin_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        if not current_user.is_authenticated or current_user.role != 'admin':
            flash(_('Access denied. Admin privileges required.'), 'error')
            return redirect(url_for('main.dashboard'))
        return f(*args, **kwargs)
    return decorated_function

@settings_bp.route('/settings')
@login_required
@admin_required
def settings_page():
    """Display settings page"""
    return render_template('settings.html')

# SSL Certificate Management
@settings_bp.route('/api/ssl/status', methods=['GET'])
@login_required
@admin_required
def get_ssl_status():
    """Get SSL certificate status - TODO: Implement"""
    return jsonify({
        'success': True,
        'ssl_enabled': False,
        'certificate_expiry': None,
        'auto_renew': False
    })

@settings_bp.route('/api/ssl/install', methods=['POST'])
@login_required
@admin_required
def install_ssl():
    """Install SSL certificate - TODO: Implement"""
    return jsonify({'success': False, 'message': 'Not implemented yet'}), 501

# SSH Configuration
@settings_bp.route('/api/ssh/config', methods=['GET'])
@login_required
@admin_required
def get_ssh_config():
    """Read the panel-managed OpenSSH encryption profile."""
    try:
        result = subprocess.run(
            ['/usr/bin/sudo', '/usr/local/sbin/itbity-ssh-profile', 'get'],
            capture_output=True, text=True, timeout=10, check=True,
        )
        return jsonify(json.loads(result.stdout))
    except (subprocess.SubprocessError, json.JSONDecodeError, OSError) as error:
        return jsonify({
            'success': False,
            'message': f'Unable to read SSH configuration: {error}',
        }), 500

@settings_bp.route('/api/ssh/config', methods=['PUT'])
@login_required
@admin_required
def update_ssh_config():
    """Safely validate, apply and reload a whitelisted SSH profile."""
    payload = request.get_json(silent=True) or {}
    profile = payload.get('profile')
    if profile not in {'automatic', 'modern', 'compatible'}:
        return jsonify({'success': False, 'message': 'Invalid encryption profile'}), 400

    try:
        result = subprocess.run(
            [
                '/usr/bin/sudo', '/usr/local/sbin/itbity-ssh-profile', 'apply',
                profile, 'no',
            ],
            capture_output=True, text=True, timeout=15,
        )
        response = json.loads(result.stdout or '{}')
        if result.returncode != 0 or not response.get('success'):
            return jsonify(response or {
                'success': False,
                'message': result.stderr.strip() or 'SSH validation failed',
            }), 500
        return jsonify(response)
    except (subprocess.SubprocessError, json.JSONDecodeError, OSError) as error:
        return jsonify({'success': False, 'message': f'Unable to update SSH: {error}'}), 500


def _wireguard_helper(*arguments):
    result = subprocess.run(
        ['/usr/bin/sudo', '/usr/local/sbin/itbity-wireguard', *map(str, arguments)],
        capture_output=True, text=True, timeout=25,
    )
    payload = json.loads(result.stdout or '{}')
    if result.returncode != 0 or not payload.get('success'):
        raise RuntimeError(payload.get('message') or result.stderr.strip() or 'WireGuard operation failed')
    return payload


@settings_bp.route('/api/wireguard/config', methods=['GET'])
@login_required
@admin_required
def get_wireguard_config():
    try:
        return jsonify(_wireguard_helper('status'))
    except Exception as error:
        return jsonify({'success': False, 'message': str(error)}), 500


@settings_bp.route('/api/wireguard/config', methods=['PUT'])
@login_required
@admin_required
def update_wireguard_config():
    payload = request.get_json(silent=True) or {}
    enabled = payload.get('enabled')
    endpoint = str(payload.get('endpoint', '')).strip()
    try:
        port = int(payload.get('port', 51820))
    except (TypeError, ValueError):
        return jsonify({'success': False, 'message': 'Invalid WireGuard port'}), 400
    if not isinstance(enabled, bool):
        return jsonify({'success': False, 'message': 'Enabled must be true or false'}), 400
    try:
        return jsonify(_wireguard_helper('configure', str(enabled).lower(), endpoint, port))
    except Exception as error:
        return jsonify({'success': False, 'message': str(error)}), 500

# Two-Factor Authentication
@settings_bp.route('/api/2fa/status', methods=['GET'])
@login_required
@admin_required
def get_2fa_status():
    """Get 2FA status - TODO: Implement"""
    return jsonify({
        'success': True,
        'enabled': False,
        'enforced': False
    })

@settings_bp.route('/api/2fa/toggle', methods=['POST'])
@login_required
@admin_required
def toggle_2fa():
    """Toggle 2FA - TODO: Implement"""
    return jsonify({'success': False, 'message': 'Not implemented yet'}), 501

# Static Website Upload
@settings_bp.route('/api/static-site/upload', methods=['POST'])
@login_required
@admin_required
def upload_static_site():
    """Upload static website - TODO: Implement"""
    return jsonify({'success': False, 'message': 'Not implemented yet'}), 501

# User Panel Access Control
@settings_bp.route('/api/user-panel/toggle', methods=['POST'])
@login_required
@admin_required
def toggle_user_panel():
    """Toggle user panel access - TODO: Implement"""
    return jsonify({'success': False, 'message': 'Not implemented yet'}), 501

# Backup & Restore
@settings_bp.route('/api/backup/create', methods=['POST'])
@login_required
@admin_required
def create_backup():
    """Create system backup - TODO: Implement"""
    return jsonify({'success': False, 'message': 'Not implemented yet'}), 501

@settings_bp.route('/api/backup/restore', methods=['POST'])
@login_required
@admin_required
def restore_backup():
    """Restore from backup - TODO: Implement"""
    return jsonify({'success': False, 'message': 'Not implemented yet'}), 501
