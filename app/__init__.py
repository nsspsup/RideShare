#app/__init__.py
from flask import Flask
from flask_login import LoginManager
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

    from app.models import User  # import *after* db init

    @login_manager.user_loader
    def load_user(user_id):
        return User.query.get(int(user_id))

    from app.routes import main, users, trips, admin, cars, proxy
    app.register_blueprint(main.bp)
    app.register_blueprint(users.bp)
    app.register_blueprint(trips.bp)
    app.register_blueprint(admin.bp)
    app.register_blueprint(cars.bp)
    app.register_blueprint(proxy.bp)

    return app
