"""Local smoke tests for the TONY TRAN Bridge API (no third-party packages)."""
import importlib.util
import json
import threading
import urllib.request
import urllib.error
from http.server import ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("tony_bridge", HERE / "bridge.py")
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
bridge.TOKEN = "T" * 40
server = ThreadingHTTPServer(("127.0.0.1", 0), bridge.Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
base = f"http://127.0.0.1:{server.server_port}"

def request(path, method="GET", payload=None, token=bridge.TOKEN):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(base + path, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=2) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())

try:
    assert request("/api/status", token="wrong")[0] == 401
    code, queued = request("/api/command", "POST", {"type": "EA_DISABLE"})
    assert code == 202 and queued["ok"]
    code, cmd = request("/api/commands/next")
    assert code == 200 and cmd["type"] == "EA_DISABLE"
    cid = cmd["id"]
    assert request("/api/commands/ack/" + cid, "POST", {"status": "ACK"})[0] == 200
    assert request("/api/command", "POST", {"type": "MOVE_STOP", "step_pips": 0})[0] == 400
    assert request("/api/command", "POST", {"type": "EA_ENABLE"})[0] == 202
    heartbeat = {"symbol": "XAUUSD", "balance": 1000, "equity": 1000,
                 "open_positions": 0, "floating_profit": 0, "trading_enabled": True}
    assert request("/api/ea/heartbeat", "POST", heartbeat)[0] == 200
    state = request("/api/status")[1]
    assert state["ea_connected"] is True and state["trading_enabled"] is True
    print("PASS: auth, command queue, ACK, input validation, heartbeat/status")
finally:
    server.shutdown()
    server.server_close()
