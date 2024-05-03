import os
import time
import docker
from flask import Flask, request
import requests

app = Flask(__name__)

# Initial list of backend servers
backend_servers = []
current_server_index = 0
last_used_port = 5000

os.system('docker build -t flask_app .')

# Function to select a backend server using round-robin scheduling
def get_backend_server():
    global current_server_index
    current_server = backend_servers[current_server_index]
    current_server_index = (current_server_index + 1) % len(backend_servers)
    return current_server

def add_backend_server():
    global backend_servers, last_used_port
    new_port = last_used_port + 1
    os.system(f'docker run -p {new_port}:4900 -d --name flask{len(backend_servers) + 1} flask_app')
    container_name = f"flask{len(backend_servers) + 1}"
    new_server = {"url": f"http://localhost:{new_port}", "container": container_name,"queued_requests": 0, "last_active": time.time()}
    backend_servers.append(new_server)
    last_used_port = new_port


# Function to remove additionally added servers if no request is sent to the server for a significant amount of time and it's unhealthy
def remove_inactive_servers():
    global backend_servers
    current_time = time.time()
    for server in backend_servers[:]:
        if current_time - server["last_active"] > 300:  # 300 seconds = 5 minutes
            os.system(f"docker stop {server['container']}")
            os.system(f"docker rm {server['container']}")
            backend_servers.remove(server)


# Route to handle incoming requests
@app.route('/')
def index():
    remove_inactive_servers()
    
    if all(server["queued_requests"] >= 1 for server in backend_servers):
        add_backend_server()
        
    backend_server = get_backend_server()
    backend_server["queued_requests"] += 1
    
    try:
        response = requests.get(backend_server["url"])
        backend_server["queued_requests"] -= 1
        backend_server["last_active"] = time.time()
        return response.content, response.status_code
    except requests.exceptions.RequestException as e:
        return f"Error occurred while processing the request: {str(e)}", 500



# Add a backend server at the start
add_backend_server() 
# Main function to run the Flask application
if __name__ == '__main__':
    # Run the Flask load balancer
    app.run(debug=True, host='0.0.0.0', port=4900)
