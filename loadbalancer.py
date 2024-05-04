import os
import time
import docker
import requests
import subprocess
from flask import Flask, request
import threading

app = Flask(__name__)
# Separate locks for adding and removing servers
add_lock = threading.Lock()
remove_lock = threading.Lock()
backend_servers = []
current_server_index = 0
last_used_port = 5000

os.system('docker build -t flask_app .')

def get_backend_server():
    global current_server_index
    current_server = backend_servers[current_server_index]
    current_server_index = (current_server_index + 1) % len(backend_servers)
    return current_server

def container_exists(container_name):
    output = os.popen(f'sudo docker ps -a --filter "name={container_name}" --format "{{.Names}}"').read().strip()
    return container_name in output.split("\n")

def add_backend_server():
    global last_used_port, backend_servers
    while True:
        with add_lock:
            if all(server["queued_requests"] >= 1 for server in backend_servers) or len(backend_servers) <= 3:
                new_port = last_used_port + 1
                last_used_port = new_port
                container_name = f"flask{len(backend_servers) + 7}"
                try:
                    os.system(f'sudo docker run -p {new_port}:4900 -d --name {container_name} flask_app')
                    new_server = {"url": f"http://localhost:{new_port}", "container": container_name, "queued_requests": 0, "last_active": time.time()}
                    backend_servers.append(new_server)
                except Exception as e:
                        print(f"Error adding backend server: {str(e)}")
        time.sleep(1)

def remove_inactive_servers():
    while True:
        if(len(backend_servers) > 4):
            with remove_lock:
                current_time = time.time()
                servers_to_remove = [server for server in backend_servers if current_time - server["last_active"] > 60]  
                for server in servers_to_remove:
        
                    try:
                        os.system(f"sudo docker stop {server['container']}")
                        os.system(f"sudo docker rm {server['container']}")
                    except Exception as e:
                        print(f"Error removing server: {str(e)}")
            time.sleep(1)

@app.route('/')
def index():
    backend_server = get_backend_server()
    backend_server["queued_requests"] += 1
    
    try:
        response = requests.get(backend_server["url"])
        backend_server["queued_requests"] -= 1
        backend_server["last_active"] = time.time()
        return response.content, response.status_code
    except requests.exceptions.RequestException as e:
        return f"Error occurred while processing the request: {str(e)}", 500

if __name__ == '__main__':
    threading.Thread(target=add_backend_server, daemon=True).start()
    threading.Thread(target=remove_inactive_servers, daemon=True).start()
    app.run(debug=True, host='0.0.0.0', port=4900)
