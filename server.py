from flask import Flask, redirect, render_template, request, send_file, session

import json
app = Flask(__name__)

@app.route("/api/metrics", methods=['POST'])
def api_feedback():
    # 1. Пытаемся прочитать JSON из тела запроса
    data = request.get_json(silent=True)

    print(f"Method: {request.method}, Path: {request.path}")

    # 2. Проверяем, пришел ли JSON, и выводим его
    if data:
        print(f"Получены данные (JSON): {json.dumps(data, indent=4, ensure_ascii=False)}")
    else:
        print("JSON не получен или пустой запрос")

    return "", 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000, debug=True, threaded=False)
