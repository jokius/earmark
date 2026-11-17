#!/usr/bin/env python3
"""Smoke check of a running earmark-whisper-server, run from the Mac (python3 stdlib, say -o, afconvert).

    python3 server/smoke.py http://gpu-box.local:8178 [token-file]

The token file defaults to <earmark support dir>/remote-token. Test speech is synthesized into a file
with `say -o` (nothing is played). Prints PASS/FAIL per check; exit code 1 if anything failed.
"""
import hashlib
import hmac
import http.client
import json
import os
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

COMMIT = "927cfce34f31707e17f2bff35c349632fb9e2c3a"
MODEL_SHA = "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
VAD_SHA = "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"
SAMPLE_RATE = 16000
TEXT = ("Hello, this is a smoke test of the earmark whisper server. "
        "The quick brown fox jumps over the lazy dog. Every recording stays on my own machines.")

results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + (": " + detail if detail else ""), flush=True)


def speech():
    """TTS of TEXT as raw float32 little-endian mono 16 kHz, like ChannelExtractor's samples."""
    with tempfile.TemporaryDirectory() as tmp:
        aiff, wav = os.path.join(tmp, "s.aiff"), os.path.join(tmp, "s.wav")
        subprocess.run(["say", "-o", aiff, TEXT], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32@%d" % SAMPLE_RATE, "-c", "1", aiff, wav], check=True)
        data = open(wav, "rb").read()
    i = 12
    while data[i:i + 4] != b"data":
        size = struct.unpack("<I", data[i + 4:i + 8])[0]
        i += 8 + size + (size & 1)
    size = struct.unpack("<I", data[i + 4:i + 8])[0]
    return data[i + 8:i + 8 + size]


def seconds(pcm):
    return len(pcm) / 4 / SAMPLE_RATE


class Server:
    def __init__(self, url, token):
        parts = urllib.parse.urlsplit(url)
        self.host, self.port, self.token = parts.hostname, parts.port or 80, token

    def open(self, method, path, body=b"", token=True, timeout=120):
        conn = http.client.HTTPConnection(self.host, self.port, timeout=timeout)
        headers = {"Content-Type": "application/octet-stream"}
        if token:
            headers["Authorization"] = "Bearer " + (self.token if token is True else token)
        conn.request(method, path, body=body if method == "POST" else None, headers=headers)
        conn.raw_sock = conn.sock  # the server closes every connection, so getresponse() hands the socket to resp
        return conn, conn.getresponse()

    def call(self, method, path, body=b"", token=True):
        conn, resp = self.open(method, path, body, token)
        data = resp.read()
        conn.close()
        try:
            return resp.status, json.loads(data)
        except ValueError:
            return resp.status, data

    def stream(self, path, body, on_line=None):
        """/v1/full: returns (status, lines, arrival times); on_line(i, line) may return False to hang up."""
        conn, resp = self.open("POST", path, body, timeout=30)
        lines, times = [], []
        try:
            if resp.status != 200:
                return resp.status, [json.loads(resp.read())], [time.monotonic()]
            while True:
                raw = resp.readline()
                if not raw:
                    break
                lines.append(json.loads(raw))
                times.append(time.monotonic())
                if on_line and on_line(len(lines) - 1, lines[-1]) is False:
                    conn.raw_sock.shutdown(socket.SHUT_RDWR)
                    break
        finally:
            resp.close()
            conn.close()
        return resp.status, lines, times


def max_gap(times):
    """Longest silence between consecutive NDJSON lines (the upload before the first line is excluded)."""
    return max([b - a for a, b in zip(times, times[1:])] or [0])


def full_ok(lines):
    return (len(lines) >= 2 and all(set(l) == {"progress"} for l in lines[:-1])
            and set(lines[-1]) == {"segments"} and len(lines[-1]["segments"]) > 0)


def text_of(lines):
    return " ".join(s["text"] for s in lines[-1].get("segments", []))


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    support = os.environ.get("EARMARK_HOME") or os.path.expanduser("~/Library/Application Support/earmark")
    token_file = sys.argv[2] if len(sys.argv) > 2 else os.path.join(support, "remote-token")
    token = open(token_file).readline().strip()
    srv = Server(sys.argv[1], token)

    clip = speech()
    silence = b"\0" * 4 * SAMPLE_RATE
    long_pcm = (clip + silence) * max(1, int(600 / seconds(clip + silence)))  # ~10 minutes
    print("clip %.1fs, long %.0fs" % (seconds(clip), seconds(long_pcm)), flush=True)

    # health: no token sent; proof = HMAC-SHA256(token, nonce exactly as sent), any header ignored
    def proof_ok(health, nonce):
        want = hmac.new(token.encode(), nonce.encode(), hashlib.sha256).hexdigest()
        return isinstance(health, dict) and hmac.compare_digest(health.get("proof", ""), want)

    nonce = secrets.token_hex(32)
    status, health = srv.call("GET", "/v1/health?nonce=" + nonce, token=False)
    check("health", status == 200 and health.get("commit") == COMMIT and health.get("model_sha256") == MODEL_SHA
          and health.get("vad_sha256") == VAD_SHA and bool(health.get("gpu")) and proof_ok(health, nonce),
          json.dumps(health))
    nonce = secrets.token_hex(32).upper()
    status, health = srv.call("GET", "/v1/health?nonce=" + nonce, token="0" * 64)
    check("health: upper-case nonce, wrong token header ignored", status == 200 and proof_ok(health, nonce),
          "%s %s" % (status, health))
    for query in ("", "?nonce=" + "a" * 63, "?nonce=" + "g" * 64):
        status, body = srv.call("GET", "/v1/health" + query, token=False)
        check("400 GET /v1/health" + query[:12], status == 400
              and body == {"error": "nonce must be 64 hex characters"}, "%s %s" % (status, body))
    # only a body-less GET /v1/health skips auth: with a body it needs the token like everything else
    conn = http.client.HTTPConnection(srv.host, srv.port, timeout=10)
    conn.request("GET", "/v1/health?nonce=" + secrets.token_hex(32), body=b"abcd")
    status = conn.getresponse().status
    conn.close()
    check("401 GET /v1/health with a body", status == 401, str(status))

    # auth
    status, body = srv.call("POST", "/v1/vad?threads=4", clip[:1024], token=False)
    check("401 without token", status == 401 and body == {"error": "unauthorized"}, "%s %s" % (status, body))
    # 1 KB body: the server answers 401 before reading the body and closes; a body still unread by then turns the
    # close into a TCP reset that can beat the 401 to this client (which reads only after it has sent everything).
    status, body = srv.call("POST", "/v1/full?language=en&threads=4", clip[:1024], token="0" * 64)
    check("401 wrong token", status == 401 and body == {"error": "unauthorized"}, "%s %s" % (status, body))

    # validation
    bad = [("POST", "/v1/vad?threads=0", clip, 400), ("POST", "/v1/vad", clip, 400),
           ("POST", "/v1/language?threads=4", b"\0\0\0", 400),
           ("POST", "/v1/full?language=xx&threads=4", clip, 400), ("GET", "/v1/nope", b"", 404)]
    for method, path, body, want in bad:
        status, reply = srv.call(method, path, body)
        check("%d %s %s" % (want, method, path), status == want and isinstance(reply, dict) and "error" in reply,
              "%s %s" % (status, reply))

    # vad
    t = time.monotonic()
    status, body = srv.call("POST", "/v1/vad?threads=4", clip)
    spans = body.get("spans", []) if status == 200 else []
    check("vad", status == 200 and len(spans) > 0
          and all(0 <= a < b <= seconds(clip) * 100 + 100 for a, b in spans),
          "%d spans in %.2fs, first %s" % (len(spans), time.monotonic() - t, spans[:1]))

    # language
    status, body = srv.call("POST", "/v1/language?threads=4", clip[:30 * SAMPLE_RATE * 4])
    probs = body.get("probs", {}) if status == 200 else {}
    top = max(probs, key=probs.get) if probs else None
    check("language", status == 200 and len(probs) >= 99 and top == "en",
          "%d languages, top %s=%.3f" % (len(probs), top, probs.get(top, 0)))
    status, body = srv.call("POST", "/v1/language?threads=4", b"")
    check("language empty body", status == 200 and body == {"probs": {}}, "%s %s" % (status, body))

    # full: short clip, fixed language and auto
    for lang in ("en", "auto"):
        t = time.monotonic()
        status, lines, times = srv.stream("/v1/full?language=%s&threads=4" % lang, clip)
        check("full language=%s" % lang, status == 200 and full_ok(lines) and "fox" in text_of(lines).lower(),
              "%d lines in %.2fs: %r" % (len(lines), time.monotonic() - t, text_of(lines)[:80]))

    # full: ten minutes, heartbeat gaps and timing
    t = time.monotonic()
    status, lines, times = srv.stream("/v1/full?language=en&threads=4", long_pcm)
    took = time.monotonic() - t
    check("full long: streamed progress + segments, heartbeat <= 2 s", status == 200 and full_ok(lines)
          and max_gap(times) <= 2.5,
          "%.0fs audio in %.1fs (first line after %.1fs upload), %d lines, max gap %.2fs, %d segments"
          % (seconds(long_pcm), took, times[0] - t if times else -1, len(lines), max_gap(times),
             len(lines[-1].get("segments", []))))

    # abort: A (long) holds the GPU, B waits behind it with heartbeats; A hangs up -> B must finish quickly.
    a_started, hang_up_at = threading.Event(), [None]

    def on_a_line(i, line):
        if i == 0:
            a_started.set()
        if i >= 3:  # whisper_full is running (or in its internal VAD) by now
            hang_up_at[0] = time.monotonic()
            return False

    b = {}

    def run_b():
        a_started.wait(60)
        time.sleep(0.5)
        b["start"] = time.monotonic()
        b["status"], b["lines"], b["times"] = srv.stream("/v1/full?language=en&threads=4", clip)
        b["end"] = time.monotonic()

    tb = threading.Thread(target=run_b)
    tb.start()
    srv.stream("/v1/full?language=en&threads=4", long_pcm, on_a_line)
    tb.join(120)
    ok = hang_up_at[0] is not None and b.get("status") == 200 and full_ok(b.get("lines", []))
    after = b["end"] - hang_up_at[0] if ok else -1
    check("client disconnect aborts whisper_full (waiting request gets the GPU)",
          ok and after < 2 and max_gap(b["times"]) <= 2.5,
          "B finished %.2fs after A hung up (A alone takes ~%.0fs), B: %d lines, max gap %.2fs"
          % (after, took, len(b.get("lines", [])), max_gap(b.get("times", []))))

    print("smoke: %d/%d passed" % (sum(results), len(results)))
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
