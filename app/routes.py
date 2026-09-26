from flask import Blueprint, render_template, redirect, url_for, current_app
from flask_login import login_required, current_user

main_bp = Blueprint('main', __name__)

@main_bp.route('/')
def index():
    if current_user.is_authenticated:
        return redirect(url_for('main.dashboard'))
    return redirect(url_for('auth.login_page'))

@main_bp.route('/dashboard')
@login_required
def dashboard():
    if current_user.role == 'admin':
        return render_template('admindashboard.html')
    else:
        return redirect(url_for('user_panel.dashboard'))
