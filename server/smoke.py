#!/usr/bin/env python3
"""Smoke check of a running earmark-whisper-server (protocol v2), run from the Mac (python3 stdlib, say -o, afconvert).

    python3 server/smoke.py URL [--token-file F] [--ssh HOST --unit UNIT --jobs DIR]

The token file defaults to <earmark support dir>/remote-token. Test speech is synthesized into files with `say -o`
(nothing is played; the Russian clip needs the Milena voice). With --ssh the destructive checks run too: restart and
kill -9 of UNIT, job.json mtime and a channel file under DIR on the server. Point them at a dev unit only.
Prints PASS/FAIL per check; exit code 1 if anything failed.
"""
import argparse
import hashlib
import hmac
import http.client
import json
import os
import re
import secrets
import select
import shlex
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse

COMMIT = "927cfce34f31707e17f2bff35c349632fb9e2c3a"
VAD_SHA = "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"
MODEL_SHAS = {"ggml-large-v3-turbo.bin": "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"}
SAMPLE_RATE = 16000
MIB = 1 << 20
TEXT = ("Hello, this is a smoke test of the earmark whisper server. "
        "The quick brown fox jumps over the lazy dog. Every recording stays on my own machines.")
TEXT_RU = "Привет, это проверка сервера расшифровки. Сегодня мы обсуждаем план работ на следующую неделю."
CRASHED = "server crashed on this job twice"
TERMINAL = ("done", "failed")

results = []


def check(name, ok, detail=""):
    results.append(bool(ok))
    print(("PASS " if ok else "FAIL ") + name + (": " + detail if detail else ""), flush=True)


def speech(text, voice=None):
    """TTS as raw float32 little-endian mono 16 kHz, like ChannelExtractor's samples."""
    with tempfile.TemporaryDirectory() as tmp:
        aiff, wav = os.path.join(tmp, "s.aiff"), os.path.join(tmp, "s.wav")
        subprocess.run(["say"] + (["-v", voice] if voice else []) + ["-o", aiff, text], check=True)
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32@%d" % SAMPLE_RATE, "-c", "1", aiff, wav], check=True)
        data = open(wav, "rb").read()
    i = 12
    while data[i:i + 4] != b"data":
        size = struct.unpack("<I", data[i + 4:i + 8])[0]
        i += 8 + size + (size & 1)
    size = struct.unpack("<I", data[i + 4:i + 8])[0]
    return data[i + 8:i + 8 + size]


def silence(secs):
    return bytes(4 * int(SAMPLE_RATE * secs))


def samples(pcm):
    return len(pcm) // 4


class Server:
    def __init__(self, url, token):
        parts = urllib.parse.urlsplit(url)
        self.host, self.port, self.token = parts.hostname, parts.port or 80, token
        self.not_json = []  # replies that are not an ASCII JSON object with Content-Type: application/json

    def call(self, method, path, body=b"", token=True, timeout=120, zeros=0):
        """(status, JSON object). status None: the server did not answer. A non-object reply comes back as
        {"_raw": bytes}. zeros > 0 sends that many zero bytes as the body, headers first, so a server that
        rejects by Content-Length can answer before the body."""
        conn = http.client.HTTPConnection(self.host, self.port, timeout=timeout)
        headers = {"Authorization": "Bearer " + (self.token if token is True else token)} if token else {}
        try:
            try:
                if zeros:
                    conn.putrequest(method, path)
                    for k, v in headers.items():
                        conn.putheader(k, v)
                    conn.putheader("Content-Length", str(zeros))
                    conn.endheaders()
                    if not select.select([conn.sock], [], [], 2)[0]:
                        for i in range(0, zeros, MIB):
                            conn.send(bytes(min(MIB, zeros - i)))
                else:
                    conn.request(method, path, body=body or None, headers=headers)
            except (BrokenPipeError, ConnectionResetError):
                pass  # the server may answer and close before reading the whole body: read what it said
            resp = conn.getresponse()
            data = resp.read()
        except (OSError, http.client.HTTPException) as e:
            return None, {"_raw": repr(e)}
        finally:
            conn.close()
        try:
            reply = json.loads(data)
        except ValueError:
            reply = None
        if (not isinstance(reply, dict) or not data.isascii()
                or (resp.getheader("Content-Type") or "").split(";")[0].strip() != "application/json"):
            self.not_json.append("%s %s -> %s %s %r" % (method, path.split("?")[0], resp.status,
                                                        resp.getheader("Content-Type"), data[:60]))
        return resp.status, reply if isinstance(reply, dict) else {"_raw": data[:200]}


def put(srv, job, ch, offset, pcm=b"", extra="", token=True):
    return srv.call("PUT", "/v2/jobs/%s/channels/%s?offset=%s%s" % (job, ch, offset, extra), pcm, token)


def upload(srv, job, ch, pcm, extra=""):
    """PUT pcm into channel ch from offset 0 in client-sized chunks (<= 32 MiB); the last (status, reply)."""
    status, reply = None, {}
    for i in range(0, len(pcm), 32 * MIB) or [0]:
        status, reply = put(srv, job, ch, i // 4, pcm[i:i + 32 * MIB], extra if i == 0 else "")
        if status != 200:
            break
    return status, reply


def submit(srv, job, languages, lengths, token=True):
    body = json.dumps({"languages": languages, "lengths": lengths}).encode()
    return srv.call("POST", "/v2/jobs/%s/submit" % job, body, token)


def get(srv, job):
    return srv.call("GET", "/v2/jobs/" + job)


def wait(srv, job, states, timeout):
    """Poll GET until the state is in `states`; gives up on any reply but 200, keeps polling while the server is
    down. (status, job, progress values seen)."""
    deadline, seen = time.monotonic() + timeout, []
    while True:
        status, reply = get(srv, job)
        if status == 200:
            seen.append(reply.get("progress"))
        if (status == 200 and reply.get("state") in states) or status not in (200, None) \
                or time.monotonic() > deadline:
            return status, reply, seen
        time.sleep(0.3)


def err(reply, *extra):
    """The error shape: {"error": text} plus exactly the named extra fields."""
    return isinstance(reply.get("error"), str) and set(reply) == {"error", *extra}


def segs(job, ch):
    try:
        return job["channels"][ch]["segments"]
    except (KeyError, IndexError, TypeError):
        return None


def picked(job, ch, lang=None):
    return [s for s in segs(job, ch) or [] if isinstance(s, dict) and lang in (None, s.get("language"))]


def text(job, ch, lang=None):
    return " ".join(s["text"] for s in picked(job, ch, lang) if isinstance(s.get("text"), str))


def langs(job, ch):
    return {s.get("language") for s in picked(job, ch)}


def first_ms(job, ch, lang=None):
    return min([s["start_ms"] for s in picked(job, ch, lang) if isinstance(s.get("start_ms"), int)] or [-1])


def done_ok(job, health, lengths):
    """done with the contract's result fields; every segment well-formed, in order and inside its channel."""
    if not (job.get("state") == "done" and job.get("progress") == 100 and job.get("error", "") is None
            and job.get("lengths") == lengths and job.get("model") == health.get("model")
            and job.get("model_sha256") == health.get("model_sha256")
            and isinstance(job.get("channels"), list) and len(job["channels"]) == 2):
        return False
    for ch, n in enumerate(lengths):
        s = segs(job, ch)
        if not isinstance(s, list) or not all(
                isinstance(g, dict) and isinstance(g.get("start_ms"), int) and isinstance(g.get("end_ms"), int)
                and 0 <= g["start_ms"] <= g["end_ms"] <= n * 1000 // SAMPLE_RATE + 1000
                and isinstance(g.get("text"), str) and g["text"] == g["text"].strip()
                and isinstance(g.get("language"), str) for g in s):
            return False
        if [g["start_ms"] for g in s] != sorted(g["start_ms"] for g in s):
            return False
    return True


def brief(status, job):
    if status != 200:
        return "%s %s" % (status, job)
    return "state=%s progress=%s error=%r langs=%s/%s ch0=%r ch1=%r first_ms=%s/%s" % (
        job.get("state"), job.get("progress"), job.get("error"), sorted(map(str, langs(job, 0))),
        sorted(map(str, langs(job, 1))), text(job, 0)[:70], text(job, 1)[:70], first_ms(job, 0), first_ms(job, 1))


def progress_ok(seen):
    nums = [p for p in seen if isinstance(p, (int, float)) and 0 <= p <= 100]
    return bool(seen) and len(nums) == len(seen) and nums == sorted(nums)


def health(srv):
    """Checks GET /v2/health; returns its reply (model fields are compared with finished jobs)."""
    token = srv.token

    def proof_ok(reply, nonce):
        want = hmac.new(token.encode(), nonce.encode(), hashlib.sha256).hexdigest()
        return isinstance(reply.get("proof"), str) and hmac.compare_digest(reply["proof"], want)

    nonce = secrets.token_hex(32)
    status, h = srv.call("GET", "/v2/health?nonce=" + nonce, token=False)
    model, sha = h.get("model"), h.get("model_sha256")
    model_ok = (isinstance(model, str) and re.fullmatch(r"[^/]+\.bin", model) is not None
                and isinstance(sha, str) and re.fullmatch("[0-9a-f]{64}", sha) is not None
                and MODEL_SHAS.get(model, sha) == sha)
    check("health: whisper, commit, model file, sha256s, gpu, proof; no token needed", status == 200
          and {"whisper", "commit", "model", "model_sha256", "vad_sha256", "gpu", "proof"} <= set(h)
          and h["commit"] == COMMIT and h["vad_sha256"] == VAD_SHA and model_ok and bool(h["gpu"])
          and proof_ok(h, nonce), "%s %s" % (status, json.dumps(h)))
    nonce = secrets.token_hex(32).upper()
    status, reply = srv.call("GET", "/v2/health?nonce=" + nonce, token="0" * 64)
    check("health: proof over the upper-case nonce as sent, wrong token header ignored",
          status == 200 and proof_ok(reply, nonce), "%s %s" % (status, reply))
    for label, query in (("missing", ""), ("empty", "?nonce="), ("63 hex", "?nonce=" + "a" * 63),
                         ("65 hex", "?nonce=" + "a" * 65), ("64 non-hex", "?nonce=" + "g" * 64)):
        status, reply = srv.call("GET", "/v2/health" + query, token=False)
        check("400 health with nonce %s" % label, status == 400
              and reply == {"error": "nonce must be 64 hex characters"}, "%s %s" % (status, reply))
    status, reply = srv.call("GET", "/v2/health?nonce=" + secrets.token_hex(32), b"abcd", token=False)
    check("401 health with a request body", status == 401 and err(reply), "%s %s" % (status, reply))
    return h


def removed_v1(srv, pcm):
    for method, path in (("GET", "/v1/health?nonce=" + secrets.token_hex(32)), ("POST", "/v1/full?language=en&threads=4"),
                         ("POST", "/v1/vad?threads=4"), ("POST", "/v1/language?threads=4")):
        status, reply = srv.call(method, path, pcm[:64] if method == "POST" else b"")
        check("404 %s %s (v1 removed)" % (method, path.split("?")[0]), status == 404 and err(reply),
              "%s %s" % (status, reply))


def validation(srv, jid, pcm):
    rejected = jid("rejected")
    for bad in ("ABC", "a_b", "a.b", "..", "x" * 65):
        status, reply = put(srv, bad, 0, 0, pcm[:16])
        check("400 PUT with id %r" % (bad if len(bad) < 10 else "x*65"), status == 400 and err(reply),
              "%s %s" % (status, reply))
    for method, path in (("GET", "/v2/jobs/ABC"), ("DELETE", "/v2/jobs/ABC"), ("POST", "/v2/jobs/ABC/submit")):
        body = json.dumps({"languages": "en", "lengths": [0, 0]}).encode() if method == "POST" else b""
        status, reply = srv.call(method, path, body)
        check("400 %s with id 'ABC'" % method, status == 400 and err(reply), "%s %s" % (status, reply))
    for ch in ("2", "x"):
        status, reply = put(srv, rejected, ch, 0, pcm[:16])
        check("400 PUT channel %s" % ch, status == 400 and err(reply), "%s %s" % (status, reply))
    for query in ("", "?offset=", "?offset=-1", "?offset=x", "?offset=1.5"):
        status, reply = srv.call("PUT", "/v2/jobs/%s/channels/0%s" % (rejected, query), pcm[:16])
        check("400 PUT offset %r" % query, status == 400 and err(reply), "%s %s" % (status, reply))
    for size in (3, 5):
        status, reply = put(srv, rejected, 0, 0, pcm[:size])
        check("400 PUT body of %d bytes (not whole f32 samples)" % size, status == 400 and err(reply),
              "%s %s" % (status, reply))
    status, reply = srv.call("PUT", "/v2/jobs/%s/channels/0?offset=0" % rejected, zeros=64 * MIB + 4)
    check("413 PUT body of 64 MiB + 4 bytes", status == 413 and err(reply), "%s %s" % (status, reply))
    status, reply = get(srv, rejected)
    check("rejected PUTs (400, 413) create no job", status == 404 and err(reply), "%s %s" % (status, reply))
    longest = jid("m" * (64 - len(jid(""))))
    status, reply = srv.call("PUT", "/v2/jobs/%s/channels/0?offset=0" % longest, zeros=64 * MIB)
    check("PUT with a 64-char id and a 64 MiB body: 200", status == 200 and reply == {"lengths": [16 * MIB, 0]},
          "%s %s" % (status, reply))


def jobs(srv, h, en, ru, jid):
    """Upload, auth, submit and the result of short jobs; returns the id of a done job kept for the restart check."""
    # main: English after 5 s of silence in channel 0, three chunks; channel 1 stays empty
    main = jid("main")
    a = silence(5) + en
    n = samples(a)
    c1, c2 = n // 3, 2 * n // 3
    status, reply = put(srv, main, 0, 0, a[:c1 * 4])
    check("PUT offset=0 on a new id creates the job: 200 {lengths}", status == 200 and reply == {"lengths": [c1, 0]},
          "%s %s" % (status, reply))
    for label, off in (("0", 0), ("N-1", c1 - 1), ("N+1", c1 + 1)):
        status, reply = put(srv, main, 0, off, a[c1 * 4:c2 * 4])
        check("409 PUT offset=%s while the channel holds N samples: {error, state, lengths}" % label,
              status == 409 and err(reply, "state", "lengths") and reply["state"] == "receiving"
              and reply["lengths"] == [c1, 0], "%s %s" % (status, reply))
    s1, r1 = put(srv, main, 0, c1, a[c1 * 4:c2 * 4])
    s2, r2 = put(srv, main, 0, c2, a[c2 * 4:])
    check("PUT at the current length appends chunk by chunk (the 409s wrote nothing)",
          s1 == s2 == 200 and r1 == {"lengths": [c2, 0]} and r2 == {"lengths": [n, 0]}, "%s %s %s %s" % (s1, r1, s2, r2))
    status, reply = put(srv, main, 1, 0, b"", "&source=stream")
    check("PUT with an empty body: 200, nothing appended", status == 200 and reply == {"lengths": [n, 0]},
          "%s %s" % (status, reply))
    status, job = get(srv, main)
    check("GET receiving job: state, progress, lengths, languages null, source m4a (source= on a non-empty job "
          "ignored), error null", status == 200 and job.get("state") == "receiving" and job.get("lengths") == [n, 0]
          and job.get("languages", "") is None and job.get("source") == "m4a" and job.get("error", "") is None
          and isinstance(job.get("progress"), (int, float)) and 0 <= job["progress"] <= 100, "%s %s" % (status, job))

    # auth on an existing job: 401 and no effect
    for name, method, path, body in (
            ("PUT channel", "PUT", "/v2/jobs/%s/channels/0?offset=%d" % (main, n), en[:16]),
            ("POST submit", "POST", "/v2/jobs/%s/submit" % main, json.dumps({"languages": "en", "lengths": [n, 0]}).encode()),
            ("GET job", "GET", "/v2/jobs/" + main, b""), ("DELETE job", "DELETE", "/v2/jobs/" + main, b"")):
        for label, token in (("no token", False), ("a wrong token", "0" * 64)):
            status, reply = srv.call(method, path, body, token)
            check("401 %s with %s" % (name, label), status == 401 and err(reply), "%s %s" % (status, reply))
    for label, token in (("the token minus its last char", srv.token[:-1]), ("the token plus a char", srv.token + "0")):
        status, reply = srv.call("GET", "/v2/jobs/" + main, token=token)
        check("401 GET job with %s" % label, status == 401 and err(reply), "%s %s" % (status, reply))
    status, job = get(srv, main)
    check("unauthorized requests changed nothing", status == 200 and job.get("state") == "receiving"
          and job.get("lengths") == [n, 0], "%s %s" % (status, job))
    ghost = jid("ghost")
    s1, r1 = put(srv, ghost, 0, 0, en[:16], token=False)
    s2, r2 = get(srv, ghost)
    check("401 PUT without a token on a new id creates nothing (GET 404)", s1 == 401 and s2 == 404 and err(r2),
          "%s %s / %s %s" % (s1, r1, s2, r2))

    # submit validation on the receiving job
    for languages in ("xx", "ru,xx", "", "auto,en"):
        status, reply = submit(srv, main, languages, [n, 0])
        check("400 submit languages=%r" % languages, status == 400 and err(reply), "%s %s" % (status, reply))
    status, reply = submit(srv, main, "en", [n - 1, 0])
    check("409 submit with lengths the server does not have: {error, state, lengths, languages}",
          status == 409 and err(reply, "state", "lengths", "languages") and reply["state"] == "receiving"
          and reply["lengths"] == [n, 0] and reply["languages"] is None, "%s %s" % (status, reply))
    status, reply = submit(srv, jid("none"), "en", [0, 0])
    check("404 submit of an unknown job", status == 404 and err(reply), "%s %s" % (status, reply))

    # more jobs, queued behind main
    listed, auto, empty, mixed, outside = jid("list"), jid("auto"), jid("empty"), jid("mixed"), jid("outside")
    b = silence(3) + en
    half = samples(b) // 2 * 4
    s1, _ = put(srv, listed, 1, 0, b[:half], "&source=stream")
    s2, _ = put(srv, listed, 1, half // 4, b[half:], "&source=m4a")
    status, job = get(srv, listed)
    check("source=stream is set by the first PUT (offset 0, new job); a later source= is ignored",
          s1 == s2 == status == 200 and job.get("source") == "stream" and job.get("lengths") == [0, samples(b)],
          "%s %s %s" % (s1, s2, brief(status, job)))
    m = ru + silence(3) + en
    upload(srv, auto, 0, en)
    put(srv, empty, 0, 0)
    upload(srv, mixed, 0, m)
    upload(srv, outside, 0, en)
    plan = [(main, "en", [n, 0]), (listed, "ru,en", [0, samples(b)]), (auto, "auto", [samples(en), 0]),
            (empty, "en", [0, 0]), (mixed, "ru,en", [samples(m), 0]), (outside, "ru,de", [samples(en), 0])]
    submitted = {}
    for job_id, languages, lengths in plan:
        submitted[job_id] = submit(srv, job_id, languages, lengths)
    status, reply = submitted[main]
    check("submit with matching lengths: 200, queued, body like GET", status == 200
          and reply.get("state") in ("queued", "running") and reply.get("lengths") == [n, 0]
          and reply.get("languages") == "en" and reply.get("source") == "m4a" and reply.get("error", "") is None
          and "progress" in reply, "%s %s" % (status, reply))

    def finished(job_id, timeout=60):
        if submitted[job_id][0] != 200:
            return submitted[job_id][0], {"submit": submitted[job_id][1]}, []
        return wait(srv, job_id, TERMINAL, timeout)

    status, job, seen = finished(main, 120)
    check("en job done: model from health, TTS text in channel 0 from >= 4 s, language en, channel 1 empty",
          status == 200 and done_ok(job, h, [n, 0]) and "fox" in text(job, 0).lower() and langs(job, 0) == {"en"}
          and segs(job, 1) == [] and first_ms(job, 0) >= 4000, brief(status, job))
    check("progress stays within 0..100 and never goes down", progress_ok(seen), str(seen))
    done = job
    s1, r1 = submit(srv, main, "en", [n, 0])
    s2, again = get(srv, main)
    check("repeat submit on done: 200, job unchanged", s1 == s2 == 200 and again == done and done.get("state") == "done",
          "%s %s / %s" % (s1, r1, brief(s2, again)))
    for what, languages, lengths in (("languages", "ru", [n, 0]), ("lengths", "en", [n, 1])):
        status, reply = submit(srv, main, languages, lengths)
        check("409 submit on done with other %s: {error, state, lengths, languages}" % what,
              status == 409 and err(reply, "state", "lengths", "languages") and reply["state"] == "done"
              and reply["lengths"] == [n, 0] and reply["languages"] == "en", "%s %s" % (status, reply))
    status, reply = put(srv, main, 0, n, en[:16])
    check("409 PUT into a done job: {error, state, lengths}", status == 409 and err(reply, "state", "lengths")
          and reply["state"] == "done" and reply["lengths"] == [n, 0], "%s %s" % (status, reply))

    status, job, _ = finished(listed)
    check("languages ru,en on English speech in channel 1 after 3 s: language en, times from the channel start, "
          "channel 0 empty", status == 200 and done_ok(job, h, [0, samples(b)]) and segs(job, 0) == []
          and langs(job, 1) == {"en"} and "fox" in text(job, 1).lower() and first_ms(job, 1) >= 2500, brief(status, job))
    status, job, _ = finished(auto)
    check("languages auto: language is what whisper detected (en)", status == 200 and done_ok(job, h, [samples(en), 0])
          and langs(job, 0) == {"en"} and "fox" in text(job, 0).lower() and segs(job, 1) == [], brief(status, job))
    status, job, _ = finished(empty)
    check("both channels empty (0 samples): done, no segments", status == 200 and done_ok(job, h, [0, 0])
          and segs(job, 0) == [] and segs(job, 1) == [], brief(status, job))
    status, job, _ = finished(mixed)
    ru_ms = samples(ru) * 1000 // SAMPLE_RATE
    ru_starts = [s.get("start_ms", -1) for s in picked(job, 0, "ru")]
    check("languages ru,en on Russian, 3 s pause, English: a ru run (Cyrillic) then an en run, times from the "
          "channel start", status == 200 and done_ok(job, h, [samples(m), 0]) and langs(job, 0) == {"ru", "en"}
          and re.search("[а-яё]", text(job, 0, "ru").lower()) is not None and "fox" in text(job, 0, "en").lower()
          and max(ru_starts or [10 ** 9]) < first_ms(job, 0, "en") and first_ms(job, 0, "en") >= ru_ms + 2000,
          "ru clip %d ms, first en at %s; %s" % (ru_ms, first_ms(job, 0, "en"), brief(status, job)))
    status, job, _ = finished(outside)
    check("languages ru,de on English speech: a language outside the list never wins", status == 200
          and done_ok(job, h, [samples(en), 0]) and len(segs(job, 0)) > 0 and langs(job, 0) <= {"ru", "de"},
          brief(status, job))

    s1, r1 = srv.call("DELETE", "/v2/jobs/" + main)
    s2, r2 = get(srv, main)
    s3, r3 = srv.call("DELETE", "/v2/jobs/" + main)
    check("DELETE: 200 {}, then GET 404 and DELETE 404", s1 == 200 and r1 == {} and s2 == 404 and err(r2)
          and s3 == 404 and err(r3), "%s %s / %s %s / %s %s" % (s1, r1, s2, r2, s3, r3))
    s1, r1 = put(srv, main, 0, 0, en)
    s2, job = get(srv, main)
    check("PUT after DELETE starts a new job from offset 0", s1 == s2 == 200 and r1 == {"lengths": [samples(en), 0]}
          and job.get("state") == "receiving" and job.get("languages", "") is None, "%s %s / %s" % (s1, r1, brief(s2, job)))
    return auto


def running_long(srv, job_id, timeout=120):
    status, job, _ = wait(srv, job_id, ("running",) + TERMINAL, timeout)
    return status == 200 and job.get("state") == "running", brief(status, job)


def delete_running(srv, h, en, long_pcm, jid):
    big, small = jid("abort-long"), jid("abort-short")
    big_len, small_len = [samples(long_pcm), 0], [samples(en), 0]
    ups = [upload(srv, big, 0, long_pcm)[0], upload(srv, small, 0, en)[0]]
    subs = [submit(srv, big, "en", big_len)[0], submit(srv, small, "en", small_len)[0]]
    running, detail = running_long(srv, big)
    if not running:
        check("long job reaches running", False, "uploads %s submits %s; %s" % (ups, subs, detail))
        return
    s1, r1 = put(srv, small, 0, small_len[0], en[:16])
    s2, r2 = submit(srv, small, "en", small_len)
    s3, r3 = submit(srv, small, "ru", small_len)
    check("queued job: PUT 409 {state queued}, same submit 200, other languages 409",
          s1 == 409 and err(r1, "state", "lengths") and r1["state"] == "queued" and s2 == 200 and s3 == 409
          and err(r3, "state", "lengths", "languages") and r3["state"] == "queued",
          "%s %s / %s / %s %s" % (s1, r1, s2, s3, r3))
    s1, r1 = put(srv, big, 0, big_len[0], en[:16])
    s2, r2 = submit(srv, big, "en", big_len)
    _, job = get(srv, big)
    check("running job: PUT 409 {state running}, same submit 200 and it keeps running",
          s1 == 409 and err(r1, "state", "lengths") and r1["state"] == "running" and s2 == 200
          and job.get("state") == "running", "%s %s / %s / %s" % (s1, r1, s2, brief(200, job)))
    seen, end = [], time.monotonic() + 3
    while time.monotonic() < end:
        seen.append(get(srv, big)[1].get("progress"))
        time.sleep(0.3)
    check("progress grows while the job runs", progress_ok(seen) and seen[-1] > seen[0], str(seen))
    s1, r1 = srv.call("DELETE", "/v2/jobs/" + big)
    t = time.monotonic()
    s2, r2 = get(srv, big)
    status, job, _ = wait(srv, small, TERMINAL, 60)
    took = time.monotonic() - t
    check("DELETE of the running job: 200 {}, GET 404, whisper aborted (the queued job is done within 6 s)",
          s1 == 200 and r1 == {} and s2 == 404 and status == 200 and done_ok(job, h, small_len)
          and "fox" in text(job, 0).lower() and took < 6,
          "%s %s / %s; queued job %s %.1fs after DELETE" % (s1, r1, s2, job.get("state"), took))


def remote(args, cmd):
    p = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", args.ssh, cmd],
                       capture_output=True, text=True, timeout=120)
    return p.returncode, (p.stdout + p.stderr).strip()


def answers(srv, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if srv.call("GET", "/v2/health?nonce=" + secrets.token_hex(32), timeout=5)[0] is not None:
            return True
        time.sleep(0.5)
    return False


def bounce(srv, args, kill):
    """kill -9 the unit's main process (it must come back by itself) or restart the unit. (answers again, note)"""
    unit = shlex.quote(args.unit)
    if kill:
        rc, out = remote(args, 'pid=$(systemctl --user show -p MainPID --value %s); [ "$pid" -gt 0 ] && kill -9 "$pid"'
                         % unit)
    else:
        rc, out = remote(args, "systemctl --user restart " + unit)
    if rc != 0:
        return False, "ssh %s failed: %s" % ("kill -9" if kill else "restart", out)
    time.sleep(0.5)
    if answers(srv, 15):
        return True, ""
    note = ""
    if kill:
        note = "%s did not come back within 15 s after kill -9 (the unit needs Restart=on-failure); restarted it" % args.unit
        print("INFO " + note, flush=True)
        remote(args, "systemctl --user restart " + unit)
    return answers(srv, 60), note


def gc_and_restart(srv, args, en, jid, kept):
    """GC at start by job.json mtime, the trimmed channel tail, a done job surviving the restart."""
    old, young, tail = jid("gc-old"), jid("gc-young"), jid("tail")
    ups = [put(srv, old, 0, 0, en[:4000])[0], put(srv, young, 0, 0, en[:4000])[0], put(srv, tail, 0, 0, en[:400])[0]]
    _, before = get(srv, kept)
    rc, out = remote(args, "set -e; cd %s; test -f %s/job.json; test -f %s/job.json; test -f %s/ch0.f32; "
                           "touch -m -d '8 days ago' %s/job.json; touch -m -d '6 days ago' %s/job.json; "
                           "printf abc >> %s/ch0.f32" % (shlex.quote(args.jobs), old, young, tail, old, young, tail))
    if rc != 0:
        check("GC setup: jobs files under %s" % args.jobs, False, "PUTs %s; %s" % (ups, out))
        return
    ok, note = bounce(srv, args, kill=False)
    if not ok:
        check("server answers after a restart", False, note)
        return
    s_old, r_old = get(srv, old)
    rc_gone, _ = remote(args, "test ! -e %s/%s" % (shlex.quote(args.jobs), old))
    s_young, r_young = get(srv, young)
    check("GC at start: job.json 8 days old -> job and directory gone; 6 days old -> kept",
          s_old == 404 and rc_gone == 0 and s_young == 200 and r_young.get("lengths") == [1000, 0],
          "old %s %s, dir gone %s; young %s" % (s_old, r_old, rc_gone == 0, brief(s_young, r_young)))
    s1, r1 = get(srv, tail)
    s2, r2 = put(srv, tail, 0, 100, en[400:800])
    check("start trims a channel tail that is not whole samples: receiving [100, 0], PUT at 100 appends",
          s1 == s2 == 200 and r1.get("state") == "receiving" and r1.get("lengths") == [100, 0]
          and r2 == {"lengths": [200, 0]}, "%s / %s %s" % (brief(s1, r1), s2, r2))
    status, after = get(srv, kept)
    check("a done job survives the restart unchanged", status == 200 and after == before
          and before.get("state") == "done", brief(status, after))


def restart_running(srv, args, h, en, long_pcm, jid):
    big, small = jid("restart-long"), jid("restart-queued")
    big_len, small_len = [samples(long_pcm), 0], [samples(en), 0]
    upload(srv, big, 0, long_pcm)
    upload(srv, small, 0, en)
    submit(srv, big, "en", big_len)
    submit(srv, small, "en", small_len)
    running, detail = running_long(srv, big)
    if not running:
        check("restart mid-running: the long job reaches running", False, detail)
        return
    time.sleep(1.5)
    ok, note = bounce(srv, args, kill=False)
    s, job = get(srv, big)
    state = job.get("state")
    t = time.monotonic()
    status, job, _ = wait(srv, big, TERMINAL, 180)
    took = time.monotonic() - t
    s2, job2, _ = wait(srv, small, TERMINAL, 60)
    check("restart mid-running: the job is queued again and finishes done, the queued one too",
          ok and state in ("queued", "running") and status == 200 and done_ok(job, h, big_len)
          and "fox" in text(job, 0).lower() and s2 == 200 and done_ok(job2, h, small_len),
          "%s state after restart %s, finished in %.0fs: %s; queued job: %s" % (note, state, took, brief(status, job),
                                                                              brief(s2, job2)))


def kill_twice(srv, args, h, en, long_pcm, jid):
    big, behind, after = jid("crash-long"), jid("crash-behind"), jid("crash-after")
    big_len, small_len = [samples(long_pcm), 0], [samples(en), 0]
    upload(srv, big, 0, long_pcm)
    upload(srv, behind, 0, en)
    upload(srv, after, 0, en)
    submit(srv, big, "en", big_len)
    submit(srv, behind, "en", small_len)
    running, detail = running_long(srv, big)
    if not running:
        check("kill -9: the long job reaches running", False, detail)
        return
    time.sleep(1.5)
    ok, note = bounce(srv, args, kill=True)
    running, detail = running_long(srv, big)
    s, job = get(srv, behind)
    check("after kill -9 the crashed job goes to the end of the queue and runs again (the job behind it first)",
          ok and running and s == 200 and job.get("state") == "done",
          "%s long: %s; behind: %s" % (note, detail, brief(s, job)))
    if not running:
        return
    s_sub, _ = submit(srv, after, "en", small_len)
    time.sleep(1.5)
    ok, note = bounce(srv, args, kill=True)
    s, job = get(srv, big)
    check("second kill -9 on the same job: failed, error %r" % CRASHED,
          ok and s == 200 and job.get("state") == "failed" and job.get("error") == CRASHED, "%s %s" % (note, brief(s, job)))
    status, job, _ = wait(srv, after, TERMINAL, 60)
    check("the job queued behind it still runs to done", s_sub == status == 200 and done_ok(job, h, small_len)
          and "fox" in text(job, 0).lower(), brief(status, job))
    s1, r1 = submit(srv, big, "en", [big_len[0] - 1, 0])
    check("409 resubmit of a failed job with other lengths", s1 == 409 and err(r1, "state", "lengths", "languages")
          and r1["state"] == "failed" and r1["lengths"] == big_len, "%s %s" % (s1, r1))
    s1, r1 = submit(srv, big, "en", big_len)
    s2, job = get(srv, big)
    check("resubmit of a failed job with the same lengths: 200, queued again, error cleared",
          s1 == s2 == 200 and job.get("state") in ("queued", "running") and job.get("error", "") is None,
          "%s %s / %s" % (s1, r1, brief(s2, job)))
    status, job, _ = wait(srv, big, TERMINAL, 180)
    check("the resubmitted job does not get stuck: done (or failed again)", status == 200
          and (done_ok(job, h, big_len) or job.get("state") == "failed"), brief(status, job))


def main():
    support = os.environ.get("EARMARK_HOME") or os.path.expanduser("~/Library/Application Support/earmark")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("url")
    ap.add_argument("--token-file", default=os.path.join(support, "remote-token"))
    ap.add_argument("--ssh", help="ssh host of the server: enables the restart, kill -9 and mtime checks")
    ap.add_argument("--unit", help="systemd --user unit of the server under test")
    ap.add_argument("--jobs", help="the server's jobs directory (path on the ssh host)")
    args = ap.parse_args()
    if args.ssh and not (args.unit and args.jobs):
        ap.error("--ssh needs --unit and --jobs")
    if args.unit == "earmark-whisper":
        ap.error("refusing to restart or kill the production unit")
    srv = Server(args.url, open(args.token_file).readline().strip())

    en, ru = speech(TEXT), speech(TEXT_RU, "Milena")
    gap = silence(0.3)
    long_pcm = (en + gap) * int(900 / (samples(en + gap) / SAMPLE_RATE))  # ~15 min of dense speech, ~18 s on the GPU
    print("en %.1fs, ru %.1fs, long %.0fs" % (samples(en) / SAMPLE_RATE, samples(ru) / SAMPLE_RATE,
                                            samples(long_pcm) / SAMPLE_RATE), flush=True)
    prefix, created = "smoke-%s-" % secrets.token_hex(3), []

    def jid(name):
        created.append(prefix + name)
        return created[-1]

    h = health(srv)
    removed_v1(srv, en)
    try:
        validation(srv, jid, en)
        kept = jobs(srv, h, en, ru, jid)
        delete_running(srv, h, en, long_pcm, jid)
        if args.ssh:
            gc_and_restart(srv, args, en, jid, kept)
            restart_running(srv, args, h, en, long_pcm, jid)
            kill_twice(srv, args, h, en, long_pcm, jid)
    finally:
        for job_id in created:
            srv.call("DELETE", "/v2/jobs/" + job_id)
    check("every response is an ASCII JSON object with Content-Type: application/json", not srv.not_json,
          "%d bad, e.g. %s" % (len(srv.not_json), "; ".join(srv.not_json[:4])))
    print("smoke: %d/%d passed" % (sum(results), len(results)))
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
