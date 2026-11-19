#!/usr/bin/env bash
# Builds the all-in-one image.
#
#   ./build.sh                                   v6 model file from ~/josi-model, Josi package from ./pkg
#   GGUF=josi-qwen3.5-9b-v7-Q4_K_M.gguf TAG=josi-allinone:v7 ./build.sh
#
# MODEL_DIR  folder with the GGUF (default ~/josi-model)
# PKG_DIR    folder with josi_*_amd64.deb and SHA256SUMS.txt (default ./pkg)
# GGUF       the model file name inside MODEL_DIR
# TAG        the image name (default josi-allinone:v6, the model file in use today)
set -euo pipefail
cd "$(dirname "$0")"
MODEL_DIR=${MODEL_DIR:-$HOME/josi-model}
PKG_DIR=${PKG_DIR:-$PWD/pkg}
GGUF=${GGUF:-josi-qwen3.5-9b-v6-Q4_K_M.gguf}
TAG=${TAG:-josi-allinone:v6}
NUM_CTX=${NUM_CTX:-24576}

[ -f "$MODEL_DIR/$GGUF" ] || { echo "The model file $MODEL_DIR/$GGUF is not there."; exit 1; }
ls "$PKG_DIR"/josi_*_amd64.deb >/dev/null 2>&1 || { echo "No josi_*_amd64.deb in $PKG_DIR."; exit 1; }
[ ! -f "$PKG_DIR/SHA256SUMS.txt" ] || (cd "$PKG_DIR" && sha256sum -c SHA256SUMS.txt --ignore-missing)

# The model name Josi expects is josi-qwen3.5-9b; the window is what Josi cannot send itself.
printf 'FROM /model/%s\nPARAMETER num_ctx %s\n' "$GGUF" "$NUM_CTX" > Modelfile
echo "Building $TAG from $GGUF and $(basename "$(ls "$PKG_DIR"/josi_*_amd64.deb | head -n1)")"
docker buildx build --load -t "$TAG" \
  --build-context model="$MODEL_DIR" --build-context pkg="$PKG_DIR" .
docker image ls "$TAG"
echo "--- layers (size, step)"
docker history --no-trunc --format '{{.Size}}\t{{.CreatedBy}}' "$TAG" | cut -c1-150
