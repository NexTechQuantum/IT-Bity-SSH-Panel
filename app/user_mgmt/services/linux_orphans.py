# app/user_mgmt/services/linux_orphans.py
from datetime import datetime, timedelta
from app import db
from app.models import User, UserLimit
from ..linux import (
    get_all_linux_users, check_linux_user_exists, reset_linux_password, delete_linux_user
)

def list_linux_only_usernames() -> list[str]:
    db_usernames = {u.username for u in User.query.all()}
    linux_usernames = set(get_all_linux_users())
    return sorted(list(linux_usernames - db_usernames))

def import_linux_user(username: str):
    username = (username or '').strip()
    if not username:
        return {'success': False, 'message': 'username is required'}, 400
    if not check_linux_user_exists(username):
        return {'success': False, 'message': 'Linux user not found'}, 404
    if User.query.filter_by(username=username).first():
        return {'success': False, 'message': 'User already exists in database'}, 400

    # پسورد جدید روی لینوکس تا ادمین credential داشته باشد
    from ..utils import generate_random_password
    new_password = generate_random_password()
    ok, msg = reset_linux_password(username, new_password)
    if not ok:
        return {'success': False, 'message': msg}, 500

    # ساخت رکورد DB + limits پیش‌فرض
    new_user = User(username=username, role='user', is_active=True)
    new_user.set_password(new_password)
    db.session.add(new_user)
    db.session.flush()

    expires_at = datetime.utcnow() + timedelta(days=30)
    limits = UserLimit(
        user_id=new_user.id,
        traffic_limit_gb=50,
        max_connections=2, download_speed_mbps=0,
        expires_at=expires_at
    )
    db.session.add(limits)
    db.session.commit()

    return {
        'success': True,
        'message': 'Linux user imported to DB',
        'user': {
            'id': new_user.id,
            'username': username,
            'password': new_password,
            'expires_at': expires_at.strftime('%Y-%m-%d')
        }
    }

def clean_orphans():
    linux_users = get_all_linux_users()
    db_usernames = [u.username for u in User.query.all()]
    orphans = [u for u in linux_users if u not in db_usernames]
    cleaned = 0
    for username in orphans:
        ok, _ = delete_linux_user(username)
        if ok:
            cleaned += 1
    return {'success': True, 'message': f'Cleaned {cleaned} orphaned users'}
