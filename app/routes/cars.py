from flask import Blueprint, render_template, request, redirect, url_for, flash
from flask_login import login_required, current_user
from app import db
from app.models import Car

bp = Blueprint('cars', __name__, url_prefix='/cars')


@bp.route('/', methods=['GET', 'POST'])
@login_required
def manage_cars():
    if request.method == 'POST':
        # Match names used in the form exactly
        make = request.form.get('car_make')  # previously request.form.get('make')
        model = request.form.get('model')
        plate = request.form.get('plate')
        year_of_make = request.form.get('year_of_make')
        fuel_type = request.form.get('fuel_type')
        avg_consumption = request.form.get('avg_consumption')

        if not all([make, model, plate, year_of_make, fuel_type, avg_consumption]):
            flash("All fields are required.", "danger")
        else:
            new_car = Car(
                user_id=current_user.id,
                make=make,
                model=model,
                plate=plate,
                year_of_make=int(year_of_make),
                fuel_type=fuel_type,
                avg_consumption=float(avg_consumption)
            )
            db.session.add(new_car)
            db.session.commit()
            flash("Car added successfully.", "success")
            return redirect(url_for('cars.manage_cars'))

    cars = Car.query.filter_by(user_id=current_user.id).all()
    return render_template('manage_cars.html', cars=cars)

@bp.route('/edit/<int:car_id>', methods=['GET', 'POST'])
@login_required
def edit_car(car_id):
    car = Car.query.get_or_404(car_id)

    if car.user_id != current_user.id and not current_user.is_admin:
        flash("You do not have permission to edit this car.", "danger")
        return redirect(url_for('cars.manage_cars'))

    if request.method == 'POST':
        car.make = request.form.get('car_type')
        car.model = request.form.get('model')
        car.plate = request.form.get('plate')
        car.year_of_make = request.form.get('year_of_make')
        car.fuel_type = request.form.get('fuel_type')
        car.avg_consumption = request.form.get('avg_consumption')

        db.session.commit()
        flash("Car updated successfully.", "success")
        return redirect(url_for('cars.manage_cars'))

    return render_template('cars/edit_car.html', car=car)

@bp.route('/delete/<int:car_id>', methods=['POST'])
@login_required
def delete_car(car_id):
    car = Car.query.get_or_404(car_id)

    if car.user_id != current_user.id and not current_user.is_admin:
        flash("You do not have permission to delete this car.", "danger")
        return redirect(url_for('cars.manage_cars'))

    db.session.delete(car)
    db.session.commit()
    flash("Car deleted successfully.", "success")
    return redirect(url_for('cars.manage_cars'))