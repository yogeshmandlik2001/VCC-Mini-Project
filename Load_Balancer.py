from flask import Flask
from werkzeug.contrib.fixers import ProxyFix
import requests
import random

app = Flask(__name__)

# List of backend servers
backend_servers = [
    "http://localhost:5001",
    "http://localhost:5002",
    "http://localhost:5003"
]

# Function to randomly select a backend server
def get_backend_server():
    return random.choice(backend_servers)

# Route to handle incoming requests
@app.route('/')
def index():
    backend_server = get_backend_server()
    response = requests.get(backend_server)
    return response.text

# Main function to run the Flask application
if __name__ == '__main__':
    app.wsgi_app = ProxyFix(app.wsgi_app)
    app.run(debug=True)
