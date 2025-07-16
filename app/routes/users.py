from flask import Blueprint
from flask import render_template, request, redirect, url_for, flash
from flask_login import login_required, current_user
from app import db
from app.models import User

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

    return render_template('profile.html', user=current_user)