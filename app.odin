package toom

import "base:runtime"
import "core:c"
import "core:os"
import "core:strings"
import "core:thread"
import "core:sync"
import "core:time"

app_stop: i32

// force_key_video and force_key_screen request one IDR frame so
// members who just joined start decoding at once.
force_key_video:  i32
force_key_screen: i32

tx_media_n: u32
rx_media_n: u32

app_fps:      int
enc_kbps:     int
enc_prefer:   int
cam_dev:      string
cam_w_req:    int
cam_h_req:    int
audio_enc:    OpusEnc
desk_enc:     OpusEnc

// PeerRT is the per remote member runtime state.
PeerRT :: struct {
	info:    PeerInfo,
	vdec:    Dec,
	adec:    OpusDec,
	desk_dec: OpusDec,
	desk_rx_aec: Aec,
	screen_dec: Dec,
	screen_engine: ^AideoEngine,
	screen_w:   int,
	screen_h:   int,
	screen_tile: Tile,
	fas:     FragAsm,
	jb:      RingBuf,
	jb_mu:   sync.Mutex,
	desk_ring: RingBuf,
	desk_mu:   sync.Mutex,
	engine:  ^AideoEngine,
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
self_engine: ^AideoEngine
self_tile:   Tile
self_w:      int
self_h:      int
cam_ready:   i32
mic_enabled: bool
send_video:  i32
cam_off:     i32
self_mirror: i32 = 1
ui_modal:    i32
audio_swap:  i32
desk_ready:  i32
desk_send:   i32
mic_aec:     Aec
desk_aec:    Aec
aec_mu:      sync.Mutex
screen_cap:   ScreenCap
screen_enc:   H264Enc
screen_sws:   rawptr
screen_y:     []u8
screen_u:     []u8
screen_v:     []u8
screen_sw:    int
screen_sh:    int
screen_ready: i32
screen_send:  i32
screen_owner: u32
mode_saved:   LayoutMode
focus_saved:  int
self_screen_engine: ^AideoEngine
self_screen_tile:   Tile
self_screen_w:      int
self_screen_h:      int
share_output:       string
share_cursor:       i32 = 1
share_win_menu:     i32
share_window:       u64
win_lost:           i32
mir_y:       []u8
mir_u:       []u8
mir_v:       []u8
enc_out:     []u8
ybuf:        []u8
ubuf:        []u8
vbuf:        []u8
layout_dirty: i32

engine_new :: proc(src_w, src_h: int, t: Tile) -> ^AideoEngine {
	cfg: AideoConfig
	cfg.fd = 1
	cfg.src_w = c.int(src_w)
	cfg.src_h = c.int(src_h)
	cfg.out_w = c.int(t.w)
	cfg.out_h = c.int(t.h)
	cfg.colors = c.int(colors_now())
	cfg.origin_row = c.int(t.prow)
	cfg.origin_col = c.int(t.pcol)
	return aideo_open(&cfg)
}

// engine_mu guards every engine pointer so pushes, rebuilds, moves
// and closes never race.
engine_mu: sync.Mutex

// slot_push pushes one frame into the engine behind a pointer slot
// under the engine lock. Pushes are silenced while a text page covers
// the meeting screen.
slot_push :: proc(slot: ^^AideoEngine, f: YuvFrame) {
	sync.mutex_lock(&engine_mu)
	e := slot^
	if e != nil && sync.atomic_load(&ui_modal) == 0 {
		aideo_push_yuv(e, f.y, f.u, f.v, f.sy, f.sc)
	}
	sync.mutex_unlock(&engine_mu)
}

// slot_close closes the engine behind a pointer slot under the engine
// lock.
slot_close :: proc(slot: ^^AideoEngine) {
	sync.mutex_lock(&engine_mu)
	if slot^ != nil {
		aideo_close(slot^)
		slot^ = nil
	}
	sync.mutex_unlock(&engine_mu)
}

// slot_set replaces the engine behind a pointer slot under the engine
// lock.
slot_set :: proc(slot: ^^AideoEngine, e: ^AideoEngine) {
	sync.mutex_lock(&engine_mu)
	if slot^ != nil {
		aideo_close(slot^)
	}
	slot^ = e
	sync.mutex_unlock(&engine_mu)
}

// slot_resize moves the engine behind a pointer slot to a new tile,
// creating it when missing and the source size is known. While a text
// page covers the screen the engine is rebuilt instead of resized
// because a resize emits its own screen wipe behind the text page.
slot_resize :: proc(slot: ^^AideoEngine, src_w, src_h: int, t: Tile) {
	sync.mutex_lock(&engine_mu)
	if slot^ == nil {
		if src_w > 0 && src_h > 0 {
			slot^ = engine_new(src_w, src_h, t)
		}
	} else if sync.atomic_load(&ui_modal) != 0 {
		aideo_close(slot^)
		slot^ = nil
		if src_w > 0 && src_h > 0 {
			slot^ = engine_new(src_w, src_h, t)
		}
	} else {
		aideo_resize(slot^, c.int(t.w), c.int(t.h), c.int(t.prow), c.int(t.pcol))
	}
	sync.mutex_unlock(&engine_mu)
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
	sync.mutex_lock(&engine_mu)
	if self_engine != nil {
		aideo_repaint(self_engine)
	}
	if self_screen_engine != nil {
		aideo_repaint(self_screen_engine)
	}
	sync.mutex_unlock(&engine_mu)
	sync.mutex_lock(&peer_mu)
	for _, p in peers {
		sync.mutex_lock(&engine_mu)
		if p.engine != nil {
			aideo_repaint(p.engine)
		}
		if p.screen_engine != nil {
			aideo_repaint(p.screen_engine)
		}
		sync.mutex_unlock(&engine_mu)
	}
	sync.mutex_unlock(&peer_mu)
}

// ui_modal_on silences the sixel streams before a text page covers
// the meeting screen so no video diff mixes with the text layer.
ui_modal_on :: proc() {
	sync.atomic_store(&ui_modal, 1)
}

// ui_recover ends the text page, clears the screen and forces every
// sixel engine to redraw in full so no stale picture or partial diff
// survives.
ui_recover :: proc() {
	sync.atomic_store(&ui_modal, 0)
	screen_clear()
	engines_repaint()
}

// colors_apply pushes the selected palette size to every engine.
colors_apply :: proc() {
	colors := c.int(colors_now())
	if self_engine != nil {
		aideo_set_colors(self_engine, colors)
	}
	if self_screen_engine != nil {
		aideo_set_colors(self_screen_engine, colors)
	}
	sync.mutex_lock(&peer_mu)
	for _, p in peers {
		if p.engine != nil {
			aideo_set_colors(p.engine, colors)
		}
		if p.screen_engine != nil {
			aideo_set_colors(p.screen_engine, colors)
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
	if screen_owner != 0 || screen_local_on() {
		tiles = layout_focus(n + 1, n, self_w, self_h)
	} else if conf_mode == .Grid {
		tiles = layout_grid(n, self_w, self_h)
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
	if screen_owner != 0 {
		sw2, sh2 := self_w, self_h
		sp := peer_get(screen_owner)
		if sp != nil && sp.screen_w > 0 {
			sw2, sh2 = sp.screen_w, sp.screen_h
		}
		tile_fit(&tiles[n], sw2, sh2)
	} else if screen_local_on() {
		tile_fit(&tiles[n], screen_sw, screen_sh)
		self_screen_tile = tiles[n]
	}
	// The screen is cleared once per layout change so no stale
	// picture or partial sixel diff survives the rearrangement.
	screen_clear()
	self_tile = tiles[0]
	slot_resize(&self_engine, self_w, self_h, self_tile)
	sync.mutex_lock(&peer_mu)
	for id, i in ids {
		p := peers[id]
		if p == nil {
			continue
		}
		p.tile = tiles[i + 1]
		p.has_tile = true
		slot_resize(&p.engine, p.src_w, p.src_h, p.tile)
	}
	if screen_owner != 0 {
		sp := peers[screen_owner]
		if sp != nil {
			sp.screen_tile = tiles[n]
			slot_resize(&sp.screen_engine, sp.screen_w, sp.screen_h, sp.screen_tile)
		}
	}
	sync.mutex_unlock(&peer_mu)
	if screen_local_on() {
		slot_resize(&self_screen_engine, screen_sw, screen_sh, self_screen_tile)
	}
	if screen_owner == 0 && !screen_local_on() {
		slot_close(&self_screen_engine)
	}
	delete(conf_tiles)
	conf_tiles = tiles
	engines_repaint()
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
	_ = dec_open(&p.screen_dec, "h264")
	_ = opus_dec_open(&p.adec, 1)
	_ = opus_dec_open(&p.desk_dec, 2)
	_ = aec_open(&p.desk_rx_aec, AUDIO_RATE, PB_CH, PB_CH)
	ring_init(&p.jb, AUDIO_RATE)
	ring_init(&p.desk_ring, AUDIO_RATE * 2 * 2)
	peers[info.id] = p
	if info.screen {
		screen_set_owner(info.id)
	}
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
	slot_close(&p.engine)
	slot_close(&p.screen_engine)
	dec_close(&p.vdec)
	dec_close(&p.screen_dec)
	opus_dec_close(&p.adec)
	opus_dec_close(&p.desk_dec)
	sync.mutex_lock(&aec_mu)
	aec_close(&p.desk_rx_aec)
	sync.mutex_unlock(&aec_mu)
	delete(p.jb.data)
	delete(p.desk_ring.data)
	free(p)
	if screen_owner == id {
		screen_set_owner(0)
	}
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
	sync.mutex_lock(&engine_mu)
	need := p.engine == nil || p.src_w != f.w || p.src_h != f.h
	sync.mutex_unlock(&engine_mu)
	if need {
		p.src_w = f.w
		p.src_h = f.h
		if !p.has_tile {
			return
		}
		tile_fit(&p.tile, f.w, f.h)
		slot_set(&p.engine, engine_new(f.w, f.h, p.tile))
	}
	slot_push(&p.engine, f)
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

// desk_block decodes one stereo system audio packet into the peer desk
// ring after removing the local playback contribution.
desk_block :: proc(p: ^PeerRT, data: []u8) {
	buf: [AUDIO_BLOCK * 2]i16
	n := opus_dec_decode(&p.desk_dec, data, buf[:])
	if n <= 0 {
		return
	}
	sync.mutex_lock(&aec_mu)
	aec_cap(&p.desk_rx_aec, buf[:], AUDIO_BLOCK)
	sync.mutex_unlock(&aec_mu)
	sync.mutex_lock(&p.desk_mu)
	ring_write(&p.desk_ring, buf[:n])
	sync.mutex_unlock(&p.desk_mu)
}

// cam_pipeline_start opens the camera, the conversion buffers and the
// encoder so the meeting can send video. It reports whether the
// pipeline is ready.
cam_pipeline_start :: proc() -> bool {
	if sync.atomic_load(&cam_ready) != 0 {
		return true
	}
	cam_auto_pick()
	if !cam_start(&cam, cam_dev, cam_w_req, cam_h_req) {
		return false
	}
	self_w = cam.w
	self_h = cam.h
	ybuf = make([]u8, self_w * self_h)
	ubuf = make([]u8, self_w * self_h / 4)
	vbuf = make([]u8, self_w * self_h / 4)
	mir_y = make([]u8, self_w * self_h)
	mir_u = make([]u8, self_w * self_h / 4)
	mir_v = make([]u8, self_w * self_h / 4)
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

// audio_switch restarts the audio devices so newly picked input and
// output take effect during a meeting.
audio_switch :: proc() {
	vol := sync.atomic_load(&spk_vol_bits)
	desk_on := sync.atomic_load(&desk_ready) != 0
	sync.atomic_store(&audio_swap, 1)
	time.sleep(150 * time.Millisecond)
	if desk_on {
		desk_stop()
	}
	audio_stop()
	audio_start()
	if desk_on && !desk_start() {
		sync.atomic_store(&desk_send, 0)
	}
	sync.atomic_store(&spk_vol_bits, vol)
	sync.atomic_store(&audio_swap, 0)
}

// cam_switch restarts the camera pipeline so the newly picked device
// takes effect during a meeting.
cam_switch :: proc() {
	off := sync.atomic_load(&cam_off)
	was_ready := sync.atomic_load(&cam_ready) != 0
	sync.atomic_store(&cam_ready, 0)
	sync.atomic_store(&send_video, 0)
	time.sleep(300 * time.Millisecond)
	cam_stop(&cam)
	h264_enc_close(&enc)
	dec_close(&local_dec)
	delete(ybuf)
	delete(ubuf)
	delete(vbuf)
	delete(enc_out)
	delete(mir_y)
	delete(mir_u)
	delete(mir_v)
	ybuf = nil
	ubuf = nil
	vbuf = nil
	enc_out = nil
	mir_y = nil
	mir_u = nil
	mir_v = nil
	if cam_pipeline_start() {
		if was_ready && off == 1 {
			sync.atomic_store(&cam_off, 1)
		} else {
			sync.atomic_store(&cam_off, 0)
			sync.atomic_store(&send_video, 1)
		}
		slot_close(&self_engine)
		layout_apply()
	}
	sess_update(&sess, sync.atomic_load(&send_video) != 0, sync.atomic_load(&mic_mute) == 0, sync.atomic_load(&screen_send) != 0)
}

// dev_modal_run opens the device picker during a meeting, keeps the
// sixel engines quiet while it is open and applies device changes
// live.
dev_modal_run :: proc() {
	in_id := strings.clone(dev_pick[0].use)
	out_id := strings.clone(dev_pick[1].use)
	old_cam := strings.clone(cam_dev)
	ui_modal_on()
	time.sleep(60 * time.Millisecond)
	dev_session = true
	dev_run()
	ui_recover()
	if dev_pick[0].use != in_id || dev_pick[1].use != out_id {
		audio_switch()
	}
	if cam_dev != old_cam {
		cam_switch()
	}
	config_store()
	if len(in_id) > 0 {
		delete(in_id)
	}
	if len(out_id) > 0 {
		delete(out_id)
	}
	if len(old_cam) > 0 {
		delete(old_cam)
	}
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
			if len(data) < cam.w * cam.h * 2 {
				cam_ungrab(&cam)
				continue
			}
			yuyv_to_i420(data, cam.w, cam.h, ybuf, ubuf, vbuf)
			f = YuvFrame{
				y = raw_data(ybuf), u = raw_data(ubuf), v = raw_data(vbuf),
				sy = c.int(cam.w), sc = c.int(cam.w / 2), w = cam.w, h = cam.h,
			}
		}
		if f.w > 0 && sync.atomic_load(&cam_off) == 0 {
			if sync.atomic_load(&self_mirror) != 0 {
				if f.w * f.h > len(mir_y) {
					delete(mir_y)
					delete(mir_u)
					delete(mir_v)
					mir_y = make([]u8, f.w * f.h)
					mir_u = make([]u8, f.w * f.h / 4)
					mir_v = make([]u8, f.w * f.h / 4)
				}
				slot_push(&self_engine, yuv_flip_h(f, mir_y, mir_u, mir_v))
			} else {
				slot_push(&self_engine, f)
			}
		}
		if f.w > 0 {
			if sync.atomic_load(&send_video) != 0 {
				n, key := h264_enc_encode(&enc, f, enc_out, sync.atomic_load(&force_key_video) != 0)
				if n > 0 {
					sync.atomic_store(&force_key_video, 0)
					flags := u8(0)
					if key {
						flags = MEDIA_FLAG_KEY
					}
					seq += 1
					sess_send_frame(&sess, MEDIA_STREAM_VIDEO, flags, seq, ms_now(), enc_out[:n])
					sync.atomic_add(&tx_media_n, 1)
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
		if sync.atomic_load(&audio_swap) != 0 {
			continue
		}
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
		sync.mutex_lock(&aec_mu)
		aec_cap(&mic_aec, pcm[:], AUDIO_BLOCK)
		sync.mutex_unlock(&aec_mu)
		n := opus_enc_encode(&audio_enc, pcm[:], out[:])
		if n > 0 {
			seq += 1
			sess_send_frame(&sess, MEDIA_STREAM_AUDIO, 0, seq, ms_now(), out[:n])
			sync.atomic_add(&tx_media_n, 1)
		}
	}
}

// desk_pipeline_start opens system audio sharing so the active output
// monitor is captured and sent to the room.
desk_pipeline_start :: proc() -> bool {
	if sync.atomic_load(&desk_ready) != 0 {
		return true
	}
	if !desk_start() {
		return false
	}
	if !opus_enc_open(&desk_enc, 128000, 2) {
		desk_stop()
		toast_show("desktop audio: encoder failed", 2)
		return false
	}
	_ = aec_open(&desk_aec, AUDIO_RATE, PB_CH, PB_CH)
	sync.atomic_store(&desk_ready, 1)
	return true
}

desk_tx_thread :: proc() {
	buf: [AUDIO_BLOCK * 2]i16
	out: [4000]u8
	seq: u32
	for sync.atomic_load(&app_stop) == 0 {
		time.sleep(5 * time.Millisecond)
		if sync.atomic_load(&audio_swap) != 0 {
			continue
		}
		if sync.atomic_load(&desk_ready) == 0 {
			continue
		}
		if sync.atomic_load(&desk_send) == 0 {
			desk_capture_pop(buf[:])
			continue
		}
		if desk_capture_fill() < AUDIO_BLOCK * PB_CH {
			continue
		}
		desk_capture_pop(buf[:])
		sync.mutex_lock(&aec_mu)
		aec_cap(&desk_aec, buf[:], AUDIO_BLOCK)
		sync.mutex_unlock(&aec_mu)
		n := opus_enc_encode(&desk_enc, buf[:], out[:])
		if n > 0 {
			seq += 1
			sess_send_frame(&sess, MEDIA_STREAM_DESK, 0, seq, ms_now(), out[:n])
			sync.atomic_add(&tx_media_n, 1)
		}
	}
}

// screen_set_owner tracks which member streams a screen and swaps the
// layout to the screen arrangement automatically. A member whose
// screen is taken over by a later sharer drops back to the idle state.
screen_set_owner :: proc(id: u32) {
	if id == screen_owner {
		return
	}
	if id != 0 && id != sess.self_id && sync.atomic_load(&screen_send) != 0 {
		screen_stop()
		toast_show("screen sharing stopped, another member took over", 2)
		sess_update(&sess, sync.atomic_load(&send_video) != 0, sync.atomic_load(&mic_mute) == 0, false)
	}
	if id != 0 && screen_owner == 0 {
		mode_saved = conf_mode
		focus_saved = conf_focus
	}
	screen_owner = id
	if id == 0 {
		conf_mode = mode_saved
		conf_focus = focus_saved
	}
	sync.atomic_store(&layout_dirty, 1)
}




// dump_bgra_bmp writes one BGRA frame to a BMP for debugging.
dump_bgra_bmp :: proc(path: string, p: []u8, stride, w, h: int) {
	row := ((w * 3 + 3) / 4) * 4
	buf := make([]u8, 54 + row * h)
	buf[0] = 'B'
	buf[1] = 'M'
	sz := len(buf)
	buf[2] = u8(sz)
	buf[3] = u8(sz >> 8)
	buf[4] = u8(sz >> 16)
	buf[5] = u8(sz >> 24)
	buf[10] = 54
	buf[14] = 40
	buf[18] = u8(w)
	buf[19] = u8(w >> 8)
	buf[22] = u8(h)
	buf[23] = u8(h >> 8)
	buf[26] = 1
	buf[28] = 24
	for yy in 0..<h {
		for x in 0..<w {
			off := 54 + (h - 1 - yy) * row + x * 3
			src := yy * stride + x * 4
			buf[off] = p[src]
			buf[off + 1] = p[src + 1]
			buf[off + 2] = p[src + 2]
		}
	}
	_ = os.write_entire_file(path, buf)
	delete(buf)
}

// dump_frame_bmp writes one YUV frame to a BMP for debugging.
dump_frame_bmp :: proc(path: string, y, u, v: [^]u8, sy, sc, w, h: int) {
	row := ((w * 3 + 3) / 4) * 4
	buf := make([]u8, 54 + row * h)
	buf[0] = 'B'
	buf[1] = 'M'
	sz := len(buf)
	buf[2] = u8(sz)
	buf[3] = u8(sz >> 8)
	buf[4] = u8(sz >> 16)
	buf[5] = u8(sz >> 24)
	buf[10] = 54
	buf[14] = 40
	buf[18] = u8(w)
	buf[19] = u8(w >> 8)
	buf[22] = u8(h)
	buf[23] = u8(h >> 8)
	buf[26] = 1
	buf[28] = 24
	for yy in 0..<h {
		for x in 0..<w {
			Y := int(y[yy * sy + x]) - 16
			U := int(u[(yy / 2) * sc + x / 2]) - 128
			V := int(v[(yy / 2) * sc + x / 2]) - 128
			r := (298 * Y + 409 * V + 128) >> 8
			g := (298 * Y - 100 * U - 208 * V + 128) >> 8
			b := (298 * Y + 516 * U + 128) >> 8
			r = clamp(r, 0, 255)
			g = clamp(g, 0, 255)
			b = clamp(b, 0, 255)
			off := 54 + (h - 1 - yy) * row + x * 3
			buf[off] = u8(b)
			buf[off + 1] = u8(g)
			buf[off + 2] = u8(r)
		}
	}
	_ = os.write_entire_file(path, buf)
	delete(buf)
}

// screen_local_on reports whether the local desktop is being shared.
screen_local_on :: proc() -> bool {
	return sync.atomic_load(&screen_ready) != 0 && sync.atomic_load(&screen_send) != 0 && screen_sw > 0
}

// screen_preview pushes one captured desktop frame into the local
// preview engine so the sharer sees what is being shared.
screen_preview :: proc(f: YuvFrame) {
	sync.mutex_lock(&engine_mu)
	need := self_screen_engine == nil || self_screen_w != f.w || self_screen_h != f.h
	sync.mutex_unlock(&engine_mu)
	if need {
		self_screen_w = f.w
		self_screen_h = f.h
		if self_screen_tile.bw == 0 {
			return
		}
		tile_fit(&self_screen_tile, f.w, f.h)
		slot_set(&self_screen_engine, engine_new(f.w, f.h, self_screen_tile))
	}
	slot_push(&self_screen_engine, f)
}

// screen_frame_in routes one decoded screen frame into the owner
// engine, recreating it when the source size changes.
screen_frame_in :: proc(p: ^PeerRT, f: YuvFrame) {
	sync.mutex_lock(&engine_mu)
	need := p.screen_engine == nil || p.screen_w != f.w || p.screen_h != f.h
	sync.mutex_unlock(&engine_mu)
	if need {
		p.screen_w = f.w
		p.screen_h = f.h
		if p.screen_tile.bw == 0 {
			return
		}
		tile_fit(&p.screen_tile, f.w, f.h)
		slot_set(&p.screen_engine, engine_new(f.w, f.h, p.screen_tile))
	}
	slot_push(&p.screen_engine, f)
}

// share_apply restarts screen sharing so new settings take effect.
share_apply :: proc() {
	if sync.atomic_load(&screen_send) == 0 {
		return
	}
	screen_stop()
	if screen_pipeline_start() {
		sync.atomic_store(&screen_send, 1)
		sync.atomic_store(&layout_dirty, 1)
		toast_show("screen sharing restarted", 1)
	} else {
		toast_show("screen sharing failed, compositor needs wlr-screencopy", 2)
	}
}

// share_target_apply starts or retargets screen sharing on one picked
// target. The stop entry ends sharing instead.
share_target_apply :: proc(e: ^DevEnt) {
	if e.dev == "stop" {
		screen_stop()
		sync.atomic_store(&layout_dirty, 1)
		sess_update(&sess, sync.atomic_load(&send_video) != 0, sync.atomic_load(&mic_mute) == 0, false)
		toast_show("screen sharing stopped", 0)
		return
	}
	if e.win != 0 {
		share_window = e.win
		if len(share_output) > 0 {
			delete(share_output)
			share_output = ""
		}
	} else {
		share_window = 0
		if len(share_output) > 0 {
			delete(share_output)
		}
		share_output = strings.clone(e.dev)
	}
	dev_set_name(&dev_target_name, e.name)
	sharing := sync.atomic_load(&screen_send) != 0
	if sharing {
		share_apply()
	} else if screen_pipeline_start() {
		sync.atomic_store(&screen_send, 1)
		sync.atomic_store(&layout_dirty, 1)
		toast_show("screen sharing started", 1)
	} else {
		toast_show("screen sharing failed, compositor needs wlr-screencopy", 2)
	}
	sess_update(&sess, sync.atomic_load(&send_video) != 0, sync.atomic_load(&mic_mute) == 0, sync.atomic_load(&screen_send) != 0)
}

// share_menu_run opens the share target menu. Outputs are always
// listed and windows follow the windows setting. Picking a target
// starts or retargets sharing and picking stop sharing ends it.
share_menu_run :: proc() {
	ui_modal_on()
	time.sleep(60 * time.Millisecond)
	defer ui_recover()
	opts: [dynamic]DevEnt
	defer dev_list_free(&opts)
	base := 0
	if sync.atomic_load(&screen_send) != 0 {
		append(&opts, DevEnt{name = strings.clone("stop sharing"), dev = strings.clone("stop")})
		base = 1
	}
	cur := dev_sub_build(.Target, &opts)
	if cur < base {
		cur = base
	}
	need_draw := true
	for {
		if need_draw {
			b: FB
			fb_begin(&b)
			cols, rows := term_size()
			if cols < 40 || rows < 10 {
				ui_small(&b, "Terminal too small, need at least 40x10")
				fb_end(&b)
				need_draw = false
				continue
			}
			width := min(cols - 8, 60)
			height := min(len(opts) + 4, rows - 4)
			left := (cols - width) / 2 + 1
			top := max((rows - height) / 2, 1)
			ui_panel(&b, top, left, width, height, "share target")
			dev_col_draw(&b, left + 2, top + 2, width - 4, height - 3, opts[:], cur, 0, true, false)
			hint_draw(&b, cols, rows, [4][2]string{{"j/k, arrows", "move"}, {"Enter", "select"}, {"q", "cancel"}, {"", ""}})
			fb_end(&b)
			need_draw = false
		}
		k := key_next()
		if k.kind == .None {
			if term_take_winch() {
				need_draw = true
			}
			continue
		}
		need_draw = true
		#partial switch k.kind {
		case .Quit:
			return
		case .Up:
			if cur > 0 {
				cur -= 1
			}
		case .Down:
			if cur + 1 < len(opts) {
				cur += 1
			}
		case .Enter:
			share_target_apply(&opts[cur])
			return
		case .Char:
			switch k.ch {
			case 'q', 'Q':
				return
			case 'k', 'K', 'w', 'W':
				if cur > 0 {
					cur -= 1
				}
			case 'j', 'J', 's', 'S':
				if cur + 1 < len(opts) {
					cur += 1
				}
			}
		}
	}
}

// screen_pipeline_start opens the screen capture so the meeting can
// send the desktop picture or one application window.
// screen_mu serializes the screen capture pipeline against the tx
// thread so stop and start never race with polling, scaling or
// encoding.
screen_mu: sync.Mutex

screen_pipeline_start :: proc() -> bool {
	sync.mutex_lock(&screen_mu)
	defer sync.mutex_unlock(&screen_mu)
	if sync.atomic_load(&screen_ready) != 0 {
		return true
	}
	if share_window != 0 {
		w, _, alive := win_track(share_window)
		if !alive || !win_use() {
			return false
		}
		if w.rect.w <= 0 || w.rect.h <= 0 {
			if w.floating {
				toast_show("window not on screen", 2)
			} else {
				toast_show("tiled window needs niri update", 2)
			}
			return false
		}
		if !screen_open_ex(&screen_cap, w.output, "", sync.atomic_load(&share_cursor) != 0) {
			return false
		}
		screen_set_region(&screen_cap, w.rect.x, w.rect.y, w.rect.w, w.rect.h)
		sync.atomic_store(&screen_ready, 1)
		return true
	}
	if !screen_open_ex(&screen_cap, share_output, "", sync.atomic_load(&share_cursor) != 0) {
		return false
	}
	sync.atomic_store(&screen_ready, 1)
	return true
}

// screen_teardown releases the scaler, buffers and encoder.
screen_teardown :: proc() {
	if screen_sws != nil {
		sws_freeContext(screen_sws)
		screen_sws = nil
	}
	h264_enc_close(&screen_enc)
	delete(screen_y)
	delete(screen_u)
	delete(screen_v)
	screen_y = nil
	screen_u = nil
	screen_v = nil
	screen_sw = 0
	screen_sh = 0
}

// screen_stop closes the screen capture pipeline and schedules a
// layout pass so the share tile never survives as a stale region.
screen_stop :: proc() {
	sync.mutex_lock(&screen_mu)
	screen_stop_locked()
	sync.mutex_unlock(&screen_mu)
}

// screen_stop_locked tears the pipeline down while screen_mu is held.
screen_stop_locked :: proc() {
	sync.atomic_store(&screen_send, 0)
	sync.atomic_store(&screen_ready, 0)
	screen_close(&screen_cap)
	screen_teardown()
	sync.atomic_store(&layout_dirty, 1)
}

// screen_setup rebuilds the scaler, conversion buffers and encoder for
// a new screen size.
screen_setup :: proc(w, h: int) {
	screen_teardown()
	screen_sw = w
	screen_sh = h
	screen_y = make([]u8, w * h)
	screen_u = make([]u8, w * h / 4)
	screen_v = make([]u8, w * h / 4)
	screen_sws = sws_getContext(c.int(w), c.int(h), PIX_FMT_BGRA, c.int(w), c.int(h), PIX_FMT_YUV420P, 1, nil, nil, nil)
	_ = h264_enc_open(&screen_enc, w, h, 15, 2000, enc_prefer)
}

// screen_tx_thread captures the desktop, encodes it and sends the
// stream to the room.
// screen_tx_once polls one frame and sends it under screen_mu. It
// returns false when the pipeline failed and must be stopped.
screen_tx_once :: proc(out: []u8, last: ^time.Time, first: ^bool, seq: ^u32) -> bool {
	if sync.atomic_load(&screen_ready) == 0 || sync.atomic_load(&screen_send) == 0 {
		return true
	}
	if share_window != 0 {
		w, _, alive := win_track(share_window)
		if !alive {
			sync.atomic_store(&win_lost, 1)
			return false
		}
		if w.rect.w > 0 && w.rect.h > 0 {
			screen_set_region(&screen_cap, w.rect.x, w.rect.y, w.rect.w, w.rect.h)
		}
	}
	r := screen_poll(&screen_cap, 100)
	if r < 0 {
		return false
	}
	if r == 0 {
		return true
	}
	w, h, stride, yinv := 0, 0, 0, 0
	data := screen_frame(&screen_cap, &w, &h, &stride, &yinv)
	if data == nil {
		return true
	}
	now := time.now()
	if !first^ && time.since(last^) < 66 * time.Millisecond {
		return true
	}
	first^ = false
	last^ = now
	if screen_sw != w || screen_sh != h || screen_sws == nil {
		screen_setup(w, h)
		sync.atomic_store(&layout_dirty, 1)
	}
	srcp := raw_data(data)
	sstride := c.int(stride)
	if yinv != 0 {
		srcp = ([^]u8)(&data[(h - 1) * stride])
		sstride = -sstride
	}
	srcData: [4][^]u8
	srcStride: [4]c.int
	dstData: [4][^]u8
	dstStride: [4]c.int
	srcData[0] = srcp
	srcStride[0] = sstride
	dstData[0] = raw_data(screen_y)
	dstData[1] = raw_data(screen_u)
	dstData[2] = raw_data(screen_v)
	dstStride[0] = c.int(w)
	dstStride[1] = c.int(w / 2)
	dstStride[2] = c.int(w / 2)
	sws_scale(screen_sws, &srcData, &srcStride, 0, c.int(h), &dstData, &dstStride)
	f := YuvFrame{
		y = raw_data(screen_y), u = raw_data(screen_u), v = raw_data(screen_v),
		sy = c.int(w), sc = c.int(w / 2), w = w, h = h,
	}
	screen_preview(f)
	n, key := h264_enc_encode(&screen_enc, f, out, sync.atomic_load(&force_key_screen) != 0)
	if n > 0 {
		sync.atomic_store(&force_key_screen, 0)
		flags := u8(0)
		if key {
			flags = MEDIA_FLAG_KEY
		}
		seq^ += 1
		sess_send_frame(&sess, MEDIA_STREAM_SCREEN, flags, seq^, ms_now(), out[:n])
		sync.atomic_add(&tx_media_n, 1)
	}
	return true
}

screen_tx_thread :: proc() {
	out := make([]u8, 1 << 21)
	defer delete(out)
	last: time.Time
	first := true
	seq: u32
	for sync.atomic_load(&app_stop) == 0 {
		time.sleep(5 * time.Millisecond)
		sync.mutex_lock(&screen_mu)
		ok := screen_tx_once(out, &last, &first, &seq)
		sync.mutex_unlock(&screen_mu)
		if !ok {
			screen_stop()
		}
	}
}

mix_thread :: proc() {
	mix := make([]i16, AUDIO_BLOCK * PB_CH)
	tmp := make([]i16, AUDIO_BLOCK * PB_CH)
	mono := make([]i16, AUDIO_BLOCK)
	defer delete(mix)
	defer delete(tmp)
	defer delete(mono)
	keep := 0
	for sync.atomic_load(&app_stop) == 0 {
		time.sleep(20 * time.Millisecond)
		if sync.atomic_load(&audio_swap) != 0 {
			continue
		}
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
			n := ring_read(&p.jb, mono[:])
			sync.mutex_unlock(&p.jb_mu)
			for i in 0..<n {
				mix[2 * i] += mono[i]
				mix[2 * i + 1] += mono[i]
			}
			sync.mutex_lock(&p.desk_mu)
			dn := ring_read(&p.desk_ring, tmp[:])
			sync.mutex_unlock(&p.desk_mu)
			for i in 0..<dn {
				mix[i] += tmp[i]
			}
		}
		mn := audio_monitor_pop(mono[:])
		for i in 0..<mn {
			mix[2 * i] += mono[i]
			mix[2 * i + 1] += mono[i]
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
		vol := transmute(f32)u32(sync.atomic_load(&spk_vol_bits))
		if vol != 1.0 {
			for i in 0..<len(mix) {
				s := f32(mix[i]) * vol
				if s > AUDIO_MIX_MAX {
					s = AUDIO_MIX_MAX
				} else if s < -32768 {
					s = -32768
				}
				mix[i] = i16(s)
			}
		}
		sync.mutex_lock(&aec_mu)
		aec_play(&mic_aec, mix, AUDIO_BLOCK)
		aec_play(&desk_aec, mix, AUDIO_BLOCK)
		for p in list {
			aec_play(&p.desk_rx_aec, mix, AUDIO_BLOCK)
		}
		sync.mutex_unlock(&aec_mu)
		delete(list)
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
				sync.atomic_store(&force_key_video, 1)
				sync.atomic_store(&force_key_screen, 1)
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
					p.info.screen = m.Screen
				}
				if m.Screen {
					screen_set_owner(m.ID)
				} else if screen_owner == m.ID {
					screen_set_owner(0)
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
			sync.atomic_add(&rx_media_n, 1)
			if ok2 {
				video_frame(p, f)
			}
		} else if h.stream == MEDIA_STREAM_SCREEN {
			f, ok2 := dec_feed(&p.screen_dec, frame)
			sync.atomic_add(&rx_media_n, 1)
			if ok2 {
				if screen_owner == 0 {
					screen_set_owner(h.src)
				}
				screen_frame_in(p, f)
			}
		} else if h.stream == MEDIA_STREAM_DESK {
			sync.atomic_add(&rx_media_n, 1)
			desk_block(p, frame)
		} else {
			sync.atomic_add(&rx_media_n, 1)
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
	if k.kind == .Quit {
		quit_on = false
		return false
	}
	quit_key := k.kind == .Char && (k.ch == 'q' || k.ch == 'Q')
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
		toast_show(tprintf("volume %d%%", vol_pct()), 0)
	case .Down:
		audio_vol_add(-0.1)
		toast_show(tprintf("volume %d%%", vol_pct()), 0)
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
			if sync.atomic_load(&spk_mute) != 0 {
				toast_show("speaker muted", 0)
			} else {
				toast_show("speaker on", 1)
			}
		case 'n', 'N':
			audio_toggle_mic()
			if sync.atomic_load(&mic_mute) != 0 {
				toast_show("microphone off", 0)
			} else {
				toast_show("microphone on", 1)
			}
			sess_update(&sess, sync.atomic_load(&send_video) != 0, sync.atomic_load(&mic_mute) == 0, sync.atomic_load(&screen_send) != 0)
		case 'c', 'C':
			if sync.atomic_load(&cam_ready) != 0 {
				off := 1 - sync.atomic_load(&cam_off)
				sync.atomic_store(&cam_off, off)
				sync.atomic_store(&send_video, 1 - off)
				if off == 1 {
					screen_clear()
					engines_repaint()
					toast_show("camera off", 0)
				} else {
					toast_show("camera on", 1)
				}
			} else if cam_pipeline_start() {
				sync.atomic_store(&cam_off, 0)
				sync.atomic_store(&send_video, 1)
				slot_close(&self_engine)
				layout_apply()
				toast_show("camera on", 1)
			} else {
				msg := "camera failed to open"
				if cam_fail != "" {
					msg = cam_fail
				}
				toast_show(msg, 2)
			}
			sess_update(&sess, sync.atomic_load(&send_video) != 0, sync.atomic_load(&mic_mute) == 0, sync.atomic_load(&screen_send) != 0)
		case 'f', 'F':
			n := 1 + peer_count()
			if conf_mode == .Grid {
				conf_mode = .Focus
				conf_focus = 0
			} else {
				conf_focus += 1
				if conf_focus >= n {
					conf_mode = .Grid
					conf_focus = 0
				}
			}
			label := "grid"
			if conf_mode == .Focus {
				name := "me"
				if conf_focus > 0 {
					ids := peer_ids_sorted()
					if conf_focus - 1 < len(ids) {
						p := peer_get(ids[conf_focus - 1])
						if p != nil {
							name = p.info.name
						}
					}
					delete(ids)
				}
				label = tprintf("focus %s", name)
			}
			toast_show(tprintf("layout: %s", label), 1)
			layout_apply()
		case 'h', 'H':
			sync.atomic_store(&self_mirror, 1 - sync.atomic_load(&self_mirror))
			if sync.atomic_load(&self_mirror) != 0 {
				toast_show("mirror on", 1)
			} else {
				toast_show("mirror off", 0)
			}
		case 'a', 'A':
			if sync.atomic_load(&desk_ready) == 0 {
				if desk_pipeline_start() {
					sync.atomic_store(&desk_send, 1)
					toast_show("desktop audio sharing started", 1)
				}
			} else {
				on := 1 - sync.atomic_load(&desk_send)
				sync.atomic_store(&desk_send, on)
				if on != 0 {
					toast_show("desktop audio sharing started", 1)
				} else {
					toast_show("desktop audio sharing stopped", 0)
				}
			}
		case 's', 'S':
			share_menu_run()
			sync.atomic_store(&layout_dirty, 1)
		case '?':
			ui_modal_on()
			time.sleep(60 * time.Millisecond)
			help_open = true
			help_draw()
		case 'i', 'I':
			code_modal_run()
			sync.atomic_store(&layout_dirty, 1)
		case 'd', 'D':
			dev_modal_run()
		}
	}
	return false
}

// TMUX_FULL_INTERVAL is the full repaint period under tmux. It stays
// below the tmux image count limit window so the base frame is never
// evicted while diff frames keep arriving.
TMUX_FULL_INTERVAL :: 10 * time.Second

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
	sync.atomic_store(&tx_media_n, 0)
	sync.atomic_store(&rx_media_n, 0)
	if cam_on && cam_pipeline_start() {
		sync.atomic_store(&cam_off, 0)
		sync.atomic_store(&send_video, 1)
	}
	if audio_start() && opus_enc_open(&audio_enc, 24000, 1) {
		mic_enabled = true
		_ = aec_open(&mic_aec, AUDIO_RATE, 1, PB_CH)
	} else {
		mic_enabled = false
	}
	if mic_on {
		sync.atomic_store(&mic_mute, 0)
	} else {
		sync.atomic_store(&mic_mute, 1)
	}
	sess_update(&sess, sync.atomic_load(&send_video) != 0, sync.atomic_load(&mic_mute) == 0, false)

	screen_clear()
	self_engine = nil
	self_tile = Tile{}
	conf_focus = 0
	if conf_code_tail != "" {
		delete(conf_code_tail)
	}
	if conf_code_full != "" {
		delete(conf_code_full)
	}
	code := meeting_encode(server, room, secret)
	conf_code_tail = strings.clone(code[len(code) - 4:])
	conf_code_full = strings.clone(code)
	delete(code)
	layout_apply()

	t_atx: ^thread.Thread
	t_rx := thread.create_and_start(rx_thread)
	t_mix := thread.create_and_start(mix_thread)
	t_cap := thread.create_and_start(capture_thread)
	t_dtx := thread.create_and_start(desk_tx_thread)
	t_stx := thread.create_and_start(screen_tx_thread)
	if mic_enabled {
		t_atx = thread.create_and_start(audio_tx_thread)
	}

	last_ui: time.Time
	last_full: time.Time
	tmux_env := os.get_env_alloc("TMUX", context.allocator)
	tmux_mode := tmux_env != ""
	if tmux_mode {
		delete(tmux_env)
	}
	for sync.atomic_load(&app_stop) == 0 {
		tmp := runtime.default_temp_allocator_temp_begin()
		defer runtime.default_temp_allocator_temp_end(tmp)
		k := key_next()
		if k.kind != .None {
			if help_open {
				help_open = false
				ui_recover()
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
		if sync.atomic_load(&win_lost) != 0 {
			sync.atomic_store(&win_lost, 0)
			toast_show("window closed, sharing stopped", 2)
		}
		if sync.atomic_load(&layout_dirty) != 0 {
			layout_apply()
		}
		if tmux_mode && time.since(last_full) >= TMUX_FULL_INTERVAL {
			last_full = time.now()
			engines_repaint()
		}
		if !help_open && time.since(last_ui) >= 200 * time.Millisecond {
			last_ui = time.now()
			conf_draw()
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
	thread.join(t_dtx)
	thread.join(t_stx)
	sync.atomic_store(&desk_send, 0)
	sync.atomic_store(&desk_ready, 0)
	desk_stop()
	opus_enc_close(&desk_enc)
	aec_close(&desk_aec)
	aec_close(&mic_aec)
	delete(desk_ring.data)
	desk_ring.data = nil
	screen_stop()
	screen_owner = 0
	share_window = 0
	win_stop()
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
	quit_on = false
	help_open = false
	slot_close(&self_engine)
	slot_close(&self_screen_engine)
	cam_stop(&cam)
	audio_stop()
	h264_enc_close(&enc)
	dec_close(&local_dec)
	opus_enc_close(&audio_enc)
	delete(ybuf)
	delete(ubuf)
	delete(vbuf)
	delete(enc_out)
	delete(mir_y)
	delete(mir_u)
	delete(mir_v)
	ybuf = nil
	ubuf = nil
	vbuf = nil
	enc_out = nil
	mir_y = nil
	mir_u = nil
	mir_v = nil
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
