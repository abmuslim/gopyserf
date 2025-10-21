from flask import Flask, jsonify
import socket
import random

app = Flask(__name__)

def get_ip():
    try:
        hostname = socket.gethostname()
        return socket.gethostbyname(hostname)
    except Exception:
        return "127.0.0.1"

def random_resource():
    """Generate random demand, score, and budget values"""
    return {
        "demand_per_unit": round(random.uniform(1, 10), 2),
        "score": round(random.uniform(0.5, 1.5), 2),
        "budget": round(random.uniform(1.0, 3.0), 2)
    }

@app.route("/", methods=["GET"])
def buyer_info():
    data = {
        "ip": get_ip(),
        "resources": {
            "storage": random_resource(),
            "vcpu": random_resource(),
            "ram": random_resource(),
            "vgpu": random_resource()
        }
    }
    return jsonify(data)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8090)

