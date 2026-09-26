import json
import subprocess

from app import db
from app.models import User, WireGuardPeer

HELPER = '/usr/local/sbin/itbity-wireguard'


def _helper(*arguments):
    result = subprocess.run(
        ['/usr/bin/sudo', HELPER, *map(str, arguments)],
        capture_output=True, text=True, timeout=20,
    )
    try:
        payload = json.loads(result.stdout or '{}')
    except json.JSONDecodeError:
        payload = {'success': False, 'message': result.stderr.strip() or 'Invalid helper response'}
    if result.returncode != 0 or not payload.get('success'):
        raise RuntimeError(payload.get('message') or 'WireGuard operation failed')
    return payload


def create_peer(user_id):
    user = User.query.get_or_404(user_id)
    if user.role == 'admin':
        return {'success': False, 'message': 'WireGuard is not available for administrators'}, 400
    payload = _helper('create', user.id, user.username)
    peer_data = payload['peer']
    peer = WireGuardPeer.query.filter_by(user_id=user.id).first()
    if not peer:
        peer = WireGuardPeer(user_id=user.id)
        db.session.add(peer)
    peer.public_key = peer_data['public_key']
    peer.address = peer_data['address']
    peer.enabled = bool(peer_data.get('enabled', True))
    db.session.commit()
    return {'success': True, 'message': 'WireGuard configuration created', 'peer': peer_payload(peer)}


def get_client_config(user_id):
    peer = WireGuardPeer.query.filter_by(user_id=user_id).first_or_404()
    payload = _helper('config', user_id)
    return payload['config'], peer


def set_peer_enabled(user_id, enabled):
    peer = WireGuardPeer.query.filter_by(user_id=user_id).first_or_404()
    _helper('enable' if enabled else 'disable', user_id)
    peer.enabled = enabled
    db.session.commit()
    return {'success': True, 'message': f'WireGuard peer {"enabled" if enabled else "disabled"}', 'peer': peer_payload(peer)}


def delete_peer(user_id):
    peer = WireGuardPeer.query.filter_by(user_id=user_id).first_or_404()
    _helper('delete', user_id)
    db.session.delete(peer)
    db.session.commit()
    return {'success': True, 'message': 'WireGuard configuration deleted'}


def peer_payload(peer):
    if not peer:
        return {'exists': False}
    return {
        'exists': True,
        'enabled': peer.enabled,
        'address': peer.address,
        'last_handshake_at': peer.last_handshake_at.isoformat() if peer.last_handshake_at else None,
    }
