# app/user_mgmt/services/__init__.py
from .users import (
    build_users_payload as _build_users_payload_core,
    create_user_full, update_user_full, delete_user_full
)
from .linux_orphans import list_linux_only_usernames, import_linux_user, clean_orphans
from .sync import repair_all, repair_user
from .wireguard import create_peer, get_client_config, set_peer_enabled, delete_peer

def build_users_payload():
    users_data, db_usernames, linux_usernames = _build_users_payload_core()
    # الحاق linux-only به خروجی نهایی
    linux_only = sorted(list(linux_usernames - db_usernames))
    for lx in linux_only:
        users_data.append({
            'id': None,
            'username': lx,
            'role': 'user',
            'is_active': True,
            'created_at': '-',
            'last_login': '-',
            'sync_status': {'in_database': False, 'in_linux': True, 'synced': False},
            'limits': None,
            'current_connections': 0,
            'max_connections': None,
            'linux_only': True,
            'problematic': True
        })
    return users_data, linux_only

# re-export actions for routes
action_repair_all = repair_all
action_repair_user = repair_user
action_import_linux_user = import_linux_user
action_clean_orphans = clean_orphans
