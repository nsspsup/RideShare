# create_db.py

from app import create_app, db
from app.models import User, Car, Trip
from datetime import datetime, timedelta
from werkzeug.security import generate_password_hash

app = create_app()

with app.app_context():
    print("Dropping all tables...")
    db.drop_all()

    print("Creating all tables...")
    db.create_all()


