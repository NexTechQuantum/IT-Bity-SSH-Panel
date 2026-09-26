# app/user_mgmt/services/users.py
from datetime import datetime, timedelta
from flask_babel import gettext as _
from app import db
from app.models import User, UserLimit
from .wireguard import peer_payload, delete_peer as delete_wireguard_peer
from ..linux import (
    get_all_linux_users, check_linux_user_exists, reset_linux_password,
    rename_linux_user, delete_linux_user
)
from .limits import apply_limits_updates
from ..utils import generate_random_password
from .telemetry.connections import get_conns

def build_users_payload():
    db_users = User.query.all()
    linux_usernames = set(get_all_linux_users())
    db_usernames = {u.username for u in db_users}

    users_data = []

    # DB users
    for user in db_users:
        linux_exists = user.username in linux_usernames
        current_conns = 0 if user.role == 'admin' else get_conns(user.username)
        is_expired = False
        over_traffic = False
        max_conns = None

        data = {
            'id': user.id,
            'username': user.username,
            'role': user.role,
            'is_active': user.is_active,
            'created_at': user.created_at.strftime('%Y-%m-%d %H:%M'),
            'last_login': user.last_login.strftime('%Y-%m-%d %H:%M') if user.last_login else _('Never'),
            'sync_status': {'in_database': True, 'in_linux': linux_exists, 'synced': linux_exists},
            'linux_only': False
        }
        data['wireguard'] = peer_payload(user.wireguard_peer) if user.role != 'admin' else None

        if user.limits:
            download_bytes = user.limits.download_used_bytes or 0
            upload_bytes = user.limits.upload_used_bytes or 0
            limit_bytes = (user.limits.traffic_limit_gb or 0) * (1024 ** 3)
            over_traffic = (user.limits.traffic_limit_gb is not None and
                            download_bytes >= limit_bytes)
            is_expired = bool(user.limits.is_expired)
            max_conns = user.limits.max_connections

            data['limits'] = {
                'traffic_limit_gb': user.limits.traffic_limit_gb,
                # traffic_used_gb remains an API alias for older clients and
                # intentionally means download usage (the quota basis).
                'traffic_used_gb': round(download_bytes / (1024 ** 3), 3),
                'download_used_bytes': download_bytes,
                'upload_used_bytes': upload_bytes,
                'total_used_bytes': download_bytes + upload_bytes,
                'max_connections': user.limits.max_connections,
                'download_speed_mbps': user.limits.download_speed_mbps,
                'expires_at': user.limits.expires_at.strftime('%Y-%m-%d') if user.limits.expires_at else None,
                'is_expired': is_expired
            }

        data['current_connections'] = current_conns
        data['max_connections'] = max_conns
        data['problematic'] = (
            (not linux_exists) or
            (user.role != 'admin' and (is_expired or over_traffic or (max_conns is not None and current_conns > max_conns)))
        )
        users_data.append(data)

    # Linux-only (ردیف‌های مصنوعی) اینجا اضافه نمی‌کنیم؛ در linux_orphans انجام می‌شود
    return users_data, db_usernames, linux_usernames

def create_user_full(payload: dict):
    username = payload.get('username', '').strip()
    password = payload.get('password') or generate_random_password()
    traffic_limit = int(payload.get('traffic_limit', 50))
    max_connections = int(payload.get('max_connections', 2))
    download_speed = int(payload.get('download_speed', 0))
    expiry_days = int(payload.get('expiry_days', 30))

    if not username or len(username) < 3:
        return {'success': False, 'message': 'Username must be at least 3 characters'}, 400
    if User.query.filter_by(username=username).first():
        return {'success': False, 'message': 'Username already exists in database'}, 400
    if check_linux_user_exists(username):
        return {'success': False, 'message': 'Username already exists in system'}, 400

    # ایجاد کاربر لینوکسی
    from ..linux import create_linux_user
    ok, msg = create_linux_user(username, password)
    if not ok:
        return {'success': False, 'message': msg}, 500

    # ایجاد رکورد DB
    new_user = User(username=username, role='user', is_active=True)
    new_user.set_password(password)
    db.session.add(new_user)
    db.session.flush()

    expires_at = datetime.utcnow() + timedelta(days=expiry_days)
    limits = UserLimit(user_id=new_user.id,
                       traffic_limit_gb=traffic_limit,
                       max_connections=max_connections,
                       download_speed_mbps=download_speed,
                       expires_at=expires_at)
    db.session.add(limits)
    db.session.commit()

    return {'success': True, 'message': 'User created successfully',
            'user': {'id': new_user.id, 'username': username,
                     'password': password,
                     'expires_at': expires_at.strftime('%Y-%m-%d'),
                     'traffic_limit_gb': traffic_limit,
                     'max_connections': max_connections,
                     'download_speed_mbps': download_speed}}

def update_user_full(user_id: int, data: dict):
    user = User.query.get_or_404(user_id)

    if 'username' in data:
        new_u = data['username'].strip()
        if new_u and new_u != user.username:
            if User.query.filter_by(username=new_u).first():
                return {'success': False, 'message': 'Username already exists in database'}, 400
            if check_linux_user_exists(user.username):
                ok, msg = rename_linux_user(user.username, new_u)
                if not ok:
                    return {'success': False, 'message': msg}, 500
            user.username = new_u

    if data.get('password'):
        ok, msg = reset_linux_password(user.username, data['password'])
        if not ok:
            return {'success': False, 'message': msg}, 500
        user.set_password(data['password'])

    apply_limits_updates(user, data)

    if 'is_active' in data:
        user.is_active = bool(data['is_active'])

    db.session.commit()
    return {'success': True, 'message': 'User updated successfully'}

def delete_user_full(user_id: int):
    user = User.query.get_or_404(user_id)
    if user.role == 'admin':
        return {'success': False, 'message': 'Cannot delete admin user'}, 403
    username = user.username
    ok, msg = delete_linux_user(username)
    if not ok:
        return {'success': False, 'message': msg}, 500
    if user.wireguard_peer:
        delete_wireguard_peer(user.id)
    db.session.delete(user)
    db.session.commit()
    return {'success': True, 'message': 'User deleted successfully'}
