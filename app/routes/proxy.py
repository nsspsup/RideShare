# app/routes/proxy.py

from flask import Blueprint, request, jsonify
import requests, os

bp = Blueprint('proxy', __name__, url_prefix='/proxy')

@bp.route('/osrm')
def proxy_osrm():
    start = request.args.get('start')
    end = request.args.get('end')

    if not start or not end:
        return jsonify({'error': 'Missing start or end coordinates'}), 400

    osrm_base_url = os.getenv("OSRM_URL", "http://127.0.0.1:5001")
    url = f"{osrm_base_url}/route/v1/driving/{start};{end}?overview=full&geometries=geojson&alternatives=true"
    print("Using OSRM:", url)

    try:
        response = requests.get(url, timeout=10)
        response.raise_for_status()
        #print("OSRM raw response:", response.text)
        return jsonify(response.json())
    except requests.exceptions.RequestException as e:
        return jsonify({'error': 'Failed to fetch route data', 'details': str(e)}), 502
