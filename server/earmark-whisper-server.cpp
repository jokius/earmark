// earmark-whisper-server: whisper.cpp primitives over HTTP for earmark's remote transcription.
// Contract (HTTP v1): GET /v1/health, POST /v1/vad, POST /v1/language, POST /v1/full (NDJSON stream).
// The language-list algorithm and the conversion to milliseconds live in the Mac client only; this
// server just runs the same whisper.cpp calls as Sources/EarmarkTranscription/WhisperEngine.swift.
// It never logs transcript text.

#include "whisper.h"
#include "ggml-backend.h"
#include "httplib.h"
#include "json.hpp"

#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/stat.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <future>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifndef WHISPER_COMMIT
#error "WHISPER_COMMIT must be defined at build time (see CMakeLists.txt)"
#endif

using json = nlohmann::json;
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;

static whisper_context * g_ctx = nullptr;
static std::timed_mutex g_ctx_mutex;  // whisper_context is not thread-safe: full and language take it
static std::string g_vad_path;
static std::atomic<bool> g_serving{false};

// Mirror of WhisperParams.fullParams (Sources/EarmarkTranscription/WhisperParams.swift), field by field.
// Parity depends on these values being identical: change both files together.
static whisper_full_params full_params(const char * language, int threads) {
    whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
    p.n_threads = threads;
    p.beam_search.beam_size = 5;
    p.greedy.best_of = 5;
    p.n_max_text_ctx = 0;
    p.entropy_thold = 2.8f;
    p.temperature = 0;
    p.temperature_inc = 0.2f;
    p.logprob_thold = -1;
    p.no_speech_thold = 0.6f;
    p.language = language;
    p.detect_language = false;
    p.no_context = true;
    p.suppress_blank = true;
    p.suppress_nst = false;
    p.print_progress = false;
    p.vad = true;
    p.vad_model_path = g_vad_path.c_str();
    p.vad_params = whisper_vad_default_params();
    return p;
}

static double seconds_since(Clock::time_point t0) {
    return std::chrono::duration<double>(Clock::now() - t0).count();
}

// Path and language come from anyone in the LAN, already URL-decoded: escape them so nobody forges journal lines.
static std::string printable(const std::string & s) {
    std::string out;
    for (const unsigned char c : s) {
        if (c >= 0x20 && c < 0x7f) {
            out += char(c);
        } else {
            char hex[5];
            snprintf(hex, sizeof(hex), "%%%02X", c);
            out += hex;
        }
    }
    return out;
}

static void log_request(const httplib::Request & req, const std::string & outcome, double took = -1) {
    const std::string lang = printable(req.get_param_value("language"));
    char took_s[32] = "-";
    if (took >= 0) snprintf(took_s, sizeof(took_s), "%.2fs", took);
    fprintf(stderr, "%s %s from %s audio=%.1fs lang=%s took=%s: %s\n", printable(req.method).c_str(),
            printable(req.path).c_str(), req.remote_addr.c_str(), req.body.size() / 4 / double(WHISPER_SAMPLE_RATE),
            lang.empty() ? "-" : lang.c_str(), took_s, outcome.c_str());
}

static void fail(httplib::Response & res, int status, const std::string & message) {
    res.status = status;
    res.set_content(json{{"error", message}}.dump(), "application/json");
}

static void reply(httplib::Response & res, const json & body) {
    res.set_content(body.dump(-1, ' ', true, json::error_handler_t::replace), "application/json");
}

// threads=<1..64>, otherwise 0.
static int threads_of(const httplib::Request & req) {
    const std::string s = req.get_param_value("threads");
    char * end = nullptr;
    const long n = strtol(s.c_str(), &end, 10);
    return !s.empty() && *end == '\0' && n >= 1 && n <= 64 ? int(n) : 0;
}

// Body = raw little-endian float32 mono 16 kHz samples (x86 is little-endian, so a plain copy).
static bool samples_of(const httplib::Request & req, std::vector<float> & pcm) {
    if (req.body.size() % sizeof(float) != 0) return false;
    pcm.resize(req.body.size() / sizeof(float));
    if (!pcm.empty()) memcpy(pcm.data(), req.body.data(), req.body.size());
    return true;
}

// Common validation for the POST endpoints; false = response already set.
static bool parse(const httplib::Request & req, httplib::Response & res, int & threads, std::vector<float> & pcm) {
    threads = threads_of(req);
    if (!threads) { fail(res, 400, "threads must be an integer 1..64"); return false; }
    if (!samples_of(req, pcm)) { fail(res, 400, "body must be float32 samples (length divisible by 4)"); return false; }
    return true;
}

static bool same(const std::string & a, const std::string & b) {
    if (a.size() != b.size()) return false;  // the length of the token is not a secret
    volatile unsigned char diff = 0;
    for (size_t i = 0; i < a.size(); i++) diff |= (unsigned char) (a[i] ^ b[i]);
    return diff == 0;
}

// SHA-256 (FIPS 180-4) of msg, 32 raw bytes. Hand-written for the health proof: the box has no OpenSSL headers and
// the whisper.cpp tree no usable copy. main() checks it against RFC 4231 before serving.
static std::string sha256_digest(const std::string & msg) {
    static const uint32_t k[64] = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
    uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
    auto rotr = [](uint32_t x, int n) { return x >> n | x << (32 - n); };
    std::string m = msg + '\x80';
    m.append((64 - (m.size() + 8) % 64) % 64, '\0');
    for (int i = 7; i >= 0; i--) m += char(uint64_t(msg.size()) * 8 >> (8 * i));
    for (size_t off = 0; off < m.size(); off += 64) {
        uint32_t w[64];
        for (int i = 0; i < 16; i++) {
            const auto * p = reinterpret_cast<const unsigned char *>(m.data() + off + 4 * i);
            w[i] = uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3];
        }
        for (int i = 16; i < 64; i++) {
            const uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ w[i - 15] >> 3;
            const uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ w[i - 2] >> 10;
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], x = h[7];
        for (int i = 0; i < 64; i++) {
            const uint32_t t1 = x + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + k[i] + w[i];
            const uint32_t t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
            x = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += x;
    }
    std::string out;
    for (uint32_t v : h) for (int s = 24; s >= 0; s -= 8) out += char(v >> s);
    return out;
}

// HMAC-SHA256 (RFC 2104) as lowercase hex.
static std::string hmac_sha256_hex(std::string key, const std::string & msg) {
    if (key.size() > 64) key = sha256_digest(key);
    key.resize(64, '\0');
    std::string ipad = key, opad = key;
    for (char & c : ipad) c ^= 0x36;
    for (char & c : opad) c ^= 0x5c;
    std::string hex;
    for (unsigned char c : sha256_digest(opad + sha256_digest(ipad + msg))) {
        hex += "0123456789abcdef"[c >> 4];
        hex += "0123456789abcdef"[c & 15];
    }
    return hex;
}

static std::string sha256_of(const std::string & path) {
    std::string cmd = "sha256sum -- '";
    for (char c : path) cmd += c == '\'' ? std::string("'\\''") : std::string(1, c);
    cmd += "'";
    FILE * f = popen(cmd.c_str(), "r");
    if (!f) return "";
    char hex[64];
    const size_t n = fread(hex, 1, sizeof(hex), f);
    return pclose(f) == 0 && n == sizeof(hex) ? std::string(hex, sizeof(hex)) : "";
}

// First line of the token file, trimmed. Refuses missing, empty or group/world-readable files.
static std::string read_token(const std::string & path, std::string & why) {
    struct stat st;
    if (stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode)) { why = "token file not found: " + path; return ""; }
    if (st.st_mode & 077) { why = "token file must be chmod 600: " + path; return ""; }
    std::ifstream in(path);
    std::string line;
    std::getline(in, line);
    const char * ws = " \t\r\n\v\f";
    const size_t b = line.find_first_not_of(ws);
    if (b == std::string::npos) { why = "token file is empty: " + path; return ""; }
    return line.substr(b, line.find_last_not_of(ws) - b + 1);
}

// One /v1/full request: the worker runs whisper_full, the HTTP thread streams progress and watches the client.
struct FullJob {
    std::vector<float> pcm;
    std::string language;
    int threads = 0;
    std::atomic<int> progress{0};
    std::atomic<bool> abort{false};
    std::atomic<bool> done{false};
    std::string result;   // the final NDJSON line, set before done
    std::string outcome;  // for the log, never contains text
};

static void run_full(FullJob & job) {
    try {
        std::unique_lock<std::timed_mutex> lock(g_ctx_mutex, std::defer_lock);
        while (!lock.try_lock_for(100ms)) {
            if (job.abort) { job.outcome = "aborted while waiting for the GPU"; job.done = true; return; }
        }
        whisper_full_params p = full_params(job.language.c_str(), job.threads);
        p.progress_callback = [](whisper_context *, whisper_state *, int percent, void * user) {
            static_cast<FullJob *>(user)->progress = percent;
        };
        p.progress_callback_user_data = &job;
        // Called after every encode/decode step: a closed connection stops whisper_full within one step.
        p.abort_callback = [](void * user) { return static_cast<FullJob *>(user)->abort.load(); };
        p.abort_callback_user_data = &job;
        const int code = whisper_full(g_ctx, p, job.pcm.data(), int(job.pcm.size()));
        if (job.abort) {
            job.outcome = "whisper_full aborted";
        } else if (code != 0) {
            job.outcome = "error: whisper_full returned " + std::to_string(code);
            job.result = json{{"error", "whisper_full returned " + std::to_string(code)}}.dump();
        } else {
            // Read the segments before releasing the context: the next request overwrites them.
            json segments = json::array();
            const int n = whisper_full_n_segments(g_ctx);
            for (int i = 0; i < n; i++) {
                const char * text = whisper_full_get_segment_text(g_ctx, i);
                segments.push_back({{"t0", whisper_full_get_segment_t0(g_ctx, i)},
                                    {"t1", whisper_full_get_segment_t1(g_ctx, i)},
                                    {"text", text ? text : ""}});
            }
            // Invalid UTF-8 (a token split mid-character) becomes U+FFFD, as Swift's String(cString:) does. ASCII
            // only (\uXXXX): the Mac's AsyncBytes.lines also splits on a raw U+2028, U+2029 or U+0085.
            job.result = json{{"segments", segments}}.dump(-1, ' ', true, json::error_handler_t::replace);
            job.outcome = "ok, " + std::to_string(n) + " segments";
        }
    } catch (const std::exception & e) {
        job.outcome = std::string("error: ") + e.what();
        job.result = json{{"error", std::string("internal error: ") + e.what()}}
                         .dump(-1, ' ', true, json::error_handler_t::replace);
    }
    job.done = true;
}

// {"progress":P} on every change and at least once a second (heartbeat), then one final line.
static bool stream_full(FullJob & job, const httplib::Request & req, httplib::DataSink & sink) {
    const auto t0 = Clock::now();
    std::thread worker([&job] { run_full(job); });
    auto send = [&sink](const json & line) {
        const std::string s = line.dump() + "\n";
        return sink.write(s.data(), s.size());
    };
    bool alive = true;
    int sent = -1;
    auto last = t0;
    while (alive && !job.done) {
        const int p = job.progress;
        if (p != sent || Clock::now() - last >= 1s) {
            alive = send({{"progress", p}});
            sent = p;
            last = Clock::now();
        }
        if (alive && req.is_connection_closed()) alive = false;
        if (alive) std::this_thread::sleep_for(100ms);
    }
    if (!alive) job.abort = true;
    worker.join();
    if (alive && !job.abort) {
        if (job.progress != sent) alive = send({{"progress", job.progress.load()}});
        const std::string last_line = job.result + "\n";
        alive = alive && sink.write(last_line.data(), last_line.size());
        if (alive) sink.done();
    }
    log_request(req, alive ? job.outcome : "client disconnected, " + job.outcome, seconds_since(t0));
    return alive;
}

// With OpenMP every thread that runs a ggml CPU graph keeps its own libgomp team until that thread exits. On httplib's
// long-lived pool threads the teams pile up, libgomp stops spinning once they outnumber the cores, and the CPU VAD
// (here and inside whisper_full) gets ~50x slower for good. So such handlers run on a thread that exits afterwards,
// like /v1/full's worker; std::async rethrows on the pool thread, where httplib turns exceptions into a 500.
static httplib::Server::Handler on_own_thread(httplib::Server::Handler handler) {
    return [handler](const httplib::Request & req, httplib::Response & res) {
        std::async(std::launch::async, handler, std::cref(req), std::ref(res)).get();
    };
}

static void usage() {
    fprintf(stderr, "usage: earmark-whisper-server --model PATH --vad-model PATH --token-file PATH "
                    "[--host 0.0.0.0] [--port 8178]\n");
}

int main(int argc, char ** argv) {
    std::string model, vad, token_file, host = "0.0.0.0";
    int port = 8178;
    for (int i = 1; i < argc; i++) {
        const std::string arg = argv[i];
        if (i + 1 >= argc) { usage(); return 2; }
        const std::string value = argv[++i];
        if (arg == "--model") model = value;
        else if (arg == "--vad-model") vad = value;
        else if (arg == "--token-file") token_file = value;
        else if (arg == "--host") host = value;
        else if (arg == "--port") port = atoi(value.c_str());
        else { usage(); return 2; }
    }
    if (model.empty() || vad.empty() || token_file.empty() || port <= 0 || port > 65535) { usage(); return 2; }

    std::string why;
    const std::string token = read_token(token_file, why);
    if (token.empty()) { fprintf(stderr, "error: %s\n", why.c_str()); return 1; }
    const std::string expected_auth = "Bearer " + token;
    // RFC 4231 cases 1, 2 and 6 (key longer than a block) before the HMAC vouches for this server.
    if (hmac_sha256_hex(std::string(20, '\x0b'), "Hi There") !=
            "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7" ||
        hmac_sha256_hex("Jefe", "what do ya want for nothing?") !=
            "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" ||
        hmac_sha256_hex(std::string(131, '\xaa'), "Test Using Larger Than Block-Size Key - Hash Key First") !=
            "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54") {
        fprintf(stderr, "error: HMAC-SHA256 self-test failed\n");
        return 1;
    }

    // whisper/ggml log: everything while loading, then only warnings and errors (no per-request noise).
    whisper_log_set([](ggml_log_level level, const char * text, void *) {
        static ggml_log_level last = GGML_LOG_LEVEL_INFO;
        if (level == GGML_LOG_LEVEL_CONT) level = last; else last = level;
        if (level == GGML_LOG_LEVEL_DEBUG || (g_serving && level < GGML_LOG_LEVEL_WARN)) return;
        fputs(text, stderr);
    }, nullptr);

    // On CPU whisper.cpp would quietly serve slower than the Mac's Metal while looking healthy: fail, systemd retries.
    ggml_backend_dev_t gpu_dev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU);
    if (!gpu_dev) { fprintf(stderr, "error: no CUDA GPU found (check nvidia-smi), refusing to run on the CPU\n"); return 1; }
    const std::string gpu = ggml_backend_dev_description(gpu_dev);

    const std::string model_sha = sha256_of(model), vad_sha = sha256_of(vad);
    if (model_sha.empty() || vad_sha.empty()) { fprintf(stderr, "error: cannot read %s or %s\n", model.c_str(), vad.c_str()); return 1; }
    g_vad_path = vad;

    // Context as in WhisperEngine.init (Sources/EarmarkTranscription/WhisperEngine.swift).
    whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = true;
    cparams.flash_attn = true;
    g_ctx = whisper_init_from_file_with_params(model.c_str(), cparams);
    if (!g_ctx) { fprintf(stderr, "error: whisper.cpp failed to load the model %s\n", model.c_str()); return 1; }

    httplib::Server svr;
    svr.set_payload_max_length(size_t(1536) << 20);  // 1.5 GiB; larger -> 413
    svr.set_read_timeout(60s);
    svr.set_tcp_nodelay(true);
    // One request per connection: after a 401 the unread body must not be parsed as the next request.
    svr.set_keep_alive_max_count(1);
    // Set on the listening socket, Linux copies it to accepted ones. A client gone without a FIN (lid closed, left
    // the LAN) stops ACKing the heartbeats: the write fails after 30 s and /v1/full frees the GPU, not after ~15 min.
    svr.set_socket_options([](socket_t sock) {
        httplib::default_socket_options(sock);
        const int ms = 30000;
        setsockopt(sock, IPPROTO_TCP, TCP_USER_TIMEOUT, &ms, sizeof(ms));
    });

    // Before the body is read: an unauthorized client never gets to upload audio. /v1/health is the handshake in
    // which the server proves it knows the token, so it needs none (a header, if sent, is ignored), but no body.
    svr.set_pre_routing_handler([&](const httplib::Request & req, httplib::Response & res) {
        const bool handshake = req.method == "GET" && req.path == "/v1/health" && !httplib::detail::expect_content(req);
        if (handshake || same(req.get_header_value("Authorization"), expected_auth)) {
            return httplib::Server::HandlerResponse::Unhandled;
        }
        fail(res, 401, "unauthorized");
        return httplib::Server::HandlerResponse::Handled;
    });
    // Every status >= 400 (ours or httplib's 404/413/400) gets a JSON body and one log line.
    svr.set_error_handler([](const httplib::Request & req, httplib::Response & res) {
        if (res.body.empty()) fail(res, res.status, httplib::status_message(res.status));
        if (!req.method.empty()) log_request(req, std::to_string(res.status) + " " + res.body);
    });

    // proof = HMAC-SHA256(token, nonce as received): the Mac sends the token and audio only to a server that has it.
    svr.Get("/v1/health", [&](const httplib::Request & req, httplib::Response & res) {
        const std::string nonce = req.get_param_value("nonce");
        if (nonce.size() != 64 || nonce.find_first_not_of("0123456789abcdefABCDEF") != std::string::npos) {
            return fail(res, 400, "nonce must be 64 hex characters");
        }
        reply(res, {{"whisper", whisper_version()}, {"commit", WHISPER_COMMIT}, {"model_sha256", model_sha},
                    {"vad_sha256", vad_sha}, {"gpu", gpu}, {"proof", hmac_sha256_hex(token, nonce)}});
    });

    // As WhisperEngine.speech: own VAD context per call, no context mutex.
    svr.Post("/v1/vad", on_own_thread([&](const httplib::Request & req, httplib::Response & res) {
        const auto t0 = Clock::now();
        int threads;
        std::vector<float> pcm;
        if (!parse(req, res, threads, pcm)) return;
        whisper_vad_context_params cp = whisper_vad_default_context_params();
        cp.n_threads = threads;
        whisper_vad_context * vctx = whisper_vad_init_from_file_with_params(g_vad_path.c_str(), cp);
        if (!vctx) return fail(res, 500, "whisper.cpp failed to load the VAD model");
        whisper_vad_segments * found =
            whisper_vad_segments_from_samples(vctx, whisper_vad_default_params(), pcm.data(), int(pcm.size()));
        if (!found) { whisper_vad_free(vctx); return fail(res, 500, "whisper VAD failed to detect speech"); }
        json spans = json::array();
        const int n = whisper_vad_segments_n_segments(found);
        for (int i = 0; i < n; i++) {
            // Raw centiseconds as float; nlohmann prints the shortest round-trip double, so the float is exact.
            spans.push_back({whisper_vad_segments_get_segment_t0(found, i), whisper_vad_segments_get_segment_t1(found, i)});
        }
        whisper_vad_free_segments(found);
        whisper_vad_free(vctx);
        reply(res, {{"spans", spans}});
        log_request(req, "ok, " + std::to_string(n) + " spans", seconds_since(t0));
    }));

    // As WhisperEngine.languageProbabilities. Today the mel and auto_detect leave no OpenMP team behind, but a
    // backend that runs one op on the CPU would bring the /v1/vad slowdown back, so the same short-lived thread.
    svr.Post("/v1/language", on_own_thread([&](const httplib::Request & req, httplib::Response & res) {
        const auto t0 = Clock::now();
        int threads;
        std::vector<float> pcm;
        if (!parse(req, res, threads, pcm)) return;
        json probs = json::object();
        if (!pcm.empty()) {
            std::lock_guard<std::timed_mutex> lock(g_ctx_mutex);
            const int mel = whisper_pcm_to_mel(g_ctx, pcm.data(), int(pcm.size()), threads);
            if (mel != 0) return fail(res, 500, "whisper_pcm_to_mel returned " + std::to_string(mel));
            std::vector<float> p(whisper_lang_max_id() + 1, 0.0f);
            const int top = whisper_lang_auto_detect(g_ctx, 0, threads, p.data());
            if (top < 0) return fail(res, 500, "whisper_lang_auto_detect returned " + std::to_string(top));
            for (int id = 0; id < int(p.size()); id++) {
                if (const char * code = whisper_lang_str(id)) probs[code] = p[id];
            }
        }
        reply(res, {{"probs", probs}});
        log_request(req, "ok", seconds_since(t0));
    }));

    svr.Post("/v1/full", [&](const httplib::Request & req, httplib::Response & res) {
        auto job = std::make_shared<FullJob>();
        job->language = req.get_param_value("language");
        if (job->language != "auto" && whisper_lang_id(job->language.c_str()) < 0) {
            return fail(res, 400, "language must be auto or a whisper language code");
        }
        if (!parse(req, res, job->threads, job->pcm)) return;
        // The provider runs inside this request's processing, so req outlives it.
        res.set_chunked_content_provider("application/x-ndjson", [job, &req](size_t, httplib::DataSink & sink) {
            return stream_full(*job, req, sink);
        });
    });

    fprintf(stderr, "earmark-whisper-server: whisper %s (%s), gpu \"%s\", listening on %s:%d\n", whisper_version(),
            WHISPER_COMMIT, gpu.c_str(), host.c_str(), port);
    g_serving = true;
    if (!svr.listen(host, port)) { fprintf(stderr, "error: cannot listen on %s:%d\n", host.c_str(), port); return 1; }
    return 0;
}
