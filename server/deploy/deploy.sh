#!/bin/sh
# Builds the server for Linux and installs it on the droplet.
#
#   deploy/deploy.sh root@live.somto.si
#
# First-time setup is in server/README.md ("Deploy").
set -eu

if [ $# -ne 1 ]; then
  echo "usage: $0 user@host" >&2
  exit 2
fi
target=$1
cd "$(dirname "$0")/.."

build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT
echo "Building…"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' -o "$build/fitmeasure-server" ./cmd/fitmeasure-server

echo "Copying to $target…"
scp -q "$build/fitmeasure-server" deploy/fitmeasure.service "$target:/tmp/"

echo "Installing and restarting…"
ssh "$target" '
  set -e
  test -f /etc/fitmeasure/fitmeasure.env || { echo "missing /etc/fitmeasure/fitmeasure.env (see server/README.md)" >&2; exit 1; }
  install -m 755 /tmp/fitmeasure-server /usr/local/bin/fitmeasure-server
  install -m 644 /tmp/fitmeasure.service /etc/systemd/system/fitmeasure.service
  rm -f /tmp/fitmeasure-server /tmp/fitmeasure.service
  systemctl daemon-reload
  systemctl enable --quiet fitmeasure
  systemctl restart fitmeasure
  sleep 2
  systemctl --no-pager --lines=8 status fitmeasure
'
