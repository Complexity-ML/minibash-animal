#!/usr/bin/env bash
# One-shot job. restart=false, so minit marks it desired=down once it exits;
# run it on demand with `bashsvc start worker`.
set -u

echo "worker: background job online"
sleep 3
echo "worker: done"
