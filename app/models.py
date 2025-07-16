# app/models.py
from flask_login import UserMixin
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy.dialects.postgresql import JSON
from datetime import datetime
from sqlalchemy import DateTime

db = SQLAlchemy()  # define locally here



class User(db.Model, UserMixin):
    id = db.Column(db.Integer, primary_key=True)
    email = db.Column(db.String(150), unique=True, nullable=False)
    password_hash = db.Column(db.String(200), nullable=False)
    first_name = db.Column(db.String(100), nullable=False)
    last_name = db.Column(db.String(100), nullable=False)
    national_id = db.Column(db.String(50), nullable=False)

    car_type = db.Column(db.String(100))
    car_model = db.Column(db.String(100))
    year_of_make = db.Column(db.Integer)
    seats = db.Column(db.Integer)
    fuel_type = db.Column(db.String(20))
    avg_consumption = db.Column(db.Float)

class Trip(db.Model):
    start_lat = db.Column(db.Float)
    start_lng = db.Column(db.Float)
    end_lat = db.Column(db.Float)
    end_lng = db.Column(db.Float)

    id = db.Column(db.Integer, primary_key=True)
    driver_id = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=False)
    start_location = db.Column(db.String(200), nullable=False)
    end_location = db.Column(db.String(200), nullable=False)
    available_seats = db.Column(db.Integer, nullable=False)
    cost_split = db.Column(db.String(100), default="50/50")  # default split
    allow_deviation = db.Column(db.Boolean, default=False)
    max_deviation_km = db.Column(db.Float,nullable=True)
    route_geometry = db.Column(JSON, nullable=True)  # stores GeoJSON LineString
    departure_time = db.Column(db.DateTime, nullable=False)

    driver = db.relationship('User', backref='trips')
