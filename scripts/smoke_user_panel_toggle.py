"""Safe smoke test for the user-panel availability switch."""

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app import create_app
from app.models import User


app = create_app()
prefix = f'/{app.config["PANEL_PATH"]}'

with app.app_context():
    admin = User.query.filter_by(role='admin').first()
    if not admin:
        raise RuntimeError('Administrator account not found')
    admin_id = str(admin.id)

client = app.test_client()
with client.session_transaction() as session:
    session['_user_id'] = admin_id
    session['_fresh'] = True

status = client.get(f'{prefix}/settings/api/user-panel/status').get_json()
original = bool(status['enabled'])

try:
    disabled = client.post(f'{prefix}/settings/api/user-panel/toggle', json={'enabled': False})
    assert disabled.status_code == 200 and disabled.get_json()['enabled'] is False
    public = app.test_client()
    assert public.get(f'{prefix}/user/login').status_code == 404
    assert b'User panel login' not in public.get(f'{prefix}/', follow_redirects=True).data

    enabled = client.post(f'{prefix}/settings/api/user-panel/toggle', json={'enabled': True})
    assert enabled.status_code == 200 and enabled.get_json()['enabled'] is True
    public = app.test_client()
    assert public.get(f'{prefix}/user/login').status_code == 200
    assert b'User panel login' in public.get(f'{prefix}/', follow_redirects=True).data
    print('user-panel-toggle-smoke: ok')
finally:
    client.post(f'{prefix}/settings/api/user-panel/toggle', json={'enabled': original})
