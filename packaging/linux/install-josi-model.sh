#!/usr/bin/env bash
# Puts Josi's model on a computer that runs Josi natively (Fedora, Bazzite, anything with systemd):
# installs Ollama if it is missing, then creates the model "josi-qwen3.5-9b" from the GGUF file.
#
#   sudo ./install-josi-model.sh /path/to/josi-qwen3.5-9b-v6.gguf
#   sudo ./install-josi-model.sh https://host/josi-qwen3.5-9b-v6.gguf   (downloaded first)
#
# Josi finds Ollama at 127.0.0.1:11434 by itself; nothing else to set up.
set -euo pipefail

NAME="${JOSI_MODEL_NAME:-josi-qwen3.5-9b}"
SRC="${1:-}"
[ -n "$SRC" ] || { echo "Usage: sudo $0 <path-or-url-of-the-model.gguf>" >&2; exit 2; }
[ "$(id -u)" = 0 ] || { echo "Run this with sudo." >&2; exit 1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

if ! command -v ollama >/dev/null 2>&1; then
  echo "== Installing Ollama"
  curl -fsSL https://ollama.com/install.sh | sh
fi
systemctl enable --now ollama >/dev/null 2>&1 || true
for _ in $(seq 1 30); do curl -fs http://127.0.0.1:11434/api/version >/dev/null 2>&1 && break; sleep 2; done
curl -fs http://127.0.0.1:11434/api/version >/dev/null || { echo "Ollama is not answering on 127.0.0.1:11434." >&2; exit 1; }

case "$SRC" in
  http://*|https://*) echo "== Downloading the model (5.8 GB)"; curl -fL --retry 5 -C - -o "$work/model.gguf" "$SRC"; GGUF="$work/model.gguf" ;;
  *) GGUF="$(readlink -f "$SRC")"; [ -f "$GGUF" ] || { echo "No such file: $SRC" >&2; exit 1; } ;;
esac

# The ollama service user must be able to read the file while the model is created.
chmod a+r "$GGUF"
printf 'FROM %s\nPARAMETER num_ctx 24576\n' "$GGUF" > "$work/Modelfile"
chmod a+r "$work/Modelfile"

echo "== Creating $NAME"
ollama create "$NAME" -f "$work/Modelfile"
ollama list | grep -F "$NAME"
echo "Done. Josi will use $NAME from Ollama (restart Josi if it was open: sudo systemctl restart josi)."
