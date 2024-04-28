from flask import Flask, request
from werkzeug.middleware.proxy_fix import ProxyFix
import requests
import random

app = Flask(__name__)

# List of backend servers
backend_servers = [
    {"url": "http://localhost:5000", "container_id": "Container-1", "priority": 2},
    {"url": "http://localhost:5000", "container_id": "Container-2", "priority": 1},
    {"url": "http://localhost:5000", "container_id": "Container-3", "priority": 3}
]

# Function to select a backend server using round-robin scheduling
def get_backend_server_round_robin():
    global backend_servers
    server = backend_servers[0]
    backend_servers = backend_servers[1:] + [backend_servers[0]]
    return server

# Function to select a backend server using FCFS (First Come, First Served) scheduling
def get_backend_server_fcfs():
    return backend_servers[0]

# Function to select a backend server using priority-based scheduling
def get_backend_server_priority():
    return min(backend_servers, key=lambda x: x['priority'])

# Route to handle incoming requests
@app.route('/')
def index():
    backend_server = get_backend_server_round_robin()  # Change this line to use different scheduling methods
    response = requests.get(backend_server["url"])
    return f"Response from {backend_server['container_id']}: {response.text}"

# Main function to run the Flask application
if __name__ == '__main__':
    app.wsgi_app = ProxyFix(app.wsgi_app)
    app.run(debug=True, host='0.0.0.0', port=8080)


