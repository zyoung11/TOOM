package toom

import "core:c"

PIX_FMT_YUV420P  :: 0
PIX_FMT_YUYV422  :: 1
PIX_FMT_YUVJ420P :: 12
PIX_FMT_BGRA     :: 29

YuvFrame :: struct {
	y, u, v: [^]u8,
	sy, sc:  c.int,
	w, h:    int,
}

// H264Enc wraps the encoder shim with its backend probe.
H264Enc :: struct {
	handle: rawptr,
}

h264_enc_open :: proc(enc: ^H264Enc, w, h, fps, kbps, prefer: int) -> bool {
	enc.handle = h264enc_open(c.int(w), c.int(h), c.int(fps), c.int(kbps), c.int(prefer))
	return enc.handle != nil
}

h264_enc_backend :: proc(enc: ^H264Enc) -> string {
	if enc.handle == nil {
		return "none"
	}
	return string(cstring(h264enc_backend(enc.handle)))
}

h264_enc_encode :: proc(enc: ^H264Enc, f: YuvFrame, out: []u8) -> (int, bool) {
	key: c.int = 0
	n := h264enc_encode(enc.handle, f.y, f.u, f.v, f.sy, f.sc, raw_data(out), c.int(len(out)), &key)
	if n <= 0 {
		return 0, false
	}
	return int(n), key != 0
}

h264_enc_close :: proc(enc: ^H264Enc) {
	if enc.handle != nil {
		h264enc_close(enc.handle)
		enc.handle = nil
	}
}

// Dec decodes one compressed video stream into YUV420P planes. Non
// 4:2:0 frames go through swscale, which libaideo also links.
Dec :: struct {
	ctx:     rawptr,
	pkt:     ^AVPacket,
	frame:   ^AVFrame,
	sws:     rawptr,
	sws_fmt: c.int,
	sws_w:   c.int,
	sws_h:   c.int,
	y:       []u8,
	u:       []u8,
	v:       []u8,
}

dec_open :: proc(d: ^Dec, name: string) -> bool {
	buf: [16]u8
	n := min(len(name), len(buf) - 1)
	copy(buf[:], name[:n])
	buf[n] = 0
	codec := avcodec_find_decoder_by_name(cast(cstring)&buf[0])
	if codec == nil {
		return false
	}
	d.ctx = avcodec_alloc_context3(codec)
	d.pkt = av_packet_alloc()
	d.frame = av_frame_alloc()
	if d.ctx == nil || d.pkt == nil || d.frame == nil {
		return false
	}
	if avcodec_open2(d.ctx, codec, nil) != 0 {
		return false
	}
	return true
}

// dec_feed sends one access unit and returns the decoded frame. The
// planes stay valid until the next dec_feed or dec_close call.
dec_feed :: proc(d: ^Dec, data: []u8) -> (YuvFrame, bool) {
	if d.ctx == nil {
		return {}, false
	}
	av_frame_unref(d.frame)
	d.pkt.data = raw_data(data)
	d.pkt.size = c.int(len(data))
	if avcodec_send_packet(d.ctx, d.pkt) != 0 {
		av_packet_unref(d.pkt)
		return {}, false
	}
	av_packet_unref(d.pkt)
	if avcodec_receive_frame(d.ctx, d.frame) != 0 {
		return {}, false
	}
	w := int(d.frame.width)
	h := int(d.frame.height)
	if w <= 0 || h <= 0 {
		return {}, false
	}
	fmt := d.frame.format
	if fmt == PIX_FMT_YUV420P || fmt == PIX_FMT_YUVJ420P {
		return YuvFrame{
			y = d.frame.data[0], u = d.frame.data[1], v = d.frame.data[2],
			sy = d.frame.linesize[0], sc = d.frame.linesize[1],
			w = w, h = h,
		}, true
	}
	if d.sws == nil || d.sws_fmt != fmt || d.sws_w != c.int(w) || d.sws_h != c.int(h) {
		if d.sws != nil {
			sws_freeContext(d.sws)
			d.sws = nil
		}
		d.sws = sws_getContext(c.int(w), c.int(h), fmt, c.int(w), c.int(h), PIX_FMT_YUV420P, 1, nil, nil, nil)
		d.sws_fmt = fmt
		d.sws_w = c.int(w)
		d.sws_h = c.int(h)
		delete(d.y)
		delete(d.u)
		delete(d.v)
		d.y = make([]u8, w * h)
		d.u = make([]u8, w * h / 4)
		d.v = make([]u8, w * h / 4)
	}
	if d.sws == nil {
		return {}, false
	}
	dst_data: [4][^]u8
	dst_stride: [4]c.int
	dst_data[0] = raw_data(d.y)
	dst_data[1] = raw_data(d.u)
	dst_data[2] = raw_data(d.v)
	dst_stride[0] = c.int(w)
	dst_stride[1] = c.int(w / 2)
	dst_stride[2] = c.int(w / 2)
	sws_scale(d.sws, &d.frame.data, &d.frame.linesize, 0, c.int(h), &dst_data, &dst_stride)
	return YuvFrame{
		y = dst_data[0], u = dst_data[1], v = dst_data[2],
		sy = dst_stride[0], sc = dst_stride[1],
		w = w, h = h,
	}, true
}

dec_close :: proc(d: ^Dec) {
	if d.ctx != nil {
		avcodec_free_context(&d.ctx)
	}
	if d.pkt != nil {
		av_packet_free(&d.pkt)
	}
	if d.frame != nil {
		av_frame_free(&d.frame)
	}
	if d.sws != nil {
		sws_freeContext(d.sws)
		d.sws = nil
	}
	delete(d.y)
	delete(d.u)
	delete(d.v)
	d^ = {}
}

// yuv_flip_h mirrors one YUV420P frame horizontally into the dst
// planes and returns the flipped frame.
yuv_flip_h :: proc(f: YuvFrame, dst_y, dst_u, dst_v: []u8) -> YuvFrame {
	w := f.w
	h := f.h
	for row in 0..<h {
		src := int(f.sy) * row
		dst := w * row
		for x in 0..<w {
			dst_y[dst + x] = f.y[src + w - 1 - x]
		}
	}
	hw := w / 2
	hh := h / 2
	for row in 0..<hh {
		src := int(f.sc) * row
		dst := hw * row
		for x in 0..<hw {
			dst_u[dst + x] = f.u[src + hw - 1 - x]
			dst_v[dst + x] = f.v[src + hw - 1 - x]
		}
	}
	return YuvFrame{
		y = raw_data(dst_y), u = raw_data(dst_u), v = raw_data(dst_v),
		sy = c.int(w), sc = c.int(hw), w = w, h = h,
	}
}

// yuyv_to_i420 converts one packed YUYV frame into I420 planes with
// 2x2 chroma subsampling.
yuyv_to_i420 :: proc(src: []u8, w, h: int, y, u, v: []u8) {
	hw := w / 2
	for row in 0..<h {
		line := row * w * 2
		yo := row * w
		uo := (row / 2) * hw
		for x in 0..<hw {
			y[yo + x * 2] = src[line + x * 4]
			y[yo + x * 2 + 1] = src[line + x * 4 + 2]
			if row & 1 == 0 {
				u[uo + x] = src[line + x * 4 + 1]
				v[uo + x] = src[line + x * 4 + 3]
			}
		}
	}
}

// OpusEnc encodes PCM at 48 kHz in one or two channels.
OpusEnc :: struct {
	handle: rawptr,
	ch:     int,
}

opus_enc_open :: proc(e: ^OpusEnc, kbps, channels: int) -> bool {
	err: c.int = 0
	e.handle = opus_encoder_create(48000, c.int(channels), OPUS_APPLICATION_VOIP, &err)
	if e.handle == nil || err != 0 {
		return false
	}
	e.ch = max(channels, 1)
	rate := c.int(kbps)
	opus_encoder_ctl(e.handle, OPUS_SET_BITRATE, &rate)
	return true
}

opus_enc_encode :: proc(e: ^OpusEnc, pcm: []i16, out: []u8) -> int {
	return int(opus_encode(e.handle, raw_data(pcm), c.int(len(pcm) / e.ch), raw_data(out), c.int(len(out))))
}

opus_enc_close :: proc(e: ^OpusEnc) {
	if e.handle != nil {
		opus_encoder_destroy(e.handle)
		e.handle = nil
	}
}

// OpusDec decodes PCM at 48 kHz in one or two channels and performs
// packet loss concealment when fed a nil packet.
OpusDec :: struct {
	handle: rawptr,
	ch:     int,
}

opus_dec_open :: proc(d: ^OpusDec, channels: int) -> bool {
	err: c.int = 0
	d.handle = opus_decoder_create(48000, c.int(channels), &err)
	d.ch = max(channels, 1)
	return d.handle != nil && err == 0
}

opus_dec_decode :: proc(d: ^OpusDec, data: []u8, pcm: []i16) -> int {
	cap := c.int(len(pcm) / d.ch)
	if len(data) == 0 {
		return int(opus_decode(d.handle, nil, 0, raw_data(pcm), cap, 0)) * d.ch
	}
	return int(opus_decode(d.handle, raw_data(data), c.int(len(data)), raw_data(pcm), cap, 0)) * d.ch
}

opus_dec_close :: proc(d: ^OpusDec) {
	if d.handle != nil {
		opus_decoder_destroy(d.handle)
		d.handle = nil
	}
}
