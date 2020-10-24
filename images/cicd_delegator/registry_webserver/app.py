from flask import Flask
from flask import render_template

import json
from pathlib import Path

app = Flask(__name__)

@app.route('/')
def index():

    reg = json.loads(Path("/registry.json").read_text())

    return render_template('index.html', sites=reg['sites'])
