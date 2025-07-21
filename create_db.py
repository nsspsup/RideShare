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

    # Sample users
    user1 = User(
        name="Alice",
        email="alice@example.com",
        password_hash=generate_password_hash("password1"),
        first_name="Alice",
        last_name="Smith",
        national_id="SK1234567890",
        is_admin=False
    )

    user2 = User(
        name="Bob",
        email="bob@example.com",
        password_hash=generate_password_hash("password2"),
        first_name="Bob",
        last_name="Brown",
        national_id="SK0987654321",
        is_admin=False
    )
    db.session.add_all([user1, user2])
    db.session.commit()

    # Sample cars
    car1 = Car(
        user_id=user1.id,
        make="Toyota",
        model="Corolla",
        seats=4,
        year_of_make=2020,
        fuel_type="Petrol",
        avg_consumption=6.5,
        plate="BL123AB"
    )
    car2 = Car(
        user_id=user2.id,
        make="Volkswagen",
        model="Golf",
        seats=4,
        year_of_make=2021,
        fuel_type="Petrol",
        avg_consumption=6.5,
        plate="BA323AB"
    )
    db.session.add_all([car1, car2])
    db.session.commit()

    # Sample trips
    trip1 = Trip(
        driver_id=user1.id,
        car_id=car1.id,
        start_location="Bratislava",
        end_location="Vienna",
        start_lat=48.1486,
        start_lng=17.1077,
        end_lat=48.2082,
        end_lng=16.3738,
        available_seats=1,
        cost_split=True,
        departure_time=datetime.utcnow() + timedelta(days=1),
        route_geometry=None  # Can add sample GeoJSON if needed
    )
    trip2 = Trip(
        driver_id=user2.id,
        car_id=car2.id,
        start_location="Trnava",
        end_location="Brno",
        start_lat=48.3774,
        start_lng=17.5872,
        end_lat=49.1951,
        end_lng=16.6068,
        available_seats=1,
        cost_split=False,
        departure_time=datetime.utcnow() + timedelta(days=2),
        route_geometry=None
    )
    db.session.add_all([trip1, trip2])
    db.session.commit()

    print("✔️ Sample users, cars, and trips added.")
