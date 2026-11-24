#!/usr/bin/env sh
# Builds the TOOM client dependencies and binary. The FFmpeg build is
# a superset of Aideo's build_ffstatic.sh (libaideo.a links against it)
# plus the encode side: libx264, h264_nvenc, h264_vaapi and libopus.
set -e
TOOM_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$TOOM_DIR"

FFMPEG_SRC="${FFMPEG_SRC:-/tmp/ffmpeg-src}"
ZLIB_SRC="${ZLIB_SRC:-/tmp/zlib-src}"
DAV1D_SRC="${DAV1D_SRC:-/tmp/dav1d-src}"
X264_SRC="${X264_SRC:-/tmp/x264-src}"
OPUS_SRC="${OPUS_SRC:-/tmp/opus-src}"
OPUS_BUILD="${OPUS_BUILD:-/tmp/opus-build}"
WEBRTC_SRC="${WEBRTC_SRC:-/home/zy/zy/TEST/Apps/CLI/webrtc-audio-processing}"
WEBRTC_BUILD="${WEBRTC_BUILD:-/tmp/webrtc-build}"
WEBRTC_INST="${WEBRTC_INST:-/tmp/webrtc-inst}"
FFNV_SRC="${FFNV_SRC:-/tmp/ffnvcodec-src}"
FFNV_INST="${FFNV_INST:-/tmp/ffnvcodec-inst}"
JOBS="${JOBS:-$(nproc)}"

mkdir -p ffstatic

if [ ! -f "$ZLIB_SRC/configure" ]; then
	echo "[i] cloning zlib"
	rm -rf "$ZLIB_SRC"
	git clone --depth 1 https://github.com/madler/zlib.git "$ZLIB_SRC"
fi
if [ ! -f "$ZLIB_SRC/libz.a" ]; then
	echo "[i] building zlib"
	(cd "$ZLIB_SRC" && ./configure --static >/dev/null && make -j"$JOBS" >/dev/null)
fi
cp "$ZLIB_SRC/libz.a" ffstatic/

if [ ! -f "$DAV1D_SRC/meson.build" ]; then
	echo "[i] cloning dav1d"
	rm -rf "$DAV1D_SRC"
	git clone --depth 1 https://code.videolan.org/videolan/dav1d.git "$DAV1D_SRC"
fi
if [ ! -f "$DAV1D_SRC/build/src/libdav1d.a" ]; then
	echo "[i] building dav1d"
	meson setup "$DAV1D_SRC/build" "$DAV1D_SRC" \
		--default-library=static --buildtype=release \
		-Denable_tools=false -Denable_tests=false >/dev/null
	ninja -C "$DAV1D_SRC/build" >/dev/null
fi
cp "$DAV1D_SRC/build/src/libdav1d.a" ffstatic/

if [ ! -f "$X264_SRC/configure" ]; then
	echo "[i] cloning x264"
	rm -rf "$X264_SRC"
	git clone --depth 1 https://code.videolan.org/videolan/x264.git "$X264_SRC"
fi
if [ ! -f "$X264_SRC/libx264.a" ]; then
	echo "[i] building x264"
	(cd "$X264_SRC" && ./configure --enable-static --disable-cli >/dev/null && make -j"$JOBS" >/dev/null)
fi
cp "$X264_SRC/libx264.a" ffstatic/

if [ ! -f "$OPUS_SRC/CMakeLists.txt" ]; then
	echo "[i] cloning libopus"
	rm -rf "$OPUS_SRC"
	git clone --depth 1 https://github.com/xiph/opus.git "$OPUS_SRC"
fi
if [ ! -f "$OPUS_BUILD/libopus.a" ]; then
	echo "[i] building libopus"
	rm -rf "$OPUS_BUILD"
	cmake -S "$OPUS_SRC" -B "$OPUS_BUILD" \
		-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
		-DOPUS_BUILD_PROGRAMS=OFF >/dev/null
	cmake --build "$OPUS_BUILD" -j"$JOBS" >/dev/null
fi
cp "$OPUS_BUILD/libopus.a" ffstatic/

if [ ! -f "$FFNV_SRC/Makefile" ]; then
	echo "[i] cloning nv-codec-headers"
	rm -rf "$FFNV_SRC"
	git clone --depth 1 https://github.com/FFmpeg/nv-codec-headers.git "$FFNV_SRC"
fi
make -C "$FFNV_SRC" install PREFIX="$FFNV_INST" >/dev/null

if [ ! -f "$FFMPEG_SRC/configure" ]; then
	echo "[i] cloning FFmpeg"
	rm -rf "$FFMPEG_SRC"
	git clone --depth 1 https://github.com/FFmpeg/FFmpeg.git "$FFMPEG_SRC"
fi

echo "[i] building FFmpeg (player superset + encoders)"
(
	cd "$FFMPEG_SRC"
	PKG_CONFIG_PATH="$FFNV_INST/lib/pkgconfig:$PKG_CONFIG_PATH" ./configure \
		--prefix=/opt/toom-ff \
		--disable-shared --enable-static \
		--disable-debug --disable-doc --disable-programs \
		--enable-small --disable-autodetect --disable-everything \
		--enable-avformat --enable-avcodec --enable-swresample --enable-swscale --enable-avutil \
		--enable-protocol=file,pipe \
		--enable-demuxer=mov,matroska,avi,mpegts,ogg,wav,flac,mp3,flv \
		--enable-demuxer=image_png_pipe,image_jpeg_pipe,image_webp_pipe,image_bmp_pipe,image_tiff_pipe,gif,apng,webp_anim \
		--enable-decoder=h264,hevc,vp8,vp9,libdav1d,aac,mp3,flac,opus,vorbis,ac3,eac3,pcm_s16le,pcm_s24le,pcm_f32le \
		--enable-decoder=png,mjpeg,webp,bmp,gif,tiff,apng,webp_anim \
		--enable-parser=h264,hevc,vp8,vp9,av1,aac,mpegaudio,flac,opus,vorbis,ac3 \
		--enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,extract_extradata \
		--enable-zlib \
		--enable-libdav1d \
		--enable-gpl \
		--enable-encoder=libx264,h264_nvenc,h264_vaapi,libopus \
		--enable-libx264 --enable-libopus \
		--enable-vaapi --enable-ffnvcodec \
		--enable-hwaccel=h264_vaapi
	make -j"$JOBS" >/dev/null
	cp libavformat/libavformat.a libavcodec/libavcodec.a libswscale/libswscale.a \
		libswresample/libswresample.a libavutil/libavutil.a "$TOOM_DIR/ffstatic/"
)

echo "[i] building aideo artifacts"
cc -O2 -mavx2 -c aideo/avx2_quant.c -o aideo/avx2_quant.o
cc -O2 -c aideo/miniaudio/ma_impl.c -o aideo/miniaudio/ma_impl.o
ar rcs aideo/miniaudio/libminiaudio.a aideo/miniaudio/ma_impl.o

echo "[i] building encoder shim"
cc -O2 -I"$FFMPEG_SRC" -c h264enc.c -o h264enc.o

echo "[i] building compat shim"
cc -O2 -fno-builtin -c compat_shim.c -o compat_shim.o

echo "[i] building va shim"
cc -O2 -c va_shim.c -o va_shim.o

echo "[i] building webrtc-audio-processing (static)"
if ! find "$WEBRTC_INST/lib" -name 'libwebrtc-audio-processing-*.a' 2>/dev/null | grep -q .; then
	rm -rf "$WEBRTC_BUILD" "$WEBRTC_INST"
	meson setup "$WEBRTC_BUILD" "$WEBRTC_SRC" \
		--default-library=static --buildtype=release \
		--prefix="$WEBRTC_INST" --wrap-mode=forcefallback >/dev/null
	ninja -C "$WEBRTC_BUILD" >/dev/null
	meson install -C "$WEBRTC_BUILD" >/dev/null
fi
rm -f ffstatic/libwebrtc_all.a
{
	echo "CREATE $TOOM_DIR/ffstatic/libwebrtc_all.a"
	find "$WEBRTC_INST/lib" -name 'libwebrtc-audio-processing-*.a' | while read -r a; do
		echo "ADDLIB $a"
	done
	find "$WEBRTC_BUILD/subprojects" -name 'libabsl_*.a' | sort | while read -r a; do
		echo "ADDLIB $a"
	done
	echo "SAVE"
	echo "END"
} | ar -M

echo "[i] staging static C++ runtime"
cp "$(cc -print-file-name=libstdc++.a)" ffstatic/libstdc++.a
cp "$(cc -print-file-name=libgcc.a)" ffstatic/libgcc.a

echo "[i] building aec shim"
PKG_CONFIG_PATH="$WEBRTC_INST/lib/pkgconfig" c++ -O2 -std=c++17 \
	$(PKG_CONFIG_PATH="$WEBRTC_INST/lib/pkgconfig" pkg-config --cflags webrtc-audio-processing-2) \
	-I"$WEBRTC_INST/include" -c aec_shim.cc -o aec_shim.o

echo "[i] generating screencopy protocol"
wayland-scanner client-header proto/wlr-screencopy-unstable-v1.xml proto/screencopy-client-protocol.h
wayland-scanner private-code proto/wlr-screencopy-unstable-v1.xml proto/screencopy-protocol.c
cc -O2 -c proto/screencopy-protocol.c -o proto/screencopy-protocol.o

echo "[i] building screen capture shim"
cc -O2 -c wlshim.c -o wlshim.o
cc -O2 -Iproto -c screen_shim.c -o screen_shim.o

echo "[i] building TOOM client"
odin build . -o:speed -out:toom -extra-linker-flags:"-static-libstdc++ -static-libgcc -Wl,--allow-multiple-definition"

echo "[+] build complete"
