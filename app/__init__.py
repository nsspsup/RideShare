# app/__init__.py
from flask import Flask
from flask_login import LoginManager, current_user
from dotenv import load_dotenv
from app.extensions import db, migrate  # Import from extensions

login_manager = LoginManager()

def create_app():
    load_dotenv()
    app = Flask(__name__)
    app.config.from_object('config.Config')

    db.init_app(app)
    migrate.init_app(app, db)

    login_manager.init_app(app)
    login_manager.login_view = 'main.login'

    from app.models import User, JoinRequest  # Import JoinRequest for context processor

    @login_manager.user_loader
    def load_user(user_id):
        return User.query.get(int(user_id))

    # ✅ Context processor for notification badge
    @app.context_processor
    def inject_notification_status():
        if current_user.is_authenticated:
            show_notification = JoinRequest.query.filter_by(passenger_id=current_user.id, notified=False).count() > 0
        else:
            show_notification = False
        return dict(show_notification=show_notification)

    from app.routes import main, users, trips, admin, cars, proxy
    app.register_blueprint(main.bp)
    app.register_blueprint(users.bp)
    app.register_blueprint(trips.bp)
    app.register_blueprint(admin.bp)
    app.register_blueprint(cars.bp)
    app.register_blueprint(proxy.bp)

    return app
