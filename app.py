from flask import Flask
import socket

app = Flask(__name__)

@app.route('/')
def hello():
    container_id = socket.gethostname()
    return f"Hello from Flask!! (This is my Container ID: {container_id}!! ) BYE BYE!!"

if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=4001)
