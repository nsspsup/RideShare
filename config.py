import os

class Config:
    SECRET_KEY = os.getenv('SECRET_KEY')
    SQLALCHEMY_DATABASE_URI = os.getenv('DATABASE_URL')
    SQLALCHEMY_TRACK_MODIFICATIONS = False
    FUEL_PRICE_PER_LITER = float(os.getenv('FUEL_PRICE_PER_LITER', 1.50))
