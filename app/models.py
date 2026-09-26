# app/models.py

from app import db
from flask_login import UserMixin
from werkzeug.security import generate_password_hash, check_password_hash
from datetime import datetime


# ==============================
# User Table
# ==============================
class User(UserMixin, db.Model):
    __tablename__ = 'users'
    
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(255), nullable=False)
    role = db.Column(db.String(20), default='user', nullable=False)
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, nullable=False)
    last_login = db.Column(db.DateTime)

    # Relationships
    limits = db.relationship(
        'UserLimit',
        backref='user',
        uselist=False,
        cascade='all, delete-orphan'
    )

    ip_sessions = db.relationship(
        'UserIPSession',
        backref='user',
        lazy=True,
        cascade='all, delete-orphan'
    )

    wireguard_peer = db.relationship(
        'WireGuardPeer', backref='user', uselist=False,
        cascade='all, delete-orphan'
    )

    tickets = db.relationship(
        'SupportTicket', backref='user', lazy=True,
        cascade='all, delete-orphan'
    )

    def set_password(self, password):
        self.password_hash = generate_password_hash(password)
    
    def check_password(self, password):
        return check_password_hash(self.password_hash, password)

    @property
    def user_type(self):
        return self.role

    def __repr__(self):
        return f'<User {self.username}>'


# ==============================
# User Limits
# ==============================
class UserLimit(db.Model):
    __tablename__ = 'user_limits'
    
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(
        db.Integer, 
        db.ForeignKey('users.id', ondelete='CASCADE'),
        nullable=False,
        unique=True
    )
    
    traffic_limit_gb = db.Column(db.Integer, default=50, nullable=False)
    # Keep exact counters in bytes.  Floating-point GB values drift over time
    # and cannot be updated safely by concurrent traffic samples.
    download_used_bytes = db.Column(db.BigInteger, default=0, nullable=False)
    upload_used_bytes = db.Column(db.BigInteger, default=0, nullable=False)
    # Legacy column kept for backwards-compatible upgrades. New code does not
    # use it as the source of truth.
    traffic_used_gb = db.Column(db.Float, default=0.0, nullable=False)
    max_connections = db.Column(db.Integer, default=2, nullable=False)
    download_speed_mbps = db.Column(db.Integer, default=0, nullable=False)
    expires_at = db.Column(db.DateTime)

    @property
    def traffic_remaining_gb(self):
        return max(0, self.traffic_limit_gb - self.download_used_gb)

    @property
    def download_used_gb(self):
        return self.download_used_bytes / (1024 ** 3)

    @property
    def upload_used_gb(self):
        return self.upload_used_bytes / (1024 ** 3)

    @property
    def total_used_gb(self):
        return (self.download_used_bytes + self.upload_used_bytes) / (1024 ** 3)
    
    @property
    def is_expired(self):
        return bool(self.expires_at and datetime.utcnow() > self.expires_at)
    
    def __repr__(self):
        return f'<UserLimit user_id={self.user_id}>'


# ==============================
# User IP Sessions (Traffic)
# ==============================
class UserIPSession(db.Model):
    __tablename__ = 'user_ip_sessions'

    id = db.Column(db.Integer, primary_key=True)

    user_id = db.Column(
        db.Integer,
        db.ForeignKey('users.id', ondelete='CASCADE'),
        nullable=False
    )

    ip_address = db.Column(db.String(45), nullable=False)
    session_id = db.Column(db.String(128), nullable=False)
    nft_rule_name = db.Column(db.String(128), nullable=False)

    # traffic counters
    bytes_in = db.Column(db.BigInteger, default=0, nullable=False)
    bytes_out = db.Column(db.BigInteger, default=0, nullable=False)

    created_at = db.Column(
        db.DateTime,
        default=datetime.utcnow,
        nullable=False
    )
    closed_at = db.Column(db.DateTime)

    def __repr__(self):
        return f'<UserIPSession user_id={self.user_id} ip={self.ip_address}>'


class WireGuardPeer(db.Model):
    __tablename__ = 'wireguard_peers'

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(
        db.Integer, db.ForeignKey('users.id', ondelete='CASCADE'),
        nullable=False, unique=True, index=True,
    )
    public_key = db.Column(db.String(64), unique=True, nullable=False)
    address = db.Column(db.String(45), unique=True, nullable=False)
    enabled = db.Column(db.Boolean, default=True, nullable=False)
    rx_bytes = db.Column(db.BigInteger, default=0, nullable=False)
    tx_bytes = db.Column(db.BigInteger, default=0, nullable=False)
    last_handshake_at = db.Column(db.DateTime)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, nullable=False)

    def __repr__(self):
        return f'<WireGuardPeer user_id={self.user_id} address={self.address}>'


class AppSetting(db.Model):
    __tablename__ = 'app_settings'

    key = db.Column(db.String(80), primary_key=True)
    value = db.Column(db.Text, nullable=False)


class SupportTicket(db.Model):
    __tablename__ = 'support_tickets'

    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey('users.id', ondelete='CASCADE'), nullable=False, index=True)
    subject = db.Column(db.String(160), nullable=False)
    message = db.Column(db.Text, nullable=False)
    status = db.Column(db.String(20), default='open', nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, nullable=False)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow, nullable=False)


class RecommendedApp(db.Model):
    __tablename__ = 'recommended_apps'

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    platform = db.Column(db.String(40), nullable=False)
    download_url = db.Column(db.String(500), nullable=False)
    icon = db.Column(db.String(60), default='fa-download', nullable=False)
    is_active = db.Column(db.Boolean, default=True, nullable=False)
    sort_order = db.Column(db.Integer, default=0, nullable=False)

DEFAULT_RECOMMENDED_APPS = (
    ('WireGuard', 'Android', 'https://www.wireguard.com/install/', 'fa-shield-halved', 10),
    ('HTTP Injector', 'Android', 'https://play.google.com/store/apps/details?id=com.evozi.injector', 'fa-mobile-screen-button', 11),
    ('WireGuard', 'iPhone', 'https://www.wireguard.com/install/', 'fa-shield-halved', 20),
    ('Termius', 'iPhone', 'https://termius.com/download/ios', 'fa-terminal', 21),
    ('WireGuard', 'Windows', 'https://www.wireguard.com/install/', 'fa-shield-halved', 30),
    ('Bitvise SSH Client', 'Windows', 'https://bitvise.com/ssh-client-download', 'fa-terminal', 31),
    ('WireGuard', 'Linux', 'https://www.wireguard.com/install/', 'fa-shield-halved', 40),
    ('Termius', 'Linux', 'https://termius.com/download/linux', 'fa-terminal', 41),
)

def ensure_default_recommended_apps():
    if RecommendedApp.query.first() is not None:
        return
    for name, platform, url, icon, order in DEFAULT_RECOMMENDED_APPS:
        db.session.add(RecommendedApp(name=name, platform=platform, download_url=url, icon=icon, sort_order=order))
    db.session.commit()
