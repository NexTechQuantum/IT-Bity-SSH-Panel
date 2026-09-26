from flask import Blueprint, render_template, request, jsonify, flash, redirect, url_for
from flask_login import login_required, current_user
from flask_babel import gettext as _
from functools import wraps
import json
import os
import subprocess
import uuid
from app import db
from app.models import AppSetting, RecommendedApp, ensure_default_recommended_apps

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
def _ssl_helper(*arguments, timeout=180):
    result = subprocess.run(['/usr/bin/sudo', '/usr/local/sbin/itbity-ssl', *map(str, arguments)], capture_output=True, text=True, timeout=timeout)
    payload = json.loads(result.stdout or '{}')
    if result.returncode != 0 or not payload.get('success'):
        raise RuntimeError(payload.get('message') or result.stderr.strip() or 'SSL operation failed')
    return payload

@settings_bp.route('/api/ssl/status', methods=['GET'])
@login_required
@admin_required
def get_ssl_status():
    try: return jsonify(_ssl_helper('status', timeout=15))
    except Exception as error: return jsonify({'success': False, 'message': str(error)}), 500

@settings_bp.route('/api/ssl/check', methods=['POST'])
@login_required
@admin_required
def check_ssl_domain():
    domain = str((request.get_json(silent=True) or {}).get('domain', '')).strip()
    try: return jsonify(_ssl_helper('check', domain, timeout=20))
    except Exception as error: return jsonify({'success': False, 'message': str(error)}), 400

@settings_bp.route('/api/ssl/install', methods=['POST'])
@login_required
@admin_required
def install_ssl():
    domain = str((request.get_json(silent=True) or {}).get('domain', '')).strip()
    try: return jsonify(_ssl_helper('install', domain))
    except Exception as error: return jsonify({'success': False, 'message': str(error)}), 500

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


def _backup_helper(*arguments, input_text=None, timeout=30):
    result = subprocess.run(
        ['/usr/bin/sudo', '/usr/local/sbin/itbity-backup', *map(str, arguments)],
        input=input_text, capture_output=True, text=True, timeout=timeout,
    )
    try:
        payload = json.loads(result.stdout or '{}')
    except json.JSONDecodeError:
        payload = {'success': False, 'message': result.stderr.strip() or 'Invalid backup helper response'}
    if result.returncode != 0 or not payload.get('success'):
        raise RuntimeError(payload.get('message') or result.stderr.strip() or 'Backup operation failed')
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
@settings_bp.route('/api/user-panel/status', methods=['GET'])
@login_required
@admin_required
def user_panel_status():
    setting = db.session.get(AppSetting, 'user_panel_enabled')
    response = jsonify({'success': True, 'enabled': setting is None or setting.value == 'true'})
    response.headers['Cache-Control'] = 'no-store'
    return response


@settings_bp.route('/api/user-panel/toggle', methods=['POST'])
@login_required
@admin_required
def toggle_user_panel():
    payload = request.get_json(silent=True) or {}
    enabled = payload.get('enabled')
    if not isinstance(enabled, bool):
        return jsonify({'success': False, 'message': 'Enabled must be true or false'}), 400
    setting = db.session.get(AppSetting, 'user_panel_enabled')
    if not setting:
        setting = AppSetting(key='user_panel_enabled', value='true')
        db.session.add(setting)
    setting.value = 'true' if enabled else 'false'
    db.session.commit()
    return jsonify({'success': True, 'enabled': enabled})


@settings_bp.route('/api/user-panel/apps', methods=['GET', 'POST'])
@login_required
@admin_required
def user_panel_apps():
    if request.method == 'GET':
        ensure_default_recommended_apps()
        apps = RecommendedApp.query.order_by(RecommendedApp.sort_order, RecommendedApp.name).all()
        return jsonify({'success': True, 'apps': [
            {'id': app.id, 'name': app.name, 'platform': app.platform,
             'download_url': app.download_url, 'is_active': app.is_active}
            for app in apps
        ]})
    payload = request.get_json(silent=True) or {}
    name = str(payload.get('name', '')).strip()
    platform = str(payload.get('platform', '')).strip()
    download_url = str(payload.get('download_url', '')).strip()
    if platform not in {'Android', 'iPhone', 'Windows', 'Linux'}:
        return jsonify({'success': False, 'message': 'Choose a supported operating system'}), 400
    if not name or not download_url.startswith(('https://', 'http://')):
        return jsonify({'success': False, 'message': 'Enter a name, platform and valid download URL'}), 400
    app = RecommendedApp(name=name[:100], platform=platform[:40], download_url=download_url[:500])
    db.session.add(app)
    db.session.commit()
    return jsonify({'success': True, 'id': app.id})


@settings_bp.route('/api/user-panel/apps/<int:app_id>', methods=['DELETE'])
@login_required
@admin_required
def delete_user_panel_app(app_id):
    app = RecommendedApp.query.get_or_404(app_id)
    db.session.delete(app)
    db.session.commit()
    return jsonify({'success': True})

# Backup & Restore
@settings_bp.route('/api/backup/status', methods=['GET'])
@login_required
@admin_required
def backup_status():
    try:
        response = jsonify(_backup_helper('status'))
        response.headers['Cache-Control'] = 'no-store'
        return response
    except Exception as error:
        return jsonify({'success': False, 'message': str(error)}), 500


@settings_bp.route('/api/backup/config', methods=['PUT'])
@login_required
@admin_required
def save_backup_config():
    payload = request.get_json(silent=True) or {}
    schedule = str(payload.get('schedule', '')).strip()
    chat_id = str(payload.get('chat_id', '')).strip()
    token = str(payload.get('token', '')).strip()
    try:
        return jsonify(_backup_helper('configure', schedule, chat_id, input_text=token, timeout=40))
    except Exception as error:
        return jsonify({'success': False, 'message': str(error)}), 400


@settings_bp.route('/api/backup/test', methods=['POST'])
@login_required
@admin_required
def test_backup_connection():
    try:
        return jsonify(_backup_helper('test', timeout=40))
    except Exception as error:
        return jsonify({'success': False, 'message': str(error)}), 400


@settings_bp.route('/api/backup/create', methods=['POST'])
@login_required
@admin_required
def create_backup():
    try:
        return jsonify(_backup_helper('trigger', timeout=20))
    except Exception as error:
        return jsonify({'success': False, 'message': str(error)}), 500

@settings_bp.route('/api/backup/restore', methods=['POST'])
@login_required
@admin_required
def restore_backup():
    payload = request.get_json(silent=True) or {}
    if payload.get('confirmation') != 'RESTORE':
        return jsonify({'success': False, 'message': 'Type RESTORE to confirm'}), 400
    if not current_user.check_password(str(payload.get('admin_password', ''))):
        return jsonify({'success': False, 'message': 'Administrator password is incorrect'}), 403
    restore_id = str(payload.get('restore_id', ''))
    mode = str(payload.get('mode', 'data'))
    try:
        return jsonify(_backup_helper('restore-trigger', restore_id, mode, timeout=20))
    except Exception as error:
        return jsonify({'success': False, 'message': str(error)}), 400


@settings_bp.route('/api/backup/restore/upload', methods=['POST'])
@login_required
@admin_required
def upload_restore_backup():
    uploaded = request.files.get('backup')
    if not uploaded or not uploaded.filename.lower().endswith('.zip'):
        return jsonify({'success': False, 'message': 'Choose an IT Bity ZIP backup'}), 400
    if request.content_length and request.content_length > 51 * 1024 * 1024:
        return jsonify({'success': False, 'message': 'Backup file is larger than 50 MB'}), 413
    path = f'/tmp/itbity-restore-{uuid.uuid4().hex}.zip'
    try:
        descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(descriptor)
        uploaded.save(path)
        return jsonify(_backup_helper('stage', os.path.basename(path), timeout=40))
    except Exception as error:
        try:
            os.unlink(path)
        except OSError:
            pass
        return jsonify({'success': False, 'message': str(error)}), 400
