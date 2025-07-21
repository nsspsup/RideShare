# app/models.py
from flask_login import UserMixin
from flask_sqlalchemy import SQLAlchemy
from sqlalchemy.dialects.postgresql import JSON
from datetime import datetime
from app.utils.geo import haversine, geocode_address
from app.extensions import db


class User(db.Model, UserMixin):
    """Represents a registered user."""
    __tablename__ = "user"
    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100))
    email = db.Column(db.String(150), unique=True, nullable=False)
    password_hash = db.Column(db.String(200), nullable=False)
    first_name = db.Column(db.String(100), nullable=True)
    last_name = db.Column(db.String(100), nullable=True)
    national_id = db.Column(db.String(50), nullable=False)

    is_admin = db.Column(db.Boolean, default=False)

    cars = db.relationship('Car', back_populates='user', cascade='all, delete-orphan')
    trips = db.relationship('Trip', back_populates='driver', cascade='all, delete-orphan')
    join_request = db.relationship("JoinRequest", back_populates="passenger", cascade="all, delete-orphan")

    def full_name(self):
        return f"{self.first_name} {self.last_name}"

    def has_notifications(self):
        # Returns True if user is a driver and has unnotified join requests on their trips
        return any(
            any(req.status == 'pending' and not req.notified for req in trip.join_request)
            for trip in self.trips
        )

class Car(db.Model):
    """Represents a user's registered vehicle."""
    __tablename__ = "car"
    id = db.Column(db.Integer, primary_key=True)
    user_id = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=False)
    make = db.Column(db.String(64), nullable=False)
    model = db.Column(db.String(64), nullable=False)
    year_of_make = db.Column(db.Integer)
    fuel_type = db.Column(db.String(20))
    avg_consumption = db.Column(db.Float)
    plate = db.Column(db.String(20), nullable=False)

    user = db.relationship('User', back_populates='cars')

class Trip(db.Model):
    __tablename__ = "trip"
    id = db.Column(db.Integer, primary_key=True)
    driver_id = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=False)
    start_location = db.Column(db.String(200), nullable=False)
    end_location = db.Column(db.String(200), nullable=False)
    start_lat = db.Column(db.Float)
    start_lng = db.Column(db.Float)
    end_lat = db.Column(db.Float)
    end_lng = db.Column(db.Float)
    route_geometry = db.Column(JSON, nullable=True)
    departure_time = db.Column(db.DateTime, nullable=False)

    route_distance_km = db.Column(db.Float, nullable=True)
    cost_total = db.Column(db.Float, nullable=True)
    cost_per_person = db.Column(db.Float, nullable=True)

    driver = db.relationship('User', back_populates='trips')
    car_id = db.Column(db.Integer, db.ForeignKey('car.id'), nullable=True)
    car = db.relationship('Car')
    join_request = db.relationship("JoinRequest", back_populates="trip", cascade="all, delete-orphan")

    def update_cost_per_person(self):
        if self.cost_total is None:
            self.cost_per_person = None
            return
        count = 1 + sum(1 for jr in self.join_request if jr.status == 'accepted')
        self.cost_per_person = self.cost_total / count if count > 0 else None

    def update_analytics(self):
        """Set distance and total cost based on geometry & car only once."""
        if not self.car or not self.route_geometry:
            self.route_distance_km = None
            self.cost_total = None
            self.cost_per_person = None
            return

        coords = self.route_geometry.get("coordinates", [])
        total_km = sum(
            haversine(lat1, lon1, lat2, lon2)
            for (lon1, lat1), (lon2, lat2) in zip(coords, coords[1:])
        )
        self.route_distance_km = total_km
        self.cost_total = (total_km / 100) * self.car.avg_consumption
        # driver initially only
        self.cost_per_person = self.cost_total
        # later passenger joins will trigger only per-person update

    @property
    def has_passenger(self):
        return any(jr.status in ('pending', 'accepted') for jr in self.join_requests)


class JoinRequest(db.Model):
    __tablename__ = "join_request"
    id = db.Column(db.Integer, primary_key=True)
    trip_id = db.Column(db.Integer, db.ForeignKey('trip.id'), nullable=False)
    passenger_id = db.Column(db.Integer, db.ForeignKey('user.id'), nullable=False)
    status = db.Column(db.String(20), default="pending")
    notified = db.Column(db.Boolean, default=False)

    trip = db.relationship("Trip", back_populates="join_request")
    passenger = db.relationship("User", back_populates="join_request")

