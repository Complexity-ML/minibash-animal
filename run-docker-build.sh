#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
docker build --platform linux/amd64 -t minibash-linux-builder .
docker run --rm --platform linux/amd64 -v "$(cd .. && pwd)":/work minibash-linux-builder
