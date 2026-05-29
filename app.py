from flask import Flask, send_from_directory, jsonify, Response
import os, mimetypes

app = Flask(__name__, static_folder='static')
MUSIC_DIR = os.path.join(os.path.dirname(__file__), 'music')

AUDIO_EXTS = {'.mp3', '.wav', '.flac', '.ogg', '.aac', '.m4a', '.opus', '.wma'}

@app.route('/')
def index():
    return send_from_directory('static', 'index.html')

@app.route('/api/tracks')
def list_tracks():
    if not os.path.exists(MUSIC_DIR):
        return jsonify([])
    files = []
    for f in sorted(os.listdir(MUSIC_DIR)):
        ext = os.path.splitext(f)[1].lower()
        if ext in AUDIO_EXTS:
            path = os.path.join(MUSIC_DIR, f)
            size = os.path.getsize(path)
            files.append({
                'name': os.path.splitext(f)[0],
                'ext': ext[1:].upper(),
                'file': f,
                'size': size
            })
    return jsonify(files)

@app.route('/music/<path:filename>')
def serve_music(filename):
    # Support HTTP Range requests for seeking
    filepath = os.path.join(MUSIC_DIR, filename)
    if not os.path.exists(filepath):
        return Response('Not found', status=404)

    file_size = os.path.getsize(filepath)
    mime = mimetypes.guess_type(filepath)[0] or 'audio/mpeg'

    from flask import request
    range_header = request.headers.get('Range')

    if range_header:
        byte1, byte2 = 0, None
        match = range_header.replace('bytes=', '').split('-')
        byte1 = int(match[0])
        if match[1]:
            byte2 = int(match[1])
        byte2 = byte2 if byte2 is not None else file_size - 1
        length = byte2 - byte1 + 1

        with open(filepath, 'rb') as f:
            f.seek(byte1)
            data = f.read(length)

        rv = Response(data, 206, mimetype=mime, direct_passthrough=True)
        rv.headers['Content-Range'] = f'bytes {byte1}-{byte2}/{file_size}'
        rv.headers['Accept-Ranges'] = 'bytes'
        rv.headers['Content-Length'] = length
        return rv

    return send_from_directory(MUSIC_DIR, filename)

if __name__ == '__main__':
    os.makedirs(MUSIC_DIR, exist_ok=True)
    print(f'Music dir: {MUSIC_DIR}')
    print(f'Place audio files in: {MUSIC_DIR}')
    app.run(host='0.0.0.0', port=5000, debug=False)
