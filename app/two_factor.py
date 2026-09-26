import base64
from io import BytesIO
import pyotp
import qrcode
from app import db
from app.models import AppSetting

def _key(user_id, suffix): return f'totp_{user_id}_{suffix}'
def _get(key, default=''):
    setting = db.session.get(AppSetting, key)
    return setting.value if setting else default
def _set(key, value):
    setting = db.session.get(AppSetting, key)
    if setting is None:
        db.session.add(AppSetting(key=key, value=str(value)))
    else: setting.value = str(value)
def enabled(user): return _get(_key(user.id, 'enabled')) == 'true'
def enforced_for_users(): return _get('two_factor_enforce_users') == 'true'
def set_enforced(value):
    _set('two_factor_enforce_users', 'true' if value else 'false'); db.session.commit()
def secret(user, create=False):
    value = _get(_key(user.id, 'secret'))
    if not value and create:
        value = pyotp.random_base32(); _set(_key(user.id, 'secret'), value); db.session.commit()
    return value
def provisioning(user):
    value = secret(user, create=True)
    uri = pyotp.TOTP(value).provisioning_uri(name=user.username, issuer_name='IT Bity Panel')
    image = qrcode.make(uri); buffer = BytesIO(); image.save(buffer, format='PNG')
    return uri, 'data:image/png;base64,' + base64.b64encode(buffer.getvalue()).decode()
def verify(user, code):
    value = secret(user)
    return bool(value and pyotp.TOTP(value).verify(str(code).replace(' ', ''), valid_window=1))
def activate(user, code):
    if not verify(user, code): return False
    _set(_key(user.id, 'enabled'), 'true'); db.session.commit(); return True
def disable(user):
    for suffix in ('enabled', 'secret'):
        setting = db.session.get(AppSetting, _key(user.id, suffix))
        if setting: db.session.delete(setting)
    db.session.commit()
