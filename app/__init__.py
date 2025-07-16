from flask import Flask
from flask_login import LoginManager
from dotenv import load_dotenv
from app.models import db, User  # db defined in models.py
from flask_migrate import Migrate

login_manager = LoginManager()
migrate = Migrate()

def create_app():
    load_dotenv()
    app = Flask(__name__)
    app.config.from_object('config.Config')

    db.init_app(app)
    migrate.init_app(app, db)

    login_manager.init_app(app)
    login_manager.login_view = 'main.login'  # redirect route for @login_required

    @login_manager.user_loader
    def load_user(user_id):
        return User.query.get(int(user_id))

    from .routes import main, users, trips
    app.register_blueprint(main.bp)
    app.register_blueprint(users.bp)
    app.register_blueprint(trips.bp)

    return app


