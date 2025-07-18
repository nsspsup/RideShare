from app import create_app, db
from app.models import User
from werkzeug.security import generate_password_hash

app = create_app()
with app.app_context():
    if not User.query.filter_by(email='admin@rideshare.sk').first():
        admin = User(
            email='admin@rideshare.sk',
            password_hash=generate_password_hash('admin123'),  # Change this later!
            first_name='Admin',
            last_name='User',
            national_id='ADMIN001',
            is_admin=True
        )
        db.session.add(admin)
        db.session.commit()
        print("Admin user created.")
    else:
        print("Admin user already exists.")
