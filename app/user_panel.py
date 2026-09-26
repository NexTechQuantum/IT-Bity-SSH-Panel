from datetime import datetime
from functools import wraps
import subprocess

from flask import Blueprint, Response, abort, flash, jsonify, redirect, render_template, request, url_for
from flask_login import current_user, login_required, login_user, logout_user

from app import db
from app.models import AppSetting, RecommendedApp, SupportTicket, User, UserIPSession
from app.user_mgmt.linux import reset_linux_password
from app.user_mgmt.services.telemetry.connections import get_conns
from app.user_mgmt.services.wireguard import get_client_config


user_panel_bp = Blueprint('user_panel', __name__)


def panel_enabled():
    setting = db.session.get(AppSetting, 'user_panel_enabled')
    return setting is None or setting.value == 'true'


def user_required(view):
    @wraps(view)
    @login_required
    def wrapped(*args, **kwargs):
        if current_user.role != 'user':
            abort(403)
        if not panel_enabled():
            logout_user()
            flash('User panel is currently unavailable.', 'warning')
            return redirect(url_for('user_panel.login_page'))
        return view(*args, **kwargs)
    return wrapped


@user_panel_bp.route('/login', methods=['GET', 'POST'])
def login_page():
    if current_user.is_authenticated:
        if current_user.role == 'user' and panel_enabled():
            return redirect(url_for('user_panel.dashboard'))
        if current_user.role == 'admin':
            return redirect(url_for('main.dashboard'))

    if request.method == 'POST':
        if not panel_enabled():
            flash('User panel is currently unavailable.', 'warning')
        else:
            username = request.form.get('username', '').strip()
            password = request.form.get('password', '')
            user = User.query.filter_by(username=username, role='user', is_active=True).first()
            if user and user.check_password(password):
                login_user(user, remember=bool(request.form.get('remember')))
                user.last_login = datetime.utcnow()
                db.session.commit()
                return redirect(url_for('user_panel.dashboard'))
            flash('Invalid username or password.', 'error')

    return render_template('user_login.html', panel_enabled=panel_enabled())


@user_panel_bp.route('/logout')
@login_required
def logout():
    logout_user()
    return redirect(url_for('user_panel.login_page'))


@user_panel_bp.route('/')
@user_required
def dashboard():
    limits = current_user.limits
    now = datetime.utcnow()
    days_remaining = None
    if limits and limits.expires_at:
        days_remaining = max(0, (limits.expires_at.date() - now.date()).days)

    sessions = (UserIPSession.query.filter_by(user_id=current_user.id)
                .order_by(UserIPSession.created_at.desc()).limit(12).all())
    tickets = (SupportTicket.query.filter_by(user_id=current_user.id)
               .order_by(SupportTicket.created_at.desc()).limit(5).all())
    apps = (RecommendedApp.query.filter_by(is_active=True)
            .order_by(RecommendedApp.sort_order, RecommendedApp.name).all())

    return render_template(
        'userdashboard.html', limits=limits, days_remaining=days_remaining,
        sessions=sessions, tickets=tickets, recommended_apps=apps,
        active_connections=get_conns(current_user.username),
        wireguard=current_user.wireguard_peer,
    )


@user_panel_bp.route('/api/password', methods=['PUT'])
@user_required
def change_password():
    payload = request.get_json(silent=True) or {}
    current_password = payload.get('current_password', '')
    new_password = payload.get('new_password', '')
    if not current_user.check_password(current_password):
        return jsonify(success=False, message='Current password is incorrect'), 400
    if len(new_password) < 8:
        return jsonify(success=False, message='New password must contain at least 8 characters'), 400
    ok, message = reset_linux_password(current_user.username, new_password)
    if not ok:
        return jsonify(success=False, message=message), 500
    current_user.set_password(new_password)
    db.session.commit()
    return jsonify(success=True, message='Password updated successfully')


@user_panel_bp.route('/api/tickets', methods=['POST'])
@user_required
def create_ticket():
    payload = request.get_json(silent=True) or {}
    subject = str(payload.get('subject', '')).strip()
    message = str(payload.get('message', '')).strip()
    if not 3 <= len(subject) <= 160 or not 10 <= len(message) <= 5000:
        return jsonify(success=False, message='Please enter a valid subject and message'), 400
    ticket = SupportTicket(user_id=current_user.id, subject=subject, message=message)
    db.session.add(ticket)
    db.session.commit()
    return jsonify(success=True, message='Ticket submitted', ticket_id=ticket.id)


@user_panel_bp.route('/wireguard/config')
@user_required
def wireguard_config():
    if not current_user.wireguard_peer:
        abort(404)
    config, _ = get_client_config(current_user.id)
    if request.args.get('download') == '1':
        return Response(config, mimetype='text/plain', headers={
            'Content-Disposition': f'attachment; filename=itbity-{current_user.username}.conf',
            'Cache-Control': 'no-store, private',
        })
    return Response(config, mimetype='text/plain', headers={'Cache-Control': 'no-store, private'})


@user_panel_bp.route('/wireguard/qrcode')
@user_required
def wireguard_qrcode():
    if not current_user.wireguard_peer:
        abort(404)
    config, _ = get_client_config(current_user.id)
    process = subprocess.run(
        ['/usr/bin/qrencode', '-t', 'PNG', '-o', '-', '-s', '5', '-m', '2'],
        input=config.encode(), capture_output=True, timeout=10,
    )
    if process.returncode != 0:
        abort(500)
    disposition = 'attachment' if request.args.get('download') == '1' else 'inline'
    return Response(process.stdout, mimetype='image/png', headers={
        'Content-Disposition': f'{disposition}; filename=itbity-{current_user.username}-wireguard.png',
        'Cache-Control': 'no-store, private',
    })
