#!/bin/sh
# build-in-container.sh builds toom in a vanilla Arch container so the
# glibc startup objects carry no raised ISA level. The host odin is
# mounted read-only, everything else comes from the container.
set -e
podman build -t toom-build -f Containerfile .
podman run --rm \
	-v "$PWD":/src \
	-v /usr/sbin/odin:/usr/sbin/odin:ro \
	-v /usr/lib/odin:/usr/lib/odin:ro \
	toom-build sh -c "cd /src && sh build.sh"
