package toom

import "base:runtime"
import "core:c"
import "core:strings"
import aideo "../Aideo"
import "core:thread"
import "core:sync"
import "core:time"

app_stop: i32

tx_audio_n: u32
rx_audio_n: u32

app_fps:      int
enc_kbps:     int
enc_prefer:   int
cam_dev:      string
cam_w_req:    int
cam_h_req:    int
audio_enc:    OpusEnc

// PeerRT is the per remote member runtime state.
PeerRT :: struct {
	info:    PeerInfo,
	vdec:    Dec,
	adec:    OpusDec,
	fas:     FragAsm,
	jb:      RingBuf,
	jb_mu:   sync.Mutex,
	engine:  ^aideo.Engine,
	src_w:   int,
	src_h:   int,
	tile:    Tile,
	has_tile: bool,
}

peer_mu:  sync.Mutex
peers:    map[u32]^PeerRT

sess:     Session
cam:      Camera
enc:      H264Enc
local_dec: Dec
self_engine: ^aideo.Engine
self_tile:   Tile
self_w:      int
self_h:      int
cam_ready:   i32
mic_enabled: bool
send_video:  i32
cam_off:     i32
enc_out:     []u8
ybuf:        []u8
ubuf:        []u8
vbuf:        []u8
layout_dirty: i32

engine_new :: proc(src_w, src_h: int, t: Tile) -> ^aideo.Engine {
	cfg: aideo.aideo_config
	cfg.fd = 1
	cfg.src_w = c.int(src_w)
	cfg.src_h = c.int(src_h)
	cfg.out_w = c.int(t.w)
	cfg.out_h = c.int(t.h)
	cfg.colors = c.int(colors_now())
	cfg.origin_row = c.int(t.prow)
	cfg.origin_col = c.int(t.pcol)
	return aideo.aideo_open(&cfg)
}

engine_push :: proc(e: ^aideo.Engine, f: YuvFrame) {
	if e == nil {
		return
	}
	aideo.aideo_push_yuv(e, f.y, f.u, f.v, f.sy, f.sc)
}

// peer_ids_sorted returns the display order: self first, then peers
// by rising id.
peer_ids_sorted :: proc() -> [dynamic]u32 {
	sync.mutex_lock(&peer_mu)
	ids := make([dynamic]u32, 0, len(peers))
	for id in peers {
		append(&ids, id)
	}
	sync.mutex_unlock(&peer_mu)
	for i in 0..<len(ids) {
		for j := i + 1; j < len(ids); j += 1 {
			if ids[j] < ids[i] {
				ids[i], ids[j] = ids[j], ids[i]
			}
		}
	}
	return ids
}

// peer_count returns the number of remote members.
peer_count :: proc() -> int {
	sync.mutex_lock(&peer_mu)
	defer sync.mutex_unlock(&peer_mu)
	return len(peers)
}

// engines_repaint forces every engine to redraw its next frame in
// full, for example after the screen was cleared.
engines_repaint :: proc() {
	if self_engine != nil {
		aideo.aideo_repaint(self_engine)
	}
	sync.mutex_lock(&peer_mu)
	for _, p in peers {
		if p.engine != nil {
			aideo.aideo_repaint(p.engine)
		}
	}
	sync.mutex_unlock(&peer_mu)
}

// colors_apply pushes the selected palette size to every engine.
colors_apply :: proc() {
	colors := c.int(colors_now())
	if self_engine != nil {
		aideo.aideo_set_colors(self_engine, colors)
	}
	sync.mutex_lock(&peer_mu)
	for _, p in peers {
		if p.engine != nil {
			aideo.aideo_set_colors(p.engine, colors)
		}
	}
	sync.mutex_unlock(&peer_mu)
}

// layout_apply recomputes the tiles for the current mode and rebuilds
// every engine whose picture rect moved. The screen is cleared once
// per layout change instead of once per engine.
layout_apply :: proc() {
	ids := peer_ids_sorted()
	defer delete(ids)
	n := 1 + len(ids)
	if conf_focus >= n {
		conf_focus = 0
	}
	tiles: []Tile
	card: Tile
	has_card: bool
	if conf_mode == .Grid {
		tiles, card, has_card = layout_grid(n, self_w, self_h)
	} else {
		tiles = layout_focus(n, conf_focus, self_w, self_h)
	}
	if len(tiles) == 0 {
		sync.atomic_store(&layout_dirty, 0)
		return
	}
	for i in 0..<n {
		src_w, src_h := self_w, self_h
		if i > 0 {
			p := peer_get(ids[i - 1])
			if p != nil && p.src_w > 0 {
				src_w, src_h = p.src_w, p.src_h
			}
		}
		tile_fit(&tiles[i], src_w, src_h)
	}
	moved := len(conf_tiles) != n
	for i in 0..<min(len(conf_tiles), n) {
		a := conf_tiles[i]
		b := tiles[i]
		if a.prow != b.prow || a.pcol != b.pcol || a.w != b.w || a.h != b.h {
			moved = true
		}
	}
	if moved {
		screen_clear()
		if self_engine != nil {
			aideo.aideo_close(self_engine)
			self_engine = nil
		}
		sync.mutex_lock(&peer_mu)
		for _, p in peers {
			if p.engine != nil {
				aideo.aideo_close(p.engine)
				p.engine = nil
			}
		}
		sync.mutex_unlock(&peer_mu)
	}
	self_tile = tiles[0]
	if self_engine == nil {
		self_engine = engine_new(self_w, self_h, self_tile)
	}
	sync.mutex_lock(&peer_mu)
	for id, i in ids {
		p := peers[id]
		if p == nil {
			continue
		}
		p.tile = tiles[i + 1]
		p.has_tile = true
		if p.engine == nil && p.src_w > 0 {
			p.engine = engine_new(p.src_w, p.src_h, p.tile)
		}
	}
	sync.mutex_unlock(&peer_mu)
	delete(conf_tiles)
	conf_tiles = tiles
	conf_card = card
	conf_has_card = has_card
	sync.atomic_store(&layout_dirty, 0)
}

// level_bar renders one audio level as a 4 step bar.
level_bar :: proc(v: int) -> string {
	steps := v * 4 / 32767
	if steps > 4 {
		steps = 4
	}
	chars := [5]string{"    ", "▁   ", "▃▂  ", "▅▄▂ ", "█▇▆▃"}
	return chars[steps]
}

peer_add :: proc(info: PeerInfo) {
	sync.mutex_lock(&peer_mu)
	defer sync.mutex_unlock(&peer_mu)
	if info.id == sess.self_id || peers[info.id] != nil {
		return
	}
	p := new(PeerRT)
	p.info = info
	_ = dec_open(&p.vdec, "h264")
	_ = opus_dec_open(&p.adec)
	ring_init(&p.jb, AUDIO_RATE)
	peers[info.id] = p
	sync.atomic_store(&layout_dirty, 1)
}

peer_remove :: proc(id: u32) {
	sync.mutex_lock(&peer_mu)
	p := peers[id]
	delete_key(&peers, id)
	sync.mutex_unlock(&peer_mu)
	if p == nil {
		return
	}
	if p.engine != nil {
		aideo.aideo_close(p.engine)
	}
	dec_close(&p.vdec)
	opus_dec_close(&p.adec)
	delete(p.jb.data)
	free(p)
	sync.atomic_store(&layout_dirty, 1)
}

peer_get :: proc(id: u32) -> ^PeerRT {
	sync.mutex_lock(&peer_mu)
	defer sync.mutex_unlock(&peer_mu)
	return peers[id]
}

// video_frame routes one decoded remote frame into the peer engine,
// refitting the tile when the source size changes.
video_frame :: proc(p: ^PeerRT, f: YuvFrame) {
	if p.engine == nil || p.src_w != f.w || p.src_h != f.h {
		p.src_w = f.w
		p.src_h = f.h
		if !p.has_tile {
			return
		}
		tile_fit(&p.tile, f.w, f.h)
		if p.engine != nil {
			aideo.aideo_close(p.engine)
		}
		p.engine = engine_new(f.w, f.h, p.tile)
	}
	engine_push(p.engine, f)
}

// audio_block decodes one Opus packet into the peer jitter buffer.
audio_block :: proc(p: ^PeerRT, data: []u8) {
	pcm: [AUDIO_BLOCK]i16
	n := opus_dec_decode(&p.adec, data, pcm[:])
	if n <= 0 {
		return
	}
	sync.mutex_lock(&p.jb_mu)
	ring_write(&p.jb, pcm[:n])
	sync.mutex_unlock(&p.jb_mu)
}

// cam_pipeline_start opens the camera, the conversion buffers and the
// encoder so the meeting can send video. It reports whether the
// pipeline is ready.
cam_pipeline_start :: proc() -> bool {
	if sync.atomic_load(&cam_ready) != 0 {
		return true
	}
	if !cam_start(&cam, cam_dev, cam_w_req, cam_h_req) {
		return false
	}
	self_w = cam.w
	self_h = cam.h
	ybuf = make([]u8, self_w * self_h)
	ubuf = make([]u8, self_w * self_h / 4)
	vbuf = make([]u8, self_w * self_h / 4)
	enc_out = make([]u8, 1 << 20)
	if cam.fmt == CAM_MJPG {
		_ = dec_open(&local_dec, "mjpeg")
	}
	if !h264_enc_open(&enc, self_w, self_h, app_fps, enc_kbps, enc_prefer) {
		cam_stop(&cam)
		return false
	}
	sync.atomic_store(&cam_ready, 1)
	return true
}

capture_thread :: proc() {
	interval := time.Duration(i64(time.Second) / i64(max(app_fps, 1)))
	last: time.Time
	first := true
	seq: u32
	for sync.atomic_load(&app_stop) == 0 {
		if sync.atomic_load(&cam_ready) == 0 {
			time.sleep(50 * time.Millisecond)
			continue
		}
		data, ok := cam_grab(&cam, 200)
		if !ok {
			continue
		}
		now := time.now()
		due := first || time.since(last) >= interval
		if !due {
			cam_ungrab(&cam)
			continue
		}
		first = false
		last = now
		f := YuvFrame{}
		if cam.fmt == CAM_MJPG {
			f, _ = dec_feed(&local_dec, data)
		} else {
			yuyv_to_i420(data, cam.w, cam.h, ybuf, ubuf, vbuf)
			f = YuvFrame{
				y = raw_data(ybuf), u = raw_data(ubuf), v = raw_data(vbuf),
				sy = c.int(cam.w), sc = c.int(cam.w / 2), w = cam.w, h = cam.h,
			}
		}
		if f.w > 0 && sync.atomic_load(&cam_off) == 0 {
			engine_push(self_engine, f)
		}
		if f.w > 0 {
			if sync.atomic_load(&send_video) != 0 {
				n, key := h264_enc_encode(&enc, f, enc_out)
				if n > 0 {
					flags := u8(0)
					if key {
						flags = MEDIA_FLAG_KEY
					}
					seq += 1
					sess_send_frame(&sess, MEDIA_STREAM_VIDEO, flags, seq, ms_now(), enc_out[:n])
				}
			}
		}
		cam_ungrab(&cam)
	}
}

audio_tx_thread :: proc() {
	pcm: [AUDIO_BLOCK]i16
	out: [1200]u8
	seq: u32
	for sync.atomic_load(&app_stop) == 0 {
		time.sleep(5 * time.Millisecond)
		if !audio_ok || audio_capture_fill() < AUDIO_BLOCK {
			continue
		}
		audio_capture_pop(pcm[:])
		if sync.atomic_load(&mic_mute) != 0 {
			continue
		}
		peak := 0
		for i in 0..<AUDIO_BLOCK {
			v := int(pcm[i])
			if v < 0 {
				v = -v
			}
			if v > peak {
				peak = v
			}
		}
		level_store(&mic_level, peak)
		audio_monitor_push(pcm[:])
		n := opus_enc_encode(&audio_enc, pcm[:], out[:])
		if n > 0 {
			seq += 1
			sess_send_frame(&sess, MEDIA_STREAM_AUDIO, 0, seq, ms_now(), out[:n])
			sync.atomic_store(&tx_audio_n, sync.atomic_load(&tx_audio_n) + 1)
		}
	}
}

mix_thread :: proc() {
	mix := make([]i16, AUDIO_BLOCK)
	tmp := make([]i16, AUDIO_BLOCK)
	defer delete(mix)
	defer delete(tmp)
	keep := 0
	for sync.atomic_load(&app_stop) == 0 {
		time.sleep(20 * time.Millisecond)
		keep += 1
		if keep >= 100 {
			keep = 0
			sess_keepalive(&sess)
		}
		for i in 0..<len(mix) {
			mix[i] = 0
		}
		list: [dynamic]^PeerRT
		sync.mutex_lock(&peer_mu)
		for _, p in peers {
			append(&list, p)
		}
		sync.mutex_unlock(&peer_mu)
		for p in list {
			sync.mutex_lock(&p.jb_mu)
			n := ring_read(&p.jb, tmp[:])
			sync.mutex_unlock(&p.jb_mu)
			for i in 0..<n {
				mix[i] += tmp[i]
			}
		}
		delete(list)
		mn := audio_monitor_pop(tmp[:])
		for i in 0..<mn {
			mix[i] += tmp[i]
		}
		for i in 0..<len(mix) {
			if mix[i] > AUDIO_MIX_MAX {
				mix[i] = AUDIO_MIX_MAX
			} else if mix[i] < -32768 {
				mix[i] = -32768
			}
		}
		peak := 0
		for i in 0..<len(mix) {
			v := int(mix[i])
			if v < 0 {
				v = -v
			}
			if v > peak {
				peak = v
			}
		}
		level_store(&rx_level, peak)
		audio_play_push(mix)
	}
}

rx_thread :: proc() {
	buf := make([]u8, 2048)
	defer delete(buf)
	addr: SockAddr
	for sync.atomic_load(&app_stop) == 0 {
		n := net_recv(sess.fd, buf[:], &addr)
		if n <= 0 {
			continue
		}
		env, ok := env_unmarshal(buf[:n])
		if !ok {
			continue
		}
		switch env.typ {
		case MSG_MEMBER_JOIN:
			m: MemberJoinMsg
			if json_unmarshal(env.body, &m) {
				peer_add(PeerInfo{id = m.ID, name = m.Name, cam = m.Cam, mic = m.Mic})
			}
		case MSG_MEMBER_LEAVE:
			m: MemberLeaveMsg
			if json_unmarshal(env.body, &m) {
				peer_remove(m.ID)
			}
		case MSG_MEMBER_UPDATE:
			m: MemberUpdateMsg
			if json_unmarshal(env.body, &m) {
				p := peer_get(m.ID)
				if p != nil {
					p.info.cam = m.Cam
					p.info.mic = m.Mic
				}
			}
		case MSG_MEDIA:
			route_media(env.body)
		}
	}
}

// route_media decrypts one media datagram and feeds reassembly.
route_media :: proc(blob: []u8) {
	plain := open(sess.media_key[:], blob)
	if plain == nil {
		return
	}
	h, payload, ok := media_unpack(plain)
	if !ok {
		delete(plain)
		return
	}
	p := peer_get(h.src)
	if p == nil {
		delete(plain)
		return
	}
	frame, done := frag_feed(&p.fas, h, payload)
	if done {
		if h.stream == MEDIA_STREAM_VIDEO {
			f, ok2 := dec_feed(&p.vdec, frame)
			if ok2 {
				video_frame(p, f)
			}
		} else {
			sync.atomic_store(&rx_audio_n, sync.atomic_load(&rx_audio_n) + 1)
			audio_block(p, frame)
		}
	}
	delete(plain)
}

ms_now :: proc() -> u32 {
	return u32(i64(time.since(epoch)) / 1_000_000)
}

epoch: time.Time

// conf_key applies one meeting key. It returns true when the user
// confirmed the quit.
conf_key :: proc(k: Key) -> bool {
	quit_key := k.kind == .Quit || (k.kind == .Char && (k.ch == 'q' || k.ch == 'Q'))
	if quit_key {
		if quit_armed() {
			return true
		}
		quit_on = true
		quit_at = time.now()
		return false
	}
	quit_on = false
	#partial switch k.kind {
	case .Up:
		audio_vol_add(0.1)
	case .Down:
		audio_vol_add(-0.1)
	case .Tab, .Left, .Right:
		dir := 1
		if k.kind == .Left {
			dir = -1
		}
		n := 1 + peer_count()
		conf_focus = ((conf_focus + dir) % n + n) % n
		if conf_mode == .Focus {
			layout_apply()
		}
	case .FocusIn:
		engines_repaint()
	case .Char:
		switch k.ch {
		case 'm', 'M':
			audio_toggle_spk()
		case 'n', 'N':
			audio_toggle_mic()
			sess_update(&sess, sync.atomic_load(&send_video) != 0, sync.atomic_load(&mic_mute) == 0)
		case 'c', 'C':
			if sync.atomic_load(&cam_ready) != 0 {
				off := 1 - sync.atomic_load(&cam_off)
				sync.atomic_store(&cam_off, off)
				sync.atomic_store(&send_video, 1 - off)
				if off == 1 {
					screen_clear()
					engines_repaint()
				}
			} else if cam_pipeline_start() {
				sync.atomic_store(&cam_off, 0)
				sync.atomic_store(&send_video, 1)
				if self_engine != nil {
					aideo.aideo_close(self_engine)
					self_engine = nil
				}
				layout_apply()
			}
			sess_update(&sess, sync.atomic_load(&send_video) != 0, sync.atomic_load(&mic_mute) == 0)
		case 'f', 'F':
			if conf_mode == .Grid {
				conf_mode = .Focus
			} else {
				conf_mode = .Grid
			}
			layout_apply()
		case 'j', 'J':
			if color_idx > 0 {
				color_idx -= 1
				colors_apply()
			}
		case 'k', 'K':
			if color_idx < len(CONF_COLORS) - 1 {
				color_idx += 1
				colors_apply()
			}
		case '?':
			help_open = true
			help_draw()
		}
	}
	return false
}

// conference_run drives one call from join to hangup. It returns an
// empty string on a clean exit or the failure reason.
conference_run :: proc(server, room, name, secret: string, create, cam_on, mic_on: bool) -> string {
	fd := net_open()
	if fd < 0 {
		return "Socket create failed"
	}
	defer sock_close(c.int(fd))

	host, port_val, ok := parse_hostport(server)
	if !ok {
		return "Server address must be host:port"
	}
	srv, sok := net_addr(host, u16(port_val))
	if !sok {
		return "Invalid server address"
	}

	sess_init(&sess, fd, srv, room, name, bytes_of(secret))
	if create {
		sess_create_room(&sess)
	}
	joined, jerr := sess_join(&sess)
	if !joined {
		return jerr
	}
	sync.mutex_lock(&sess.peer_mu)
	for _, info in sess.peers {
		peer_add(info)
	}
	sync.mutex_unlock(&sess.peer_mu)

	self_w = cam_w_req
	self_h = cam_h_req
	sync.atomic_store(&cam_ready, 0)
	sync.atomic_store(&cam_off, 1)
	sync.atomic_store(&send_video, 0)
	sync.atomic_store(&tx_audio_n, 0)
	sync.atomic_store(&rx_audio_n, 0)
	if cam_on && cam_pipeline_start() {
		sync.atomic_store(&cam_off, 0)
		sync.atomic_store(&send_video, 1)
	}
	if audio_start() && opus_enc_open(&audio_enc, 24000) {
		mic_enabled = true
	} else {
		mic_enabled = false
	}
	if mic_on {
		sync.atomic_store(&mic_mute, 0)
	} else {
		sync.atomic_store(&mic_mute, 1)
	}
	sess_update(&sess, sync.atomic_load(&send_video) != 0, sync.atomic_load(&mic_mute) == 0)

	screen_clear()
	self_engine = nil
	self_tile = Tile{}
	conf_focus = 0
	if conf_code_tail != "" {
		delete(conf_code_tail)
	}
	code := meeting_encode(server, room, secret)
	conf_code_tail = strings.clone(code[len(code) - 4:])
	delete(code)
	layout_apply()

	t_atx: ^thread.Thread
	t_rx := thread.create_and_start(rx_thread)
	t_mix := thread.create_and_start(mix_thread)
	t_cap := thread.create_and_start(capture_thread)
	if mic_enabled {
		t_atx = thread.create_and_start(audio_tx_thread)
	}

	last_ui: time.Time
	for sync.atomic_load(&app_stop) == 0 {
		tmp := runtime.default_temp_allocator_temp_begin()
		defer runtime.default_temp_allocator_temp_end(tmp)
		k := key_next()
		if k.kind != .None {
			if help_open {
				help_open = false
				screen_clear()
				engines_repaint()
				continue
			}
			if conf_key(k) {
				sync.atomic_store(&app_stop, 1)
			}
		}
		if term_take_winch() {
			if help_open {
				help_draw()
			} else {
				sync.atomic_store(&layout_dirty, 1)
			}
		}
		if sync.atomic_load(&layout_dirty) != 0 {
			layout_apply()
		}
		if !help_open && time.since(last_ui) >= 200 * time.Millisecond {
			last_ui = time.now()
			backend := "no cam"
			if sync.atomic_load(&cam_ready) != 0 {
				backend = h264_enc_backend(&enc)
			}
			conf_draw(backend)
		}
	}

	sync.atomic_store(&app_stop, 1)
	sess_bye(&sess)
	thread.join(t_rx)
	thread.join(t_mix)
	if t_cap != nil {
		thread.join(t_cap)
	}
	if t_atx != nil {
		thread.join(t_atx)
	}
	sync.mutex_lock(&peer_mu)
	ids := make([dynamic]u32, 0, len(peers))
	for id in peers {
		append(&ids, id)
	}
	sync.mutex_unlock(&peer_mu)
	for id in ids {
		peer_remove(id)
	}
	delete(conf_tiles)
	conf_tiles = nil
	conf_has_card = false
	quit_on = false
	help_open = false
	if self_engine != nil {
		aideo.aideo_close(self_engine)
		self_engine = nil
	}
	cam_stop(&cam)
	audio_stop()
	h264_enc_close(&enc)
	dec_close(&local_dec)
	opus_enc_close(&audio_enc)
	delete(ybuf)
	delete(ubuf)
	delete(vbuf)
	delete(enc_out)
	ybuf = nil
	ubuf = nil
	vbuf = nil
	enc_out = nil
	sync.atomic_store(&app_stop, 0)
	return ""
}

parse_port :: proc(s: string) -> (int, bool) {
	v := 0
	if len(s) == 0 {
		return 0, false
	}
	for r in s {
		if r < '0' || r > '9' {
			return 0, false
		}
		v = v * 10 + int(r - '0')
	}
	if v < 1 || v > 65535 {
		return 0, false
	}
	return v, true
}
