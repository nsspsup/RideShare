from flask import Blueprint, render_template, redirect, url_for, flash
from flask_login import login_required
from app.models import User, Trip, Car
from app.utils.decorators import admin_required


bp = Blueprint('admin', __name__, url_prefix='/admin')

@bp.route('/dashboard')
@login_required
@admin_required
def dashboard():
    users = User.query.all()
    trips = Trip.query.all()
    cars = Car.query.all()
    return render_template('admin/dashboard.html', users=users, trips=trips, cars=cars)

@bp.route('/delete_user/<int:user_id>', methods=['POST'])
@login_required
@admin_required
def delete_user(user_id):
    user = User.query.get_or_404(user_id)
    db.session.delete(user)
    db.session.commit()
    flash(f"User {user.email} deleted.", "warning")
    return redirect(url_for('admin.dashboard'))

@bp.route('/delete_trip/<int:trip_id>', methods=['POST'])
@login_required
@admin_required
def delete_trip(trip_id):
    trip = Trip.query.get_or_404(trip_id)
    db.session.delete(trip)
    db.session.commit()
    flash("Trip deleted.", "warning")
    return redirect(url_for('admin.dashboard'))

@bp.route('/delete_car/<int:car_id>', methods=['POST'])
@login_required
@admin_required
def delete_car(car_id):
    car = Car.query.get_or_404(car_id)
    db.session.delete(car)
    db.session.commit()
    flash("Car deleted.", "warning")
    return redirect(url_for('admin.dashboard'))