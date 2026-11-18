// earmark-whisper-server: earmark's remote transcription server, HTTP protocol v2.
// The Mac uploads the two channels of a recording (f32le 16 kHz mono) into a job and submits it; one worker thread
// transcribes queued jobs with the same whisper.cpp calls as Sources/EarmarkTranscription/WhisperEngine.swift
// (decode/decodeMulti) and keeps the raw segments until the Mac takes them. Jobs live on disk
// (<jobs>/<id>/{job.json, ch0.f32, ch1.f32}), so the Mac may sleep or leave and this server may restart.
// It never logs transcript text.

#include "whisper.h"
#include "ggml-backend.h"
#include "httplib.h"
#include "json.hpp"

#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <memory>
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
namespace fs = std::filesystem;

static whisper_context * g_ctx = nullptr;  // only the worker touches it: whisper_context is not thread-safe
static std::string g_vad_path, g_model_name, g_model_sha;
static std::atomic<bool> g_serving{false};
static fs::path g_jobs_dir;
static uintmax_t g_quota = uintmax_t(20) << 30;
static int g_ttl_days = 7;

struct Job {
    json doc;                     // = job.json: state, source, languages, error, runs, queued_at[, model, model_sha256, channels]
    int64_t lengths[2] = {0, 0};  // samples per channel = channel file size / 4
    std::atomic<int> progress{0};
    std::atomic<bool> abort{false};  // set by DELETE: whisper_full stops within one step
};
static std::mutex g_mutex;  // guards g_jobs, every Job's doc and lengths, and every write under g_jobs_dir
static std::condition_variable g_wake;  // a job became queued
static std::map<std::string, std::shared_ptr<Job>> g_jobs;

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
static const int kThreads = 4;  // WhisperParams.reference: min(4, cores)

static double seconds_since(Clock::time_point t0) {
    return std::chrono::duration<double>(Clock::now() - t0).count();
}

static int64_t now_ms() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
}

// Path and languages come from anyone in the LAN, already URL-decoded: escape them so nobody forges journal lines.
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

// The one serializer for job.json and every response. ASCII only (\uXXXX); invalid UTF-8 (a token split
// mid-character) becomes U+FFFD, as Swift's String(cString:) does.
static std::string dump(const json & j) {
    return j.dump(-1, ' ', true, json::error_handler_t::replace);
}

static void reply(httplib::Response & res, const json & body) {
    res.set_content(dump(body), "application/json");
}

static void fail(httplib::Response & res, int status, const std::string & message) {
    res.status = status;
    reply(res, {{"error", message}});
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

// ---- LanguagePlan (Sources/EarmarkCore/Transcript/LanguagePlan.swift), ported rule for rule ----

struct Span {
    int64_t start, end;  // ms
    bool operator==(const Span & o) const { return start == o.start && end == o.end; }
};
struct Run {
    int64_t start, end;
    std::string language;
    bool operator==(const Run & o) const { return start == o.start && end == o.end && language == o.language; }
};

// VAD spans glued into chunks of up to 30 s when the pause is under a second: language detection sees a 30 s window
// and errs more often on half a second of speech.
static std::vector<Span> plan_chunks(const std::vector<Span> & speech) {
    std::vector<Span> out;
    for (const Span & s : speech) {
        if (!out.empty() && s.start - out.back().end < 1000 && s.end - out.back().start <= 30000) {
            out.back().end = s.end;
        } else {
            out.push_back(s);
        }
    }
    return out;
}

// The most probable language of `allowed`. whisper hears Azerbaijani as Turkish, so az also gets tr's probability,
// unless tr is allowed itself. A tie goes to the earlier one in `allowed`.
static std::string plan_pick(const std::map<std::string, float> & probs, const std::vector<std::string> & allowed) {
    static const std::map<std::string, std::vector<std::string>> aliases = {{"az", {"tr"}}};
    auto prob = [&](const std::string & code) { const auto it = probs.find(code); return it == probs.end() ? 0.0f : it->second; };
    auto score = [&](const std::string & language) {
        float s = prob(language);
        const auto it = aliases.find(language);
        if (it != aliases.end()) {
            for (const auto & alias : it->second) {
                if (std::find(allowed.begin(), allowed.end(), alias) == allowed.end()) s += prob(alias);
            }
        }
        return s;
    };
    std::string best = allowed[0];
    float best_score = score(best);
    for (size_t i = 1; i < allowed.size(); i++) {
        const float s = score(allowed[i]);
        if (s > best_score) { best = allowed[i]; best_score = s; }
    }
    return best;
}

// Adjacent chunks of one language become one run, one whisper_full: fewer calls and context inside the run.
static std::vector<Run> plan_runs(const std::vector<Span> & chunks, const std::vector<std::string> & languages) {
    std::vector<Run> out;
    for (size_t i = 0; i < chunks.size() && i < languages.size(); i++) {
        if (!out.empty() && out.back().language == languages[i]) {
            out.back().end = chunks[i].end;
        } else {
            out.push_back({chunks[i].start, chunks[i].end, languages[i]});
        }
    }
    return out;
}

static bool plan_self_test() {
    const std::map<std::string, float> turkish = {{"tr", 0.6f}, {"en", 0.3f}, {"az", 0.002f}}, tie = {{"ru", 0.4f}, {"en", 0.4f}};
    return plan_chunks({{0, 1000}, {1999, 3000}, {4000, 5000}}) == std::vector<Span>{{0, 3000}, {4000, 5000}} &&  // pause < 1000 ms
           plan_chunks({{0, 20000}, {20500, 30000}, {30500, 31000}}) == std::vector<Span>{{0, 30000}, {30500, 31000}} &&  // 30 s cap
           plan_pick(turkish, {"en", "az"}) == "az" && plan_pick(turkish, {"en", "az", "tr"}) == "tr" &&  // alias
           plan_pick(tie, {"en", "ru"}) == "en" && plan_pick(tie, {"ru", "en"}) == "ru" && plan_pick({}, {"ru", "en"}) == "ru" &&
           plan_runs({{0, 1000}, {2000, 3000}, {5000, 6000}}, {"en", "en", "ru"}) ==
               std::vector<Run>{{0, 3000, "en"}, {5000, 6000, "ru"}};
}

static std::vector<std::string> split(const std::string & s) {
    std::vector<std::string> out;
    for (size_t from = 0;;) {
        const size_t comma = s.find(',', from);
        out.push_back(s.substr(from, comma - from));
        if (comma == std::string::npos) return out;
        from = comma + 1;
    }
}

// "auto", or whisper language codes separated by commas (TranscriptionLanguage.raw).
static bool valid_languages(const std::string & languages) {
    if (languages == "auto") return true;
    for (const std::string & code : split(languages)) {
        bool known = false;  // by walking the table: whisper_lang_id would log an unknown string unescaped
        for (int id = 0; id <= whisper_lang_max_id() && !known; id++) {
            const char * s = whisper_lang_str(id);
            known = s && code == s;
        }
        if (!known) return false;
    }
    return true;
}

// ---- transcription: WhisperEngine.decode on the server ----

struct Callbacks {
    std::function<void(int)> progress;
    const std::atomic<bool> * abort;
};

// One whisper_full with WhisperParams.fullParams; segments in ms from the start of the channel (+ shift_ms).
static void whisper_run(const float * pcm, size_t n, const std::string & language, int64_t shift_ms, const Callbacks & cb,
                        json & segments) {
    whisper_full_params p = full_params(language.c_str(), kThreads);
    p.progress_callback = [](whisper_context *, whisper_state *, int percent, void * user) {
        static_cast<const Callbacks *>(user)->progress(percent);
    };
    p.progress_callback_user_data = const_cast<Callbacks *>(&cb);
    // Called before every ggml computation: DELETE of the running job frees the GPU within one step.
    p.abort_callback = [](void * user) { return static_cast<const Callbacks *>(user)->abort->load(); };
    p.abort_callback_user_data = const_cast<Callbacks *>(&cb);
    const int code = whisper_full(g_ctx, p, pcm, int(n));
    if (*cb.abort) throw std::runtime_error("aborted");
    if (code != 0) throw std::runtime_error("whisper_full returned " + std::to_string(code));
    std::string lang = language;
    if (language == "auto") {
        const int id = whisper_full_lang_id(g_ctx);
        const char * detected = id >= 0 ? whisper_lang_str(id) : nullptr;
        if (detected) lang = detected;
    }
    const char * ws = " \t\r\n\v\f";
    const int count = whisper_full_n_segments(g_ctx);
    for (int i = 0; i < count; i++) {
        const char * raw = whisper_full_get_segment_text(g_ctx, i);
        std::string text = raw ? raw : "";
        const size_t b = text.find_first_not_of(ws);
        text = b == std::string::npos ? "" : text.substr(b, text.find_last_not_of(ws) - b + 1);
        // t0/t1 are centiseconds from the start of pcm.
        segments.push_back({{"start_ms", whisper_full_get_segment_t0(g_ctx, i) * 10 + shift_ms},
                            {"end_ms", whisper_full_get_segment_t1(g_ctx, i) * 10 + shift_ms},
                            {"text", text},
                            {"language", lang}});
    }
}

// Silero VAD with defaults, own context per call (WhisperEngine.vad), spans in ms.
static std::vector<Span> speech(const std::vector<float> & pcm) {
    whisper_vad_context_params cp = whisper_vad_default_context_params();
    cp.n_threads = kThreads;
    whisper_vad_context * vctx = whisper_vad_init_from_file_with_params(g_vad_path.c_str(), cp);
    if (!vctx) throw std::runtime_error("whisper.cpp failed to load the VAD model");
    whisper_vad_segments * found = whisper_vad_segments_from_samples(vctx, whisper_vad_default_params(), pcm.data(), int(pcm.size()));
    if (!found) { whisper_vad_free(vctx); throw std::runtime_error("whisper VAD failed to detect speech"); }
    std::vector<Span> out;
    for (int i = 0; i < whisper_vad_segments_n_segments(found); i++) {
        // Centiseconds as float, rounded as Swift's Float.rounded() does.
        out.push_back({std::lround(whisper_vad_segments_get_segment_t0(found, i) * 10.0f),
                       std::lround(whisper_vad_segments_get_segment_t1(found, i) * 10.0f)});
    }
    whisper_vad_free_segments(found);
    whisper_vad_free(vctx);
    return out;
}

// Probabilities of every whisper language for a piece (WhisperEngine.languageProbabilities); empty piece -> none.
static std::map<std::string, float> language_probabilities(const float * pcm, size_t n) {
    std::map<std::string, float> out;
    if (n == 0) return out;
    const int mel = whisper_pcm_to_mel(g_ctx, pcm, int(n), kThreads);
    if (mel != 0) throw std::runtime_error("whisper_pcm_to_mel returned " + std::to_string(mel));
    std::vector<float> p(whisper_lang_max_id() + 1, 0.0f);
    const int top = whisper_lang_auto_detect(g_ctx, 0, kThreads, p.data());
    if (top < 0) throw std::runtime_error("whisper_lang_auto_detect returned " + std::to_string(top));
    for (int id = 0; id < int(p.size()); id++) {
        if (const char * code = whisper_lang_str(id)) out[code] = p[id];
    }
    return out;
}

// One channel. One code or auto: the whole channel in one whisper_full. A list: VAD -> chunks -> the language of each
// chunk -> runs of one language, each its own whisper_full. Progress 0-10 language detection, 10-100 the runs.
static json transcribe(const std::vector<float> & pcm, const std::string & languages, const std::function<void(int)> & progress,
                       const std::atomic<bool> & abort) {
    json segments = json::array();
    if (pcm.empty()) return segments;
    const std::vector<std::string> allowed = split(languages);
    if (allowed.size() == 1) {
        whisper_run(pcm.data(), pcm.size(), allowed[0], 0, {progress, &abort}, segments);
        return segments;
    }
    // Samples of a span; VAD padding may reach past the channel, so clamp.
    auto slice = [&](int64_t start_ms, int64_t end_ms) {
        const int64_t per_ms = WHISPER_SAMPLE_RATE / 1000, count = int64_t(pcm.size());
        const int64_t lower = std::min(std::max<int64_t>(0, start_ms * per_ms), count);
        const int64_t upper = std::min(std::max(lower, end_ms * per_ms), count);
        return std::make_pair(pcm.data() + lower, size_t(upper - lower));
    };
    const std::vector<Span> chunks = plan_chunks(speech(pcm));
    std::vector<std::string> picked;
    for (size_t i = 0; i < chunks.size(); i++) {
        if (abort) throw std::runtime_error("aborted");
        progress(int(i * 10 / chunks.size()));
        const auto piece = slice(chunks[i].start, chunks[i].end);
        picked.push_back(plan_pick(language_probabilities(piece.first, piece.second), allowed));
    }
    const std::vector<Run> runs = plan_runs(chunks, picked);
    int64_t total = 0, done = 0;
    for (const Run & run : runs) total += run.end - run.start;
    total = std::max<int64_t>(1, total);
    for (const Run & run : runs) {
        if (abort) throw std::runtime_error("aborted");
        const int64_t length = run.end - run.start;
        auto scaled = [&, done, length](int percent) {
            const int64_t share = done * 100 + length * std::min(std::max(percent, 0), 100);
            progress(int(10 + 90 * share / (total * 100)));
        };
        const auto piece = slice(run.start, run.end);
        // whisper counts time from the start of the samples it gets: shift by the start of the run.
        whisper_run(piece.first, piece.second, run.language, run.start, {scaled, &abort}, segments);
        done += length;
    }
    progress(100);
    return segments;
}

// ---- jobs on disk ----

static bool valid_id(const std::string & id) {
    return !id.empty() && id.size() <= 64 && id.find_first_not_of("0123456789abcdefghijklmnopqrstuvwxyz-") == std::string::npos;
}

static fs::path channel_path(const std::string & id, int n) {
    return g_jobs_dir / id / ("ch" + std::to_string(n) + ".f32");
}

static void fsync_path(const fs::path & path) {
    const int fd = open(path.c_str(), O_RDONLY);
    if (fd >= 0) { fsync(fd); close(fd); }
}

// job.json through temp + rename + fsync: a crash leaves the old file or the new one, never half of one.
static void save(const std::string & id, const Job & job) {
    const fs::path dir = g_jobs_dir / id, tmp = dir / "job.json.tmp";
    const std::string s = dump(job.doc);
    const int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    const bool written = fd >= 0 && write(fd, s.data(), s.size()) == ssize_t(s.size()) && fsync(fd) == 0;
    int err = errno;
    if (fd >= 0) close(fd);
    if (written && rename(tmp.c_str(), (dir / "job.json").c_str()) == 0) return fsync_path(dir);
    if (written) err = errno;
    throw std::runtime_error("cannot write " + (dir / "job.json").string() + ": " + strerror(err));
}

static json view(const Job & job) {
    const std::string state = job.doc.at("state");
    json v = {{"state", state},
              {"progress", state == "done" ? 100 : state == "running" ? job.progress.load() : 0},
              {"lengths", json::array({job.lengths[0], job.lengths[1]})},
              {"languages", job.doc.at("languages")},
              {"source", job.doc.at("source")},
              {"error", job.doc.at("error")}};
    if (state == "done") {
        for (const char * key : {"model", "model_sha256", "channels"}) v[key] = job.doc.at(key);
    }
    return v;
}

// 409 of one shape whatever the state: what the server has, so the client can resume or start over.
static void conflict(httplib::Response & res, const std::string & message, const Job & job, bool with_languages) {
    json body = {{"error", message}, {"state", job.doc.at("state")}, {"lengths", json::array({job.lengths[0], job.lengths[1]})}};
    if (with_languages) body["languages"] = job.doc.at("languages");
    res.status = 409;
    reply(res, body);
}

static uintmax_t jobs_bytes() {
    uintmax_t total = 0;
    for (const auto & entry : fs::recursive_directory_iterator(g_jobs_dir)) {
        std::error_code ec;
        const uintmax_t size = entry.is_regular_file(ec) ? entry.file_size(ec) : 0;
        if (!ec) total += size;
    }
    return total;
}

static std::shared_ptr<Job> create_job(const std::string & id, const std::string & source) {
    const fs::path dir = g_jobs_dir / id;
    fs::remove_all(dir);  // leftovers this server does not know as a job
    fs::create_directory(dir);
    for (int n = 0; n < 2; n++) {
        const int fd = open(channel_path(id, n).c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (fd < 0) throw std::runtime_error("cannot create " + channel_path(id, n).string());
        close(fd);
    }
    auto job = std::make_shared<Job>();
    job->doc = {{"state", "receiving"}, {"source", source}, {"languages", nullptr}, {"error", nullptr}, {"runs", 0}, {"queued_at", 0}};
    save(id, *job);
    fsync_path(g_jobs_dir);
    g_jobs[id] = job;
    return job;
}

static bool pwrite_all(int fd, const char * p, size_t n, off_t at) {
    while (n > 0) {
        const ssize_t w = pwrite(fd, p, n, at);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) return false;
        p += w; n -= size_t(w); at += w;
    }
    return true;
}

// Startup: every <jobs>/<id>/job.json back into memory. A job the server died on goes to the end of the queue, unless
// it already died on it twice. A channel tail that is not whole samples (a write cut short) is cut off.
static void load_jobs() {
    fs::create_directories(g_jobs_dir);
    int requeued = 0, crashed = 0;
    for (const auto & entry : fs::directory_iterator(g_jobs_dir)) {
        const std::string id = entry.path().filename().string();
        if (!valid_id(id) || !entry.is_directory()) continue;
        auto job = std::make_shared<Job>();
        try {
            std::ifstream in(entry.path() / "job.json");
            job->doc = json::parse(in);
            for (int n = 0; n < 2; n++) {
                const fs::path ch = channel_path(id, n);
                const uintmax_t size = fs::file_size(ch), whole = size / 4 * 4;
                if (whole != size) fs::resize_file(ch, whole);
                job->lengths[n] = int64_t(whole / 4);
            }
            const std::string state = view(*job).at("state");  // view(): every field the API needs is there
            if (state == "running") {
                if (job->doc.value("runs", 0) >= 2) {
                    job->doc["state"] = "failed";
                    job->doc["error"] = "server crashed on this job twice";
                    crashed++;
                } else {
                    job->doc["state"] = "queued";
                    job->doc["queued_at"] = now_ms();
                    requeued++;
                }
                save(id, *job);
            } else if (state != "receiving" && state != "queued" && state != "done" && state != "failed") {
                throw std::runtime_error("unknown state " + state);
            }
            // The worker reads these on every wake-up; a bad type there would throw outside any catch and loop restarts.
            (void)job->doc.at("queued_at").get<int64_t>();
            (void)job->doc.value("runs", 0);
        } catch (const std::exception & e) {
            fprintf(stderr, "job %s: unreadable, removed: %s\n", id.c_str(), e.what());
            fs::remove_all(entry.path());
            continue;
        }
        g_jobs[id] = job;
    }
    fprintf(stderr, "jobs in %s: %zu, requeued after a crash %d, failed after crashing twice %d\n",
            g_jobs_dir.c_str(), g_jobs.size(), requeued, crashed);
}

// Jobs whose job.json is older than the TTL go, except the running one.
static void gc() {
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto cutoff = fs::file_time_type::clock::now() - std::chrono::hours(24 * g_ttl_days);
    for (auto it = g_jobs.begin(); it != g_jobs.end();) {
        std::error_code ec;
        const auto mtime = fs::last_write_time(g_jobs_dir / it->first / "job.json", ec);
        if (ec || it->second->doc.at("state") == "running" || mtime >= cutoff) { ++it; continue; }
        fs::remove_all(g_jobs_dir / it->first, ec);
        if (ec) { fprintf(stderr, "gc: cannot remove job %s: %s\n", it->first.c_str(), ec.message().c_str()); ++it; continue; }
        fprintf(stderr, "gc: job %s removed (older than %d days)\n", it->first.c_str(), g_ttl_days);
        it = g_jobs.erase(it);
    }
}

static bool current(const std::string & id, const std::shared_ptr<Job> & job) {
    const auto it = g_jobs.find(id);
    return it != g_jobs.end() && it->second == job;
}

static std::vector<float> read_channel(const std::string & id, int n, int64_t length) {
    std::vector<float> pcm(static_cast<size_t>(length));
    if (length == 0) return pcm;
    std::ifstream in(channel_path(id, n), std::ios::binary);
    if (!in.read(reinterpret_cast<char *>(pcm.data()), std::streamsize(length) * 4)) {
        throw std::runtime_error("cannot read channel " + std::to_string(n));
    }
    return pcm;
}

// One job, start to end. Any exception or whisper error -> failed with its text. A job deleted meanwhile is dropped.
static void run_job(const std::string id, const std::shared_ptr<Job> job) {
    const auto t0 = Clock::now();
    std::string error;
    json channels = json::array();
    try {
        std::string languages;
        int64_t lengths[2];
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            if (!current(id, job)) return;
            job->doc["state"] = "running";
            job->doc["runs"] = job->doc.value("runs", 0) + 1;
            job->progress = 0;
            save(id, *job);  // before whisper: a job that crashes the server is not retried forever
            languages = job->doc.at("languages");
            lengths[0] = job->lengths[0];
            lengths[1] = job->lengths[1];
        }
        fprintf(stderr, "job %s: running, languages %s, %.1fs + %.1fs of audio\n", id.c_str(), printable(languages).c_str(),
                lengths[0] / double(WHISPER_SAMPLE_RATE), lengths[1] / double(WHISPER_SAMPLE_RATE));
        for (int n = 0; n < 2; n++) {
            auto progress = [&job, n](int percent) { job->progress = (n * 100 + std::min(std::max(percent, 0), 100)) / 2; };
            channels.push_back({{"segments", transcribe(read_channel(id, n, lengths[n]), languages, progress, job->abort)}});
        }
    } catch (const std::exception & e) {
        error = *e.what() ? e.what() : "internal error";
    } catch (...) {
        error = "internal error";
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!current(id, job)) {
        fprintf(stderr, "job %s: deleted while running, dropped after %.1fs\n", id.c_str(), seconds_since(t0));
        return;
    }
    if (error.empty()) {
        job->doc["state"] = "done";
        job->doc["model"] = g_model_name;
        job->doc["model_sha256"] = g_model_sha;
        job->doc["channels"] = channels;
        fprintf(stderr, "job %s: done in %.1fs, %zu + %zu segments\n", id.c_str(), seconds_since(t0),
                channels[0]["segments"].size(), channels[1]["segments"].size());
    } else {
        job->doc["state"] = "failed";
        job->doc["error"] = error;
        fprintf(stderr, "job %s: failed after %.1fs: %s\n", id.c_str(), seconds_since(t0), printable(error).c_str());
    }
    try {
        save(id, *job);
    } catch (const std::exception & e) {
        fprintf(stderr, "job %s: %s\n", id.c_str(), e.what());
    }
}

// The single GPU worker: queued jobs in submit order.
static void worker() {
    for (;;) {
        std::string id;
        std::shared_ptr<Job> job;
        {
            std::unique_lock<std::mutex> lock(g_mutex);
            g_wake.wait(lock, [&] {
                int64_t first = INT64_MAX;
                for (const auto & [key, candidate] : g_jobs) {
                    if (candidate->doc.at("state") != "queued" || candidate->doc.at("queued_at").get<int64_t>() >= first) continue;
                    first = candidate->doc.at("queued_at");
                    id = key;
                    job = candidate;
                }
                return job != nullptr;
            });
        }
        // With OpenMP every thread that runs a ggml CPU graph (the VAD, here and inside whisper_full) keeps its own
        // libgomp team until the thread exits; teams that outnumber the cores make the VAD ~50x slower for good.
        // So every job runs on a thread that exits afterwards.
        std::thread(run_job, id, job).join();
    }
}

static void usage() {
    fprintf(stderr, "usage: earmark-whisper-server --model PATH --vad-model PATH --token-file PATH [--host 0.0.0.0] "
                    "[--port 8178] [--jobs-dir ~/earmark-server/jobs] [--jobs-quota-gb 20] [--jobs-ttl-days 7]\n");
}

static thread_local Clock::time_point t_start = Clock::now();
static thread_local std::string t_note;  // what a handler adds to its log line; never transcript text

int main(int argc, char ** argv) {
    const char * home = getenv("HOME");
    std::string model, vad, token_file, host = "0.0.0.0", jobs_dir = std::string(home ? home : ".") + "/earmark-server/jobs";
    int port = 8178;
    double quota_gb = 20;
    for (int i = 1; i < argc; i++) {
        const std::string arg = argv[i];
        if (i + 1 >= argc) { usage(); return 2; }
        const std::string value = argv[++i];
        if (arg == "--model") model = value;
        else if (arg == "--vad-model") vad = value;
        else if (arg == "--token-file") token_file = value;
        else if (arg == "--host") host = value;
        else if (arg == "--port") port = atoi(value.c_str());
        else if (arg == "--jobs-dir") jobs_dir = value;
        else if (arg == "--jobs-quota-gb") quota_gb = atof(value.c_str());
        else if (arg == "--jobs-ttl-days") g_ttl_days = atoi(value.c_str());
        else { usage(); return 2; }
    }
    if (model.empty() || vad.empty() || token_file.empty() || jobs_dir.empty() || port <= 0 || port > 65535 ||
        !(quota_gb > 0) || g_ttl_days < 1) {
        usage();
        return 2;
    }
    g_jobs_dir = jobs_dir;
    g_quota = uintmax_t(quota_gb * double(uintmax_t(1) << 30));

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
    if (!plan_self_test()) { fprintf(stderr, "error: language plan self-test failed\n"); return 1; }

    // whisper/ggml log: everything while loading, then only warnings and errors (no per-job noise).
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

    g_model_sha = sha256_of(model);
    const std::string vad_sha = sha256_of(vad);
    if (g_model_sha.empty() || vad_sha.empty()) { fprintf(stderr, "error: cannot read %s or %s\n", model.c_str(), vad.c_str()); return 1; }
    g_model_name = fs::path(model).filename().string();
    g_vad_path = vad;

    // Context as in WhisperEngine.init (Sources/EarmarkTranscription/WhisperEngine.swift).
    whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = true;
    cparams.flash_attn = true;
    g_ctx = whisper_init_from_file_with_params(model.c_str(), cparams);
    if (!g_ctx) { fprintf(stderr, "error: whisper.cpp failed to load the model %s\n", model.c_str()); return 1; }

    load_jobs();
    gc();

    httplib::Server svr;
    svr.set_payload_max_length(size_t(64) << 20);  // one channel chunk; larger -> 413
    svr.set_read_timeout(60s);
    svr.set_tcp_nodelay(true);
    // One request per connection: after a 401 the unread body must not be parsed as the next request.
    svr.set_keep_alive_max_count(1);
    // Set on the listening socket, Linux copies it to accepted ones: a client gone without a FIN (lid closed, left the
    // LAN) frees its handler thread after 30 s, not after ~15 min. SO_REUSEADDR instead of httplib's default
    // SO_REUSEPORT: with REUSEPORT a second instance binds the same port and the kernel splits requests between two job
    // stores, so a job uploaded to one is 404 on the other.
    svr.set_socket_options([](socket_t sock) {
        const int yes = 1;
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        const int ms = 30000;
        setsockopt(sock, IPPROTO_TCP, TCP_USER_TIMEOUT, &ms, sizeof(ms));
    });

    // Before any body is read: an unauthorized client never gets to upload audio. /v2/health is the handshake in which
    // the server proves it knows the token, so it needs none (a header, if sent, is ignored), but no body.
    svr.set_pre_routing_handler([&](const httplib::Request & req, httplib::Response & res) {
        t_start = Clock::now();
        t_note.clear();
        if (req.path == "/v2/jobs" || req.path.rfind("/v2/jobs/", 0) == 0) {
            if (same(req.get_header_value("Authorization"), expected_auth)) return httplib::Server::HandlerResponse::Unhandled;
            fail(res, 401, "unauthorized");
        } else if (req.path == "/v2/health" && req.method == "GET") {
            if (!httplib::detail::expect_content(req)) return httplib::Server::HandlerResponse::Unhandled;
            fail(res, 401, "unauthorized");
        } else {
            fail(res, 404, "not found");
        }
        return httplib::Server::HandlerResponse::Handled;
    });
    // Every status >= 400 (ours or httplib's 400/413) gets a JSON body.
    svr.set_error_handler([](const httplib::Request &, httplib::Response & res) {
        if (res.body.empty()) fail(res, res.status, httplib::status_message(res.status));
    });
    // One line per request: errors carry their JSON (ASCII, no transcript text), successes the handler's note.
    svr.set_logger([](const httplib::Request & req, const httplib::Response & res) {
        fprintf(stderr, "%s %s from %s: %d %s took=%.2fs\n", printable(req.method).c_str(), printable(req.path).c_str(),
                req.remote_addr.c_str(), res.status, res.status >= 400 ? res.body.c_str() : t_note.c_str(),
                seconds_since(t_start));
    });

    // proof = HMAC-SHA256(token, nonce as received): the Mac sends the token and audio only to a server that has it.
    svr.Get("/v2/health", [&](const httplib::Request & req, httplib::Response & res) {
        const std::string nonce = req.get_param_value("nonce");
        if (nonce.size() != 64 || nonce.find_first_not_of("0123456789abcdefABCDEF") != std::string::npos) {
            return fail(res, 400, "nonce must be 64 hex characters");
        }
        reply(res, {{"whisper", whisper_version()}, {"commit", WHISPER_COMMIT}, {"model", g_model_name},
                    {"model_sha256", g_model_sha}, {"vad_sha256", vad_sha}, {"gpu", gpu},
                    {"proof", hmac_sha256_hex(token, nonce)}});
    });

    // Append to a channel at exactly its current length: a resent or lost chunk shows up as a 409 with the lengths.
    svr.Put(R"(/v2/jobs/([^/]*)/channels/([^/]*))", [&](const httplib::Request & req, httplib::Response & res) {
        const std::string id = req.matches[1], ch = req.matches[2];
        const std::string offset_s = req.get_param_value("offset"), source = req.get_param_value("source");
        if (!valid_id(id)) return fail(res, 400, "job id must match [0-9a-z-]{1,64}");
        if (ch != "0" && ch != "1") return fail(res, 400, "channel must be 0 or 1");
        if (offset_s.empty() || offset_s.size() > 15 || offset_s.find_first_not_of("0123456789") != std::string::npos) {
            return fail(res, 400, "offset must be an integer >= 0");
        }
        if (!source.empty() && source != "stream" && source != "m4a") return fail(res, 400, "source must be stream or m4a");
        if (req.body.size() % sizeof(float) != 0) return fail(res, 400, "body must be float32 samples (length divisible by 4)");
        const int n = ch[0] - '0';
        const int64_t offset = std::stoll(offset_s), samples = int64_t(req.body.size() / sizeof(float));
        const std::string want_source = source.empty() ? "m4a" : source;
        t_note = "offset=" + offset_s + " samples=" + std::to_string(samples);

        std::lock_guard<std::mutex> lock(g_mutex);
        if (jobs_bytes() + req.body.size() > g_quota) return fail(res, 507, "jobs directory is over its quota");
        auto it = g_jobs.find(id);
        Job & job = *(it != g_jobs.end() ? it->second : create_job(id, offset == 0 ? want_source : "m4a"));
        if (job.doc.at("state") != "receiving") return conflict(res, "job is not receiving audio", job, false);
        if (offset != job.lengths[n]) return conflict(res, "offset is not the channel length", job, false);
        if (job.lengths[0] == 0 && job.lengths[1] == 0 && job.doc.at("source") != want_source) {
            job.doc["source"] = want_source;  // only the first chunk of an empty job says where the audio comes from
            save(id, job);
        }
        const fs::path path = channel_path(id, n);
        const int fd = open(path.c_str(), O_WRONLY);
        const off_t at = off_t(offset) * 4;
        // Cut whatever a failed write left past the length first; 200 only once the data is on disk.
        const bool ok = fd >= 0 && ftruncate(fd, at) == 0 && pwrite_all(fd, req.body.data(), req.body.size(), at) && fsync(fd) == 0;
        const int err = errno;
        if (!ok && fd >= 0 && ftruncate(fd, at) == 0) fsync(fd);
        if (fd >= 0) close(fd);
        if (!ok) return fail(res, 500, "cannot write " + path.string() + ": " + strerror(err));
        job.lengths[n] = offset + samples;
        reply(res, {{"lengths", json::array({job.lengths[0], job.lengths[1]})}});
    });

    svr.Post(R"(/v2/jobs/([^/]*)/submit)", [&](const httplib::Request & req, httplib::Response & res) {
        const std::string id = req.matches[1];
        if (!valid_id(id)) return fail(res, 400, "job id must match [0-9a-z-]{1,64}");
        const json body = json::parse(req.body, nullptr, false);
        const bool shaped = body.is_object() && body.contains("languages") && body["languages"].is_string() &&
                            body.contains("lengths") && body["lengths"].is_array() && body["lengths"].size() == 2 &&
                            std::all_of(body["lengths"].begin(), body["lengths"].end(),
                                        [](const json & l) { return l.is_number_integer() && l.get<int64_t>() >= 0; });
        if (!shaped) return fail(res, 400, "body must be {\"languages\": \"<codes>\", \"lengths\": [n0, n1]}");
        const std::string languages = body["languages"];
        if (!valid_languages(languages)) return fail(res, 400, "languages must be auto or whisper language codes separated by commas");
        t_note = "languages=" + printable(languages);

        std::lock_guard<std::mutex> lock(g_mutex);
        const auto it = g_jobs.find(id);
        if (it == g_jobs.end()) return fail(res, 404, "no such job");
        Job & job = *it->second;
        const std::string state = job.doc.at("state");
        const bool same_lengths = body["lengths"][0] == job.lengths[0] && body["lengths"][1] == job.lengths[1];
        if (state == "receiving" || state == "failed") {
            if (!same_lengths) return conflict(res, "lengths do not match the job", job, true);
            job.doc["state"] = "queued";
            job.doc["languages"] = languages;
            job.doc["error"] = nullptr;
            job.doc["runs"] = 0;  // counts crashes of this attempt
            job.doc["queued_at"] = now_ms();
            save(id, job);
            g_wake.notify_one();
        } else if (!same_lengths || job.doc.at("languages") != languages) {
            return conflict(res, "lengths or languages do not match the job", job, true);
        }
        reply(res, view(job));
    });

    svr.Get(R"(/v2/jobs/([^/]*))", [&](const httplib::Request & req, httplib::Response & res) {
        const std::string id = req.matches[1];
        if (!valid_id(id)) return fail(res, 400, "job id must match [0-9a-z-]{1,64}");
        std::lock_guard<std::mutex> lock(g_mutex);
        const auto it = g_jobs.find(id);
        if (it == g_jobs.end()) return fail(res, 404, "no such job");
        const json v = view(*it->second);
        t_note = v["state"].get<std::string>() + " " + std::to_string(v["progress"].get<int>()) + "%";
        reply(res, v);
    });

    // With a content reader: httplib would otherwise wait for a body a DELETE without Content-Length never sends.
    svr.Delete(R"(/v2/jobs/([^/]*))", [&](const httplib::Request & req, httplib::Response & res, const httplib::ContentReader &) {
        const std::string id = req.matches[1];
        if (!valid_id(id)) return fail(res, 400, "job id must match [0-9a-z-]{1,64}");
        std::lock_guard<std::mutex> lock(g_mutex);
        const auto it = g_jobs.find(id);
        if (it == g_jobs.end()) return fail(res, 404, "no such job");
        fs::remove_all(g_jobs_dir / id);
        fsync_path(g_jobs_dir);
        it->second->abort = true;  // the worker drops a job that is no longer in g_jobs
        g_jobs.erase(it);
        reply(res, json::object());
    });

    // Bind before the worker starts: a busy port must not cut a job short and count against it as a crash.
    if (!svr.bind_to_port(host, port)) {
        fprintf(stderr, "error: cannot listen on %s:%d\n", host.c_str(), port);
        return 1;
    }
    std::thread(worker).detach();
    std::thread([] { for (;;) { std::this_thread::sleep_for(1h); gc(); } }).detach();
    fprintf(stderr, "earmark-whisper-server: whisper %s (%s), model %s, gpu \"%s\", listening on %s:%d\n", whisper_version(),
            WHISPER_COMMIT, g_model_name.c_str(), gpu.c_str(), host.c_str(), port);
    g_serving = true;
    svr.listen_after_bind();
    // _exit: the detached worker still waits on g_wake, which exit()'s destructors must not touch.
    fprintf(stderr, "error: the server stopped listening on %s:%d\n", host.c_str(), port);
    _exit(1);
}
