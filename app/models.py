# app/models.py
from flask_login import UserMixin
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy.dialects.postgresql import JSON
from datetime import datetime

db = SQLAlchemy()


class User(db.Model, UserMixin):
    """Represents a registered user."""
    id = db.Column(db.Integer, primary_key=True)
    email = db.Column(db.String(150), unique=True, nullable=False)
    password_hash = db.Column(db.String(200), nullable=False)
    first_name = db.Column(db.String(100), nullable=False)
    last_name = db.Column(db.String(100), nullable=False)
    national_id = db.Column(db.String(50), nullable=False)

    is_admin = db.Column(db.Boolean, default=False)

    cars = db.relationship('Car', back_populates='user', cascade='all, delete-orphan')
    trips = db.relationship('Trip', back_populates='driver', cascade='all, delete-orphan')


class Car(db.Model):
    """Represents a user's registered vehicle."""
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=False)
    make = db.Column(db.String(64), nullable=False)
    model = db.Column(db.String(64), nullable=False)
    year_of_make = db.Column(db.Integer)
    fuel_type = db.Column(db.String(20))
    avg_consumption = db.Column(db.Float)
    seats = db.Column(db.Integer, nullable=False)
    plate = db.Column(db.String(20), nullable=False)

    user = db.relationship('User', back_populates='cars')


class Trip(db.Model):
    """Represents a planned ride/trip."""
    id = db.Column(db.Integer, primary_key=True)
    driver_id = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=False)
    start_location = db.Column(db.String(200), nullable=False)
    end_location = db.Column(db.String(200), nullable=False)
    start_lat = db.Column(db.Float)
    start_lng = db.Column(db.Float)
    end_lat = db.Column(db.Float)
    end_lng = db.Column(db.Float)
    available_seats = db.Column(db.Integer, nullable=False)
    cost_split = db.Column(db.String(100), default="50/50")
    allow_deviation = db.Column(db.Boolean, default=False)
    max_deviation_km = db.Column(db.Float, nullable=True)
    route_geometry = db.Column(JSON, nullable=True)
    departure_time = db.Column(db.DateTime, nullable=False)

    driver = db.relationship('User', back_populates='trips')
