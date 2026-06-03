#!/usr/bin/env bash
set -euo pipefail

# -p 8080:8080 forwards the guest web service (QEMU hostfwd :8080 -> guest :80)
# out to the Docker host, so you can `curl localhost:8080` from your machine.
docker run --rm --platform linux/amd64 -p 8080:8080 -v "$(cd .. && pwd)":/work minibash-linux-builder /work/minibash-linux/out/run-qemu.sh
