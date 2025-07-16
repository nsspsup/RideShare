from flask import Flask
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager
from dotenv import load_dotenv
import os

db = SQLAlchemy()
#login_manager = LoginManager()

def create_app():
    load_dotenv()
    app = Flask(__name__)
    app.config.from_object('config.Config')

    db.init_app(app)
    #login_manager.init_app(app)
    #login_manager.login_view = 'main.login'

    from .routes import main, users, trips
    app.register_blueprint(main.bp)
    app.register_blueprint(users.bp)
    app.register_blueprint(trips.bp)

    return app
