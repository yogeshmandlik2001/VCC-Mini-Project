from flask import Flask
import socket

app = Flask(__name__)

@app.route('/')
def hello():
    container_id = socket.gethostname()
    return f"Hello from Flask! (Container ID: {container_id})"

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=4001)
