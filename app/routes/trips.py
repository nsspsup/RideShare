from flask import Blueprint
from flask import render_template, request, redirect, url_for, flash
from flask_login import login_required, current_user
from app import db
from app.models import Trip
from app.utils.geo import haversine, geocode_address
import requests
from datetime import datetime


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
        start = request.form.get('start_location')
        end = request.form.get('end_location')
        seats = request.form.get('available_seats')
        cost_split = request.form.get('cost_split')
        allow_dev = request.form.get('allow_deviation') == 'yes'
        max_deviation_km = request.form.get('max_deviation_km')
        dep_time_str = request.form.get('departure_time')
        departure_time = datetime.strptime(dep_time_str, "%Y-%m-%dT%H:%M") if dep_time_str else None

        # Geocode start and end to get lat/lng
        from app.utils.geo import geocode_address
        start_lat, start_lng = geocode_address(start)
        end_lat, end_lng = geocode_address(end)

        # Fetch route geometry from OSRM
        osrm_url = f"https://router.project-osrm.org/route/v1/driving/{start_lng},{start_lat};{end_lng},{end_lat}?overview=full&geometries=geojson"
        route_geometry = None
        try:
            res = requests.get(osrm_url)
            if res.status_code == 200:
                data = res.json()
                if data["routes"]:
                    route_geometry = data["routes"][0]["geometry"]
        except Exception as e:
            print("Failed to fetch route from OSRM:", e)

        # Create trip
        new_trip = Trip(
            driver_id=current_user.id,
            start_location=start,
            end_location=end,
            start_lat=start_lat,
            start_lng=start_lng,
            end_lat=end_lat,
            end_lng=end_lng,
            available_seats=seats,
            cost_split=cost_split,
            max_deviation_km = float(max_deviation_km) if max_deviation_km else None,
            route_geometry=route_geometry,
            departure_time=departure_time,
        )

        db.session.add(new_trip)
        db.session.commit()
        flash("Trip created successfully.")
        return redirect(url_for('trips.plan_trip'))

    return render_template('trip_plan.html')


@bp.route('/search', methods=['GET', 'POST'])
def search_trip():
    results = []

    if request.method == 'POST':
        start_query = request.form.get('start_location')
        end_query = request.form.get('end_location')
        max_km = float(request.form.get('radius') or 20)  # default to 20 km

        # Simulated geocode lookup
        user_start_lat, user_start_lng = geocode_address(start_query)
        user_end_lat, user_end_lng = geocode_address(end_query)

        if not user_start_lat or not user_end_lat:
            flash("Could not geocode your search locations.")
            return render_template('trip_search.html', results=[])

        for trip in Trip.query.all():
            if trip.start_lat is None or trip.end_lat is None:
                continue

            distance_start = haversine(user_start_lat, user_start_lng, trip.start_lat, trip.start_lng)
            distance_end = haversine(user_end_lat, user_end_lng, trip.end_lat, trip.end_lng)

            if distance_start <= max_km and distance_end <= max_km:
                results.append(trip)

        if not results:
            flash("No trips found. Try broadening your search.")

    return render_template('trip_search.html', results=results)