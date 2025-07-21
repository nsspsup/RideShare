from flask import Blueprint
from flask import render_template, request, redirect, url_for, flash, abort, json , current_app
from flask_login import login_required, current_user
from app import db
from app.models import Trip, Car, JoinRequest
from app.utils.geo import haversine, geocode_address
import requests
import os
import config
from datetime import datetime
from sqlalchemy import not_


bp = Blueprint('trips', __name__, url_prefix='/trips')

# Dummy coordinates until geocoding is integrated
def fake_geocode(address):
    if 'bratislava' in address.lower():
        return (48.1486, 17.1077)
    elif 'kosice' in address.lower():
        return (48.7164, 21.2611)
    elif 'trnava' in address.lower():
        return (48.3774, 17.5888)
    return (48.15, 17.11)  # fallback: Bratislava


@bp.route('/plan', methods=['GET', 'POST'])
@login_required
def plan_trip():
    if request.method == 'POST':
        if not current_user.cars:
            flash("Add a car first.", "warning")
            return redirect(url_for('cars.manage_cars'))

        start = request.form['start_location']
        end = request.form['end_location']
        dep_time = datetime.strptime(request.form['departure_time'], "%Y-%m-%dT%H:%M")

        s_lat, s_lng = geocode_address(start)
        e_lat, e_lng = geocode_address(end)

        route_geo = None
        if request.form.get('route_geometry'):
            route_geo = json.loads(request.form['route_geometry'])

        try:
            route_distance_km = float(request.form.get('route_distance_km', 0))
            cost_total = float(request.form.get('cost_total', 0))
            cost_per_person = cost_total / 2 if cost_total is not None else None
        except ValueError:
            route_distance_km = cost_total = None


        trip = Trip(
            driver_id=current_user.id,
            start_location=start, end_location=end,
            start_lat=s_lat, start_lng=s_lng,
            end_lat=e_lat, end_lng=e_lng,
            route_geometry=route_geo,
            departure_time=dep_time,
            car_id=current_user.cars[0].id,
            route_distance_km=route_distance_km,
            cost_total=cost_total,
            cost_per_person=cost_per_person
        )

        db.session.add(trip)
        db.session.commit()
        flash("Trip created!")
        return redirect(url_for('trips.view_trip', trip_id=trip.id))

    return render_template('trip_plan.html', cars=current_user.cars)


@bp.route('/search', methods=['GET'])
def search_trip():
    show_all = request.args.get('show_all') == 'true'
    results = []

    if show_all:
        # exclude trips with an accepted passenger
        results = Trip.query.filter(
            ~Trip.join_request.any(JoinRequest.status == 'accepted')
        ).all()
    else:
        # geocode and filter by radius
        start = request.args.get('start_location', '').strip()
        end = request.args.get('end_location', '').strip()
        radius = float(request.args.get('radius', 20))
        if start and end:
            s_lat, s_lng = geocode_address(start)
            e_lat, e_lng = geocode_address(end)
            if s_lat and e_lat:
                query = Trip.query.filter(
                    ~Trip.join_requests.any(JoinRequest.status == 'accepted')
                )
                for trip in query.all():
                    d1 = haversine(s_lat, s_lng, trip.start_lat, trip.start_lng)
                    d2 = haversine(e_lat, e_lng, trip.end_lat, trip.end_lng)
                    if d1 <= radius and d2 <= radius:
                        results.append(trip)
            else:
                flash("Could not geocode inputs.", "danger")

    return render_template('trip_search.html', results=results, show_all=show_all)



@bp.route('/delete/<int:trip_id>', methods=['POST'])
@login_required
def delete_trip(trip_id):
    trip = Trip.query.get_or_404(trip_id)
    if trip.driver_id != current_user.id:
        abort(403)
    db.session.delete(trip); db.session.commit()
    flash("Deleted trip.")
    return redirect(url_for('trips.plan_trip'))


@bp.route('/join/<int:trip_id>', methods=['POST'])
@login_required
def join_trip(trip_id):
    trip = Trip.query.get_or_404(trip_id)
    if JoinRequest.query.filter_by(trip_id=trip.id, passenger_id=current_user.id).first():
        flash("Already requested.", "warning")
    else:
        jr = JoinRequest(trip_id=trip.id, passenger_id=current_user.id)
        db.session.add(jr); db.session.commit()
        flash("Requested to join.", "success")
    return redirect(url_for('trips.view_trip', trip_id=trip_id))



@bp.route('/trips/<int:trip_id>')
@login_required
def view_trip(trip_id):
    trip = Trip.query.get_or_404(trip_id)
    geo = trip.route_geometry
    if isinstance(geo, str):
        geo = json.loads(geo)
    return render_template('trip_detail.html', trip=trip, route_geojson=geo)

@bp.route('/approve_request/<int:req_id>', methods=['POST'])
@login_required
def approve_request(req_id):
    jr = JoinRequest.query.get_or_404(req_id)
    if jr.trip.driver_id != current_user.id:
        abort(403)

    if request.form['action'] == 'accept':
        jr.status = 'accepted'
    elif request.form['action'] == 'deny':
        jr.status = 'rejected'
    else:
        abort(400)

    # 🔁 Recalculate per-person cost properly
    jr.trip.update_cost_per_person()
    db.session.commit()
    flash("Request processed.", "success")
    return redirect(url_for('users.my_trips'))

@bp.route('/withdraw_request/<int:req_id>', methods=['POST'])
@login_required
def withdraw_request(req_id):
    jr = JoinRequest.query.get_or_404(req_id)
    if jr.passenger_id != current_user.id:
        abort(403)

    trip = jr.trip
    db.session.delete(jr)
    #trip.update_cost_per_person()
    db.session.commit()
    flash("Withdrawn.", "info")
    return redirect(url_for('users.my_trips'))
