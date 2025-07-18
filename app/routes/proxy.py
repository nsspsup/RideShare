# app/routes/proxy.py

from flask import Blueprint, request, jsonify
import requests

bp = Blueprint('proxy', __name__, url_prefix='/proxy')

@bp.route('/osrm')
def proxy_osrm():
    start = request.args.get('start')
    end = request.args.get('end')

    if not start or not end:
        return jsonify({'error': 'Missing start or end coordinates'}), 400

    url = f"http://158.220.118.95:5001/route/v1/driving/{start};{end}?overview=full&geometries=geojson&alternatives=true"
    print("Using OSRM:", url)

    try:
        response = requests.get(url, timeout=10)
        response.raise_for_status()
        #print("OSRM raw response:", response.text)
        return jsonify(response.json())
    except requests.exceptions.RequestException as e:
        return jsonify({'error': 'Failed to fetch route data', 'details': str(e)}), 502
