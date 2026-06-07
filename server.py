from flask import Flask, redirect, render_template, request, send_file, session

import json
app = Flask(__name__)

@app.route("/api/metrics", methods=['POST'])
def api_feedback():
    print(f"Method: {request.method}, Path: {request.path}")
    return "", 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=3000, debug=True, threaded=False)
