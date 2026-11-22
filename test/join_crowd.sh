#!/usr/bin/env sh
# join_crowd.sh - join one toom meeting from many toom clients with
# virtual cameras so multi user TUI behavior can be tested on one host.
#
# usage:
#   sh test/join_crowd.sh <meeting-code> <count>
#   sh test/join_crowd.sh stop
#
# Run it as your normal user inside niri. Only modprobe asks for sudo.
# Do not sudo the whole script, sudo drops NIRI_SOCKET and the niri
# spawn calls fail.
#
# The meeting must exist already. Create it from one toom instance and
# paste the meeting code here. Every client opens as a foot window on
# niri because the sixel video only renders in a real terminal, tmux
# drops it. Each client joins as user<N> with its own v4l2loopback
# camera fed by ffmpeg test patterns in YUYV, the only format toom
# negotiates with loopback devices.
set -eu

TOOM_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASE_VIDEO=8

cmd_stop() {
	pkill -f 'toom --join' 2>/dev/null || true
	pkill -f 'yuyv422 -f v4l2' 2>/dev/null || true
	if lsmod | grep -q '^v4l2loopback'; then
		sudo modprobe -r v4l2loopback 2>/dev/null || true
	fi
	echo "[+] crowd stopped"
}

if [ "${1:-}" = "stop" ]; then
	cmd_stop
	exit 0
fi

if [ "$#" -ne 2 ]; then
	echo "[-] usage: sh test/join_crowd.sh <meeting-code> <count>"
	exit 1
fi

if [ -z "${NIRI_SOCKET:-}" ]; then
	echo "[-] NIRI_SOCKET not set, run inside niri and without sudo"
	exit 1
fi

CODE="$1"
COUNT="$2"
case "$COUNT" in
*[!0-9]* | "")
	echo "[-] count must be a number from 1 to 9"
	exit 1
	;;
esac
if [ "$COUNT" -lt 1 ] || [ "$COUNT" -gt 9 ]; then
	echo "[-] count must be from 1 to 9"
	exit 1
fi

if [ ! -x "$TOOM_DIR/toom" ]; then
	echo "[-] $TOOM_DIR/toom not built, run sh build.sh first"
	exit 1
fi

for tool in ffmpeg niri foot; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "[-] $tool not found"
		exit 1
	fi
done

echo "[i] loading v4l2loopback with $COUNT cameras"
VNR="$(seq "$BASE_VIDEO" $((BASE_VIDEO + COUNT - 1)) | paste -sd, -)"
LABELS=""
i=1
while [ "$i" -le "$COUNT" ]; do
	LABELS="$LABELS,toom-test-$i"
	i=$((i + 1))
done
LABELS="${LABELS#,}"
if ! lsmod | grep -q '^v4l2loopback'; then
	sudo modprobe v4l2loopback "devices=$COUNT" "video_nr=$VNR" \
		"card_label=$LABELS" exclusive_caps=1
fi

PATTERNS="testsrc testsrc2 smptebars smptehdbars rgbtestsrc yuvtestsrc gradients mandelbrot smpte"
echo "[i] feeding YUYV test patterns into the virtual cameras"
i=1
while [ "$i" -le "$COUNT" ]; do
	dev="/dev/video$((BASE_VIDEO + i - 1))"
	pat="$(echo "$PATTERNS" | cut -d' ' -f"$i")"
	if [ ! -e "$dev" ]; then
		echo "[-] $dev missing, v4l2loopback layout differs"
		cmd_stop
		exit 1
	fi
	ffmpeg -loglevel quiet -f lavfi -i "$pat=size=640x480:rate=15" \
		-pix_fmt yuyv422 -f v4l2 "$dev" &
	i=$((i + 1))
done

echo "[i] opening $COUNT clients as user1..user$COUNT"
i=1
while [ "$i" -le "$COUNT" ]; do
	dev="/dev/video$((BASE_VIDEO + i - 1))"
	niri msg action spawn -- foot --title "toom-user$i" \
		-e sh -c "cd '$TOOM_DIR' && ./toom --join '$CODE' --name user$i -d '$dev'; echo '[toom-user$i] exited, press enter to close'; read"
	echo "[+] toom-user$i joining on $dev"
	i=$((i + 1))
done

echo "[i] stop with: sh test/join_crowd.sh stop"
