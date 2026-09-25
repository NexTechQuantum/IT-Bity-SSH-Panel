# app/__init__.py
from flask import Flask, request, session
from flask_babel import Babel
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager
from flask_migrate import Migrate
from config import Config

db = SQLAlchemy()
babel = Babel()
login_manager = LoginManager()
migrate = Migrate()

def get_locale():
    if 'language' in session:
        return session['language']
    return request.accept_languages.best_match(
        Config.LANGUAGES.keys(),
        default=Config.BABEL_DEFAULT_LOCALE,
    )

def create_app(config_class=Config):
    app = Flask(__name__, 
                template_folder='../templates',
                static_folder='../static')
    app.config.from_object(config_class)
    app.url_map.strict_slashes = False
    
    # Initialize extensions
    db.init_app(app)
    babel.init_app(app, locale_selector=get_locale)
    login_manager.init_app(app)
    migrate.init_app(app, db)
    
    # Flask-Login settings
    login_manager.login_view = 'auth.login_page'
    login_manager.login_message = 'لطفاً ابتدا وارد شوید'
    
    @login_manager.user_loader
    def load_user(user_id):
        from app.models import User
        return User.query.get(int(user_id))
    
    @app.context_processor
    def inject_locale():
        return dict(get_locale=get_locale)
    
    # Register blueprints
    from app.routes import main_bp
    from app.auth import auth_bp
    from app.api import api_bp
    from app.user_management import user_management_bp
    from app.settings import settings_bp
    
    app.register_blueprint(main_bp, url_prefix=f'/{app.config["PANEL_PATH"]}')
    app.register_blueprint(auth_bp, url_prefix=f'/{app.config["PANEL_PATH"]}')
    app.register_blueprint(api_bp, url_prefix=f'/{app.config["PANEL_PATH"]}/api')
    app.register_blueprint(user_management_bp, url_prefix=f'/{app.config["PANEL_PATH"]}/user_management')
    app.register_blueprint(settings_bp, url_prefix=f'/{app.config["PANEL_PATH"]}/settings')
    
    return app
