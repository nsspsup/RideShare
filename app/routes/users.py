from flask import Blueprint, render_template, request, redirect, url_for, flash
from flask_login import login_required, current_user, logout_user
from werkzeug.security import check_password_hash, generate_password_hash
from app import db
from app.models import User, JoinRequest, Trip

bp = Blueprint('users', __name__, url_prefix='/users')

@bp.route('/profile', methods=['GET', 'POST'])
@login_required
def profile():
    if request.method == 'POST':
        current_user.car_type = request.form.get('car_type')
        current_user.car_model = request.form.get('car_model')
        current_user.year_of_make = request.form.get('year_of_make')
        current_user.seats = request.form.get('seats')
        current_user.fuel_type = request.form.get('fuel_type')
        current_user.avg_consumption = request.form.get('avg_consumption')
        db.session.commit()
        flash("Profile updated successfully!")
        return redirect(url_for('users.profile'))

    notifications = JoinRequest.query.filter_by(passenger_id=current_user.id, notified=False).all()
    for req in notifications:
        req.notified = True
    db.session.commit()

    return render_template('profile.html', user=current_user, notifications=notifications)

@bp.route('/change-password', methods=['POST'])
@login_required
def change_password():
    current_password = request.form.get('current_password')
    new_password = request.form.get('new_password')

    if not (current_password and new_password):
        flash("All fields are required.", "danger")
        return redirect(url_for('users.profile'))

    if not check_password_hash(current_user.password_hash, current_password):
        flash("Current password is incorrect.", "danger")
        return redirect(url_for('users.profile'))

    current_user.password_hash = generate_password_hash(new_password)
    db.session.commit()
    flash("Password updated successfully.", "success")
    return redirect(url_for('users.profile'))


@bp.route('/delete', methods=['POST'])
@login_required
def delete_profile():
    user_id = current_user.id
    logout_user()  # Important: log the user out first
    user = User.query.get_or_404(user_id)

    db.session.delete(user)
    db.session.commit()

    flash("Your profile has been deleted.", "warning")
    return redirect(url_for('main.index'))

@bp.route('/my-trips')
@login_required
def my_trips():
    created_trips = current_user.trips
    joined_requests = current_user.join_requests
    joined_trips = [req.trip for req in joined_requests if req.status == 'accepted']
    pending_requests = [req for req in joined_requests if req.status == 'pending']

    # New: Get join requests on trips the current user created (driver)
    driver_pending_requests = JoinRequest.query.join(Trip).filter(
        Trip.driver_id == current_user.id,
        JoinRequest.status == 'pending'
    ).all()

    return render_template('my_trips.html',
                           created_trips=created_trips,
                           joined_trips=joined_trips,
                           pending_requests=pending_requests,
                           driver_pending_requests=driver_pending_requests)
