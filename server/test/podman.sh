#!/usr/bin/env sh
# Podman network stack test: one SFU container and three simulator
# containers join one room through the challenge handshake and exchange
# media through the server. Any simulator below the packet threshold
# fails the run.
set -e
cd "$(dirname "$0")/.."

mkdir -p test/bin
CGO_ENABLED=0 go build -ldflags="-s -w" -o test/bin/toom-server ./cmd/toom-server
CGO_ENABLED=0 go build -ldflags="-s -w" -o test/bin/toomsim ./cmd/toomsim
podman build -q -t toom-net-test -f test/Containerfile test/ >/dev/null

podman network rm -f toomnet >/dev/null 2>&1 || true
podman network create toomnet >/dev/null
podman rm -f toom-srv sim-a sim-b sim-c >/dev/null 2>&1 || true

podman run -d --name toom-srv --network toomnet toom-net-test /toom-server run --config /config.json >/dev/null
sleep 1

podman run --name sim-a --network toomnet toom-net-test /toomsim \
	-server toom-srv:4400 -room demo -secret s3cret -name alice -frames 30 -peers 2 \
	>test/bin/sim-a.log 2>&1 &
pa=$!
podman run --name sim-b --network toomnet toom-net-test /toomsim \
	-server toom-srv:4400 -room demo -secret s3cret -name bob -frames 30 -peers 2 \
	>test/bin/sim-b.log 2>&1 &
pb=$!
podman run --name sim-c --network toomnet toom-net-test /toomsim \
	-server toom-srv:4400 -room demo -secret s3cret -name carol -frames 30 -peers 2 \
	>test/bin/sim-c.log 2>&1 &
pc=$!

fail=0
wait $pa || fail=1
wait $pb || fail=1
wait $pc || fail=1

echo "=== server ==="
podman logs toom-srv
for s in a b c; do
	echo "=== sim-$s ==="
	cat "test/bin/sim-$s.log"
	grep -q "PASS" "test/bin/sim-$s.log" || fail=1
done

podman rm -f toom-srv sim-a sim-b sim-c >/dev/null 2>&1 || true
podman network rm -f toomnet >/dev/null 2>&1 || true

if [ $fail -ne 0 ]; then
	echo "[-] network test FAILED"
	exit 1
fi
echo "[+] network test PASS"
