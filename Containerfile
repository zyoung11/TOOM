FROM archlinux:base-devel

RUN pacman -Syu --noconfirm cmake meson ninja nasm pkg-config git python

WORKDIR /src
