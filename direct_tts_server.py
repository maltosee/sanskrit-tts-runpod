from runpod_tts_handler import handler, HANDLER_VERSION, test_handler
import json
from http.server import HTTPServer, BaseHTTPRequestHandler

import argparse

# Add argument parsing
parser = argparse.ArgumentParser(description='TTS Server')
parser.add_argument('--port', type=int, default=8888, help='Port to run server on')
args = parser.parse_args()

class TTSHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path == "/generate":
            try:
                content_length = int(self.headers['Content-Length'])
                post_data = self.rfile.read(content_length)
                event = json.loads(post_data.decode('utf-8'))

                result = handler(event)

                self.send_response(200)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps(result).encode())

            except Exception as e:
                self.send_response(500)
                self.send_header('Content-type', 'application/json')
                self.end_headers()
                error_response = {"error": str(e)}
                self.wfile.write(json.dumps(error_response).encode())

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header('Content-type', 'application/json')
            self.end_headers()
            response = {
                "status": "healthy",
                "service": "tts",
                "version": HANDLER_VERSION,
                "endpoint": "/generate"
            }
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == "__main__":
    print(f"🚀 Starting Direct TTS Server {HANDLER_VERSION}")

    # Warmup test
    print("🔥 Running warmup test...")
    test_handler()

    server = HTTPServer(("0.0.0.0", args.port), TTSHandler)
    print(f"🌐 Starting TTS server on port {args.port}")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("✋ KeyboardInterrupt received, shutting down server...")
    finally:
        server.server_close()
        print("🛑 Server closed.")
