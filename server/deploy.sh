#!/usr/bin/env bash
# Deploys earmark-whisper-server to a Linux / WSL2 box with an NVIDIA GPU. Run it on the Mac; safe to re-run.
#   server/deploy.sh <ssh-host> [lan-host] [--dev]
# ssh-host: how this Mac reaches the box over ssh (an alias from ~/.ssh/config is fine).
# lan-host: the name earmark will use for http://<lan-host>:8178 (default: ssh-host), e.g. gpu-box.local.
# On the box everything lives in ~/earmark-server/ (jobs in ~/earmark-server/jobs) plus the user unit
# ~/.config/systemd/user/earmark-whisper.service.
# --dev: a second instance for development that never touches the production one: ~/earmark-server-dev/ (own build
# and jobs; its token must already be there), unit earmark-whisper-dev on 127.0.0.1:8179 only, not enabled at boot,
# the production models read in place. Its health is fetched on the box (reach it with ssh -N -L 8179:127.0.0.1:8179).
set -euo pipefail

DEV=
HOSTS=()
for arg in "$@"; do
    if [ "$arg" = --dev ]; then DEV=1; else HOSTS+=("$arg"); fi
done
SSH_HOST=${HOSTS[0]:?usage: deploy.sh <ssh-host> [lan-host] [--dev]}
LAN_HOST=${HOSTS[1]:-$SSH_HOST}
if [ -n "$DEV" ]; then DIR=earmark-server-dev UNIT=earmark-whisper-dev PORT=8179; else DIR=earmark-server UNIT=earmark-whisper PORT=8178; fi
COMMIT=927cfce34f31707e17f2bff35c349632fb9e2c3a  # = RemoteWhisperClient.whisperCommit (v1.9.4, b5130)
MODEL_SHA=1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69
VAD_SHA=29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf
CUDA_PACKAGE=cuda-toolkit-12-9  # Blackwell (sm_120) needs CUDA >= 12.8

HERE=$(cd "$(dirname "$0")" && pwd)
SUPPORT=${EARMARK_HOME:-$HOME/Library/Application Support/earmark}
MODEL=$SUPPORT/models/ggml-large-v3-turbo.bin
VAD=$HERE/../Resources/Models/ggml-silero-v5.1.2.bin
TOKEN_FILE=$SUPPORT/remote-token
SRC=${XDG_CACHE_HOME:-$HOME/.cache}/earmark-server/whisper.cpp
# HMAC-SHA256(token file's first line, nonce): what /v2/health must prove. The token goes by file, never argv.
HMAC_PY='import hashlib, hmac, sys; print(hmac.new(open(sys.argv[1]).readline().strip().encode(), sys.argv[2].encode(), hashlib.sha256).hexdigest())'

step() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
remote() { ssh "$SSH_HOST" "$@"; }

step "whisper.cpp at $COMMIT"
if [ ! -d "$SRC/.git" ]; then
    git clone --filter=blob:none --no-checkout https://github.com/ggml-org/whisper.cpp.git "$SRC"
fi
git -C "$SRC" cat-file -e "$COMMIT^{commit}" 2>/dev/null || git -C "$SRC" fetch --filter=blob:none origin "$COMMIT"
git -C "$SRC" -c advice.detachedHead=false checkout -q "$COMMIT"
[ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || die "$SRC is not at $COMMIT"
[ -z "$(git -C "$SRC" status --porcelain)" ] || die "$SRC has local changes"

step "sources -> $SSH_HOST:~/$DIR/src"
remote "mkdir -p ~/$DIR/src ~/$DIR/bin ~/earmark-server/models && chmod 700 ~/$DIR"
rsync -a --delete "$SRC/" "$SSH_HOST:$DIR/src/whisper.cpp/"
rsync -a --delete --exclude __pycache__ "$HERE/" "$SSH_HOST:$DIR/src/server/"

step "models"
copy_model() {  # local-path expected-sha256
    local name; name=$(basename "$1")
    local have; have=$(remote "sha256sum earmark-server/models/$name 2>/dev/null | cut -c1-64" || true)
    if [ "$have" = "$2" ]; then echo "$name: up to date"; return; fi
    [ -z "$DEV" ] || die "$name in ~/earmark-server/models on $SSH_HOST is missing or differs: deploy production first"
    [ -f "$1" ] || die "$1 not found (download the model with earmark first)"
    [ "$(shasum -a 256 "$1" | cut -c1-64)" = "$2" ] || die "$1 does not match sha256 $2"
    rsync -a --partial "$1" "$SSH_HOST:earmark-server/models/$name"
    have=$(remote "sha256sum earmark-server/models/$name | cut -c1-64")
    [ "$have" = "$2" ] || die "$name on $SSH_HOST has sha256 $have, expected $2"
    echo "$name: copied and verified"
}
copy_model "$MODEL" "$MODEL_SHA"
copy_model "$VAD" "$VAD_SHA"

step "CUDA toolkit"
remote bash -s -- "$CUDA_PACKAGE" <<'EOF'
set -euo pipefail
if [ -x /usr/local/cuda/bin/nvcc ]; then /usr/local/cuda/bin/nvcc --version | tail -1; exit 0; fi
# Toolkit only, from NVIDIA's WSL-Ubuntu repo: the GPU driver comes from Windows and must never be installed here.
. /etc/os-release
repo=https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64
case "$ID" in ubuntu) ;; *) echo "unsupported distro $ID: install the CUDA toolkit by hand" >&2; exit 1 ;; esac
tmp=$(mktemp -d)
wget -q -O "$tmp/keyring.deb" "$repo/cuda-keyring_1.1-1_all.deb"
sudo dpkg -i "$tmp/keyring.deb"
sudo apt-get update -q
sudo apt-get install -y -q "$1"
rm -rf "$tmp"
EOF

step "build"
remote bash -s -- "$DIR" <<'EOF'
set -euo pipefail
cd ~/"$1"
# Content check of the synced tree against its commit (also refreshes the index rsync left stale).
[ -z "$(git -C src/whisper.cpp status --porcelain)" ] || { echo "whisper.cpp on this host differs from HEAD" >&2; exit 1; }
export CUDACXX=/usr/local/cuda/bin/nvcc
cmake -S src/server -B build -DWHISPER_SRC="$HOME/$1/src/whisper.cpp" > build.log 2>&1 || { tail -40 build.log; exit 1; }
cmake --build build -j"$(nproc)" --target earmark-whisper-server >> build.log 2>&1 || { tail -40 build.log; exit 1; }
tail -2 build.log
cp build/earmark-whisper-server bin/earmark-whisper-server.new
mv -f bin/earmark-whisper-server.new bin/earmark-whisper-server  # rename: works while the old one runs
EOF

step "token"
if [ -n "$DEV" ]; then
    remote "test -s ~/$DIR/token" || die "~/$DIR/token on $SSH_HOST is missing: put the dev token there (chmod 600)"
    echo "~/$DIR/token: kept"
else
    if [ ! -s "$TOKEN_FILE" ]; then
        mkdir -p "$SUPPORT"
        (umask 077; openssl rand -hex 32 > "$TOKEN_FILE")
        echo "generated $TOKEN_FILE"
    fi
    chmod 600 "$TOKEN_FILE"
    # Through stdin, never argv.
    remote 'umask 077; cat > ~/earmark-server/token.new && mv -f ~/earmark-server/token.new ~/earmark-server/token' < "$TOKEN_FILE"
fi

step "service $UNIT"
remote bash -s -- "$DEV" <<'EOF'
set -euo pipefail
[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" = yes ] || sudo loginctl enable-linger "$USER"
if [ -n "$1" ]; then
    # The production unit with the dev binary, token, jobs and a loopback-only listener; the same models.
    mkdir -p ~/.config/systemd/user
    sed -e 's|^Description=.*|& (development, 127.0.0.1:8179)|' \
        -e 's|%h/earmark-server/bin/|%h/earmark-server-dev/bin/|' \
        -e 's|%h/earmark-server/token|%h/earmark-server-dev/token --host 127.0.0.1 --port 8179 --jobs-dir %h/earmark-server-dev/jobs|' \
        ~/earmark-server-dev/src/server/earmark-whisper.service > ~/.config/systemd/user/earmark-whisper-dev.service
    systemctl --user daemon-reload
    systemctl --user restart earmark-whisper-dev.service
else
    install -D -m 644 ~/earmark-server/src/server/earmark-whisper.service ~/.config/systemd/user/earmark-whisper.service
    systemctl --user daemon-reload
    systemctl --user enable -q earmark-whisper.service
    systemctl --user restart earmark-whisper.service
fi
EOF

if [ -n "$DEV" ]; then
    where="127.0.0.1:$PORT on $SSH_HOST"
    get_health() { remote "curl -sf --max-time 5 'http://127.0.0.1:$PORT/v2/health?nonce=$1'"; }
    expected_proof() { remote "python3 -c '$HMAC_PY' ~/$DIR/token $1"; }
else
    where="http://$LAN_HOST:$PORT from this Mac"
    get_health() { curl -sf --max-time 5 "http://$LAN_HOST:$PORT/v2/health?nonce=$1"; }
    expected_proof() { python3 -c "$HMAC_PY" "$TOKEN_FILE" "$1"; }
fi
step "health: $where"
nonce=$(openssl rand -hex 32)
health=
for _ in $(seq 60); do
    if health=$(get_health "$nonce"); then break; fi
    health=
    sleep 2
done
[ -n "$health" ] || { remote "journalctl --user -u $UNIT -n 30 --no-pager" || true; die "no health response from $where"; }
echo "$health"
python3 - "$(expected_proof "$nonce")" "$health" "$COMMIT" "$MODEL_SHA" "$VAD_SHA" <<'EOF' || die "server is up but did not prove the token or is not compatible (commit or model/VAD sha256 differ)"
import hmac, json, sys
want, health, commit, model, vad = sys.argv[1:]
h = json.loads(health)
proven = hmac.compare_digest(h.get("proof", ""), want)
compatible = (h.get("commit"), h.get("model_sha256"), h.get("vad_sha256")) == (commit, model, vad)
sys.exit(not (proven and compatible))
EOF
echo "proof and compatibility verified"

if [ -n "$DEV" ]; then
    step "done; dev server on $where (from the Mac: ssh -N -L $PORT:127.0.0.1:$PORT $SSH_HOST)"
else
    step "done; enable remote transcription in earmark with:"
    echo "earmark config set transcription.remote.url http://$LAN_HOST:$PORT"
    echo "earmark config set transcription.remote.enabled true"
fi
