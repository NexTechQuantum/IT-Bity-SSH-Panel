from flask import Blueprint, render_template, request, redirect, url_for, session, flash
from flask_babel import gettext as _
from flask_login import login_user, logout_user, login_required, current_user
from app import db
from app.models import AppSetting, User
from datetime import datetime

auth_bp = Blueprint('auth', __name__)

@auth_bp.route('', methods=['GET'])  
def login_page():
    if current_user.is_authenticated:
        return redirect(url_for('main.dashboard') if current_user.role == 'admin' else url_for('user_panel.dashboard'))
    setting = db.session.get(AppSetting, 'user_panel_enabled')
    user_panel_enabled = setting is None or setting.value == 'true'
    return render_template('login.html', user_panel_enabled=user_panel_enabled)

@auth_bp.route('/login', methods=['POST'])
def login():
    username = request.form.get('username')
    password = request.form.get('password')
    remember = request.form.get('remember', False)
    
    user = User.query.filter_by(username=username, role='admin').first()
    
    if user:
        if user.check_password(password):
            login_user(user, remember=remember)
            
            user.last_login = datetime.utcnow()
            db.session.commit()
            
            flash(_('Successfully logged in!'), 'success')
            
            next_page = request.args.get('next')
            return redirect(next_page or url_for('main.dashboard'))
    
    flash(_('Invalid username or password!'), 'error')
    return redirect(url_for('auth.login_page'))

@auth_bp.route('/logout')
@login_required
def logout():
    logout_user()
    flash(_('Successfully logged out!'), 'info')
    return redirect(url_for('auth.login_page'))

@auth_bp.route('/change-language/<lang>')
def change_language(lang):
    from config import Config
    if lang in Config.LANGUAGES:
        session['language'] = lang
    return redirect(request.referrer or url_for('auth.login_page'))
