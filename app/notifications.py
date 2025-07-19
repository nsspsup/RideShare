from flask import flash
from flask_login import current_user
from app.models import JoinRequest, Trip
from app import db

def notify_driver():
    if not current_user.is_authenticated:
        return

    unnotified_requests = JoinRequest.query.join(Trip).filter(
        Trip.driver_id == current_user.id,
        JoinRequest.status == 'pending',
        JoinRequest.notified == False
    ).all()

    if unnotified_requests:
        flash(f"You have {len(unnotified_requests)} new trip join request(s).", "info")
        for req in unnotified_requests:
            req.notified = True
        db.session.commit()

def notify_user():
    if not current_user.is_authenticated:
        return

    responses = JoinRequest.query.filter_by(passenger_id=current_user.id, notified=False).filter(
        JoinRequest.status.in_(['accepted', 'denied'])
    ).all()

    for r in responses:
        flash(f"Your request for trip to {r.trip.end_location} was {r.status}.", "info")
        r.notified = True

    if responses:
        db.session.commit()
