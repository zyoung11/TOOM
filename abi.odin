package toom

import "core:c"

foreign import toomlibs {
	"h264enc.o",
	"aec_shim.o",
	"wlshim.o",
	"screen_shim.o",
	"proto/screencopy-protocol.o",
	"ffstatic/libavcodec.a",
	"ffstatic/libavformat.a",
	"ffstatic/libswscale.a",
	"ffstatic/libswresample.a",
	"ffstatic/libavutil.a",
	"ffstatic/libdav1d.a",
	"ffstatic/libz.a",
	"ffstatic/libx264.a",
	"ffstatic/libopus.a",
	"system:va",
	"system:va-drm",
	"system:drm",
	"system:webrtc-audio-processing-1",
	"system:stdc++",
	"system:m",
	"system:pthread",
	"system:dl",
}

AVRational :: struct {
	num, den: c.int,
}

AVPacket :: struct {
	buf:          rawptr,
	pts:          i64,
	dts:          i64,
	data:         [^]u8,
	size:         c.int,
	stream_index: c.int,
	flags:        c.int,
}

AVFrame :: struct {
	data:                [8][^]u8,
	linesize:            [8]c.int,
	extended_data:       [^][^]u8,
	width:               c.int,
	height:              c.int,
	nb_samples:          c.int,
	format:              c.int,
	pict_type:           i32,
	sample_aspect_ratio: AVRational,
	pts:                 i64,
	pkt_dts:             i64,
}

foreign toomlibs {
	h264enc_open :: proc(w, h, fps, kbps, prefer: c.int) -> rawptr ---
	h264enc_backend :: proc(e: rawptr) -> cstring ---
	h264enc_encode :: proc(e: rawptr, y, u, v: [^]u8, sy, sc: c.int, out: [^]u8, cap: c.int, keyframe: ^c.int) -> c.int ---
	h264enc_close :: proc(e: rawptr) ---

	avcodec_find_decoder_by_name :: proc(name: cstring) -> rawptr ---
	avcodec_alloc_context3 :: proc(codec: rawptr) -> rawptr ---
	avcodec_open2 :: proc(ctx, codec, opts: rawptr) -> c.int ---
	avcodec_send_packet :: proc(ctx: rawptr, pkt: ^AVPacket) -> c.int ---
	avcodec_receive_frame :: proc(ctx: rawptr, frame: ^AVFrame) -> c.int ---
	avcodec_free_context :: proc(ctx: ^rawptr) ---
	av_packet_alloc :: proc() -> ^AVPacket ---
	av_packet_free :: proc(p: ^^AVPacket) ---
	av_packet_unref :: proc(p: ^AVPacket) ---
	av_frame_alloc :: proc() -> ^AVFrame ---
	av_frame_free :: proc(f: ^^AVFrame) ---
	av_frame_unref :: proc(f: ^AVFrame) ---
	av_log_set_level :: proc(level: c.int) ---

	sws_getContext :: proc(srcW, srcH, srcFmt, dstW, dstH, dstFmt, flags: c.int, srcFilter, dstFilter, param: rawptr) -> rawptr ---
	sws_scale :: proc(swc: rawptr, srcData, srcSlice: rawptr, srcSliceY, srcSliceH: c.int, dstData, dstStride: rawptr) -> c.int ---
	sws_freeContext :: proc(swc: rawptr) ---

	opus_encoder_create :: proc(fs, ch, app: c.int, err: ^c.int) -> rawptr ---
	opus_encode :: proc(enc: rawptr, pcm: [^]i16, frames: c.int, out: [^]u8, cap: c.int) -> c.int ---
	opus_encoder_ctl :: proc(enc: rawptr, req: c.int, arg: rawptr) -> c.int ---
	opus_encoder_destroy :: proc(enc: rawptr) ---
	opus_decoder_create :: proc(fs, ch: c.int, err: ^c.int) -> rawptr ---
	opus_decode :: proc(dec: rawptr, data: [^]u8, len: c.int, pcm: [^]i16, frames: c.int, fec: c.int) -> c.int ---
	opus_decoder_destroy :: proc(dec: rawptr) ---

	toom_aec_open :: proc(rate, cap_ch, play_ch: c.int) -> rawptr ---
	toom_aec_close :: proc(p: rawptr) ---
	toom_aec_play :: proc(p: rawptr, data: [^]i16, frames: c.int) ---
	toom_aec_cap :: proc(p: rawptr, data: [^]i16, frames: c.int) ---

	toom_screen_open :: proc(output_index: c.int) -> rawptr ---
	toom_screen_open_ex :: proc(name, region: cstring, cursor: c.int) -> rawptr ---
	toom_screen_list :: proc(buf: [^]u8, cap: c.int) -> c.int ---
	toom_screen_poll :: proc(p: rawptr, timeout_ms: c.int) -> c.int ---
	toom_screen_frame :: proc(p: rawptr, w, h, stride, y_invert: ^c.int) -> [^]u8 ---
	toom_screen_close :: proc(p: rawptr) ---
}

OPUS_APPLICATION_VOIP :: 2048
OPUS_SET_BITRATE     :: 4002
