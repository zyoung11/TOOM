package toom

import "core:sync"
import "core:time"

CONF_COLORS :: [7]int{2, 8, 16, 32, 64, 128, 256}

// CapInfo is one caption rendered on the row below a picture. The
// own flag marks pictures of the local member.
CapInfo :: struct {
	t:     Tile,
	name:  string,
	muted: bool,
	sel:   bool,
	own:   bool,
	empty: bool,
}

// tile_placeholder paints the empty picture block with four corner
// marks, a dim dot pattern, the initial badge and the name so a
// disabled camera keeps its identity. It is text only: no picture
// engine runs while the camera is off.
tile_placeholder :: proc(b: ^FB, t: Tile, name: string) {
	if t.bw < 2 || t.bh < 2 || t.w < 4 || t.h < 4 {
		return
	}
	cw, ch := term_cell_pixels()
	prows := (t.h + ch - 1) / ch
	pcols := (t.w + cw - 1) / cw
	if prows < 3 || pcols < 3 {
		return
	}
	r0 := t.prow
	c0 := t.pcol
	col := hex_color(app_cfg.border_color)
	if col == 0 {
		col = 0xd8d8d8
	}
	fb_str(b, tprintf("\x1b[38;2;%d;%d;%dm", u8(col >> 16), u8(col >> 8), u8(col)))
	fb_at(b, r0, c0)
	fb_str(b, "┌")
	fb_at(b, r0, c0 + pcols - 1)
	fb_str(b, "┐")
	fb_at(b, r0 + prows - 1, c0)
	fb_str(b, "└")
	fb_at(b, r0 + prows - 1, c0 + pcols - 1)
	fb_str(b, "┘")
	fb_str(b, "\x1b[39m")
	fb_fg(b, C_BORDER)
	for r in 1 ..< prows - 1 {
		fb_at(b, r0 + r, c0 + 1)
		for c in 1 ..< pcols - 1 {
			if (r + c) % 2 == 0 {
				fb_str(b, "·")
			} else {
				fb_str(b, " ")
			}
		}
	}
	iw := pcols - 2
	initial := rune('?')
	for r in name {
		initial = r
		break
	}
	if initial >= 'a' && initial <= 'z' {
		initial -= 32
	}
	nbuf: [256]u8
	badge := cut_text(tprintf("(%c)", initial), iw, nbuf[:])
	if prows >= 4 {
		cy := r0 + 1 + (prows - 4) / 2
		bx := c0 + 1 + max((iw - disp_width(badge)) / 2, 0)
		fb_at(b, cy, bx)
		fb_fg(b, C_BLUE)
		fb_str(b, "\x1b[1m")
		fb_str(b, badge)
		fb_reset(b)
		nbuf2: [256]u8
		shown := cut_text(name, iw, nbuf2[:])
		nx := c0 + 1 + max((iw - disp_width(shown)) / 2, 0)
		fb_at(b, cy + 1, nx)
		fb_fg(b, C_TEXT)
		fb_str(b, shown)
		fb_reset(b)
		return
	}
	nbuf2: [256]u8
	shown := cut_text(name, max(iw - disp_width(badge) - 1, 1), nbuf2[:])
	total := disp_width(badge) + 1 + disp_width(shown)
	lx := c0 + 1 + max((iw - total) / 2, 0)
	fb_at(b, r0 + 1, lx)
	fb_fg(b, C_BLUE)
	fb_str(b, "\x1b[1m")
	fb_str(b, badge)
	fb_reset(b)
	fb_str(b, " ")
	fb_fg(b, C_TEXT)
	fb_str(b, shown)
	fb_reset(b)
}

// Piece is one footer group: a label part and a value part. Higher
// pri is dropped first when the row is too narrow.
Piece :: struct {
	l:   string,
	lc:  int,
	lb:  bool,
	lu:  bool,
	r:   string,
	rc:  int,
	rb:  bool,
	pri: int,
}

conf_mode: LayoutMode
conf_tiles: []Tile
conf_code_tail: string
conf_code_full: string
color_idx: int = 4
help_open: bool
quit_on: bool
quit_at: time.Time

// quit_armed reports whether the quit confirmation is still pending.
quit_armed :: proc() -> bool {
	return quit_on && time.since(quit_at) < 3 * time.Second
}

// colors_now returns the selected palette size.
colors_now :: proc() -> int {
	levels := CONF_COLORS
	return levels[color_idx]
}

// code_modal_run shows the full meeting code in a modal panel and
// copies it to the clipboard at once so a broken clipboard still
// leaves the code readable for manual copying.
code_modal_run :: proc() {
	ui_modal_on()
	time.sleep(60 * time.Millisecond)
	defer ui_recover()
	copied := clip_copy(conf_code_full)
	code_w := disp_width(conf_code_full)
	for {
		b: FB
		fb_begin(&b)
		cols, rows := term_size()
		chunk_w := max(min(cols - 10, 72), 16)
		chunks := (code_w + chunk_w - 1) / chunk_w
		width := chunk_w + 6
		height := min(chunks + 4, rows - 2)
		left := (cols - width) / 2 + 1
		top := max((rows - height) / 2, 1)
		ui_panel(&b, top, left, width, height, tr("meeting code", "会议码"))
		row := top + 2
		i := 0
		for i < code_w && row < top + height - 2 {
			end := min(i + chunk_w, code_w)
			fb_at(&b, row, left + 3)
			fb_fg(&b, C_YELLOW)
			fb_str(&b, conf_code_full[i:end])
			fb_reset(&b)
			row += 1
			i = end
		}
		fb_at(&b, top + height - 2, left + 3)
		fb_fg(&b, C_DIM)
		if copied {
			fb_str(&b, tr("copied to clipboard", "已复制到剪贴板"))
		} else {
			fb_str(
				&b,
				tr(
					"clipboard unavailable, select the code above",
					"剪贴板不可用，请手动选中上方代码",
				),
			)
		}
		fb_reset(&b)
		hint_draw(
			&b,
			cols,
			rows,
			[4][2]string{{"q/Esc", tr("close", "关闭")}, {"", ""}, {"", ""}, {"", ""}},
		)
		fb_end(&b)
		k := key_next()
		if k.kind == .Quit || k.kind == .Enter {
			return
		}
		if k.kind == .Char && (k.ch == 'q' || k.ch == 'Q') {
			return
		}
	}
}

// conf_draw paints the captions, the info card and the footer in one
// synchronized frame without touching the picture areas.
conf_draw :: proc() {
	b: FB
	fb_keep(&b)
	cols, rows := term_size()
	if cols < 32 || rows < 8 {
		fb_at(&b, rows, 1)
		fb_str(&b, "\x1b[K")
		fb_fg(&b, C_RED)
		fb_str(&b, "terminal too small")
		fb_reset(&b)
		fb_end(&b)
		return
	}
	caps_draw(&b)
	footer_draw(&b)
	fb_end(&b)
}

// caps_draw paints one caption row under every picture in display
// order: the rotated order shared by every layout.
caps_draw :: proc(b: ^FB) {
	order := display_order()
	defer delete(order)
	for id, i in order {
		focused := conf_mode == .Focus && i == 0
		if id == sess.self_id {
			self_cap := CapInfo {
				t     = self_tile,
				name  = tprintf("%s (me)", sess.name),
				muted = sync.atomic_load(&mic_mute) != 0,
				sel   = focused,
				own   = true,
				empty = sync.atomic_load(&cam_off) != 0 || sync.atomic_load(&cam_ready) == 0,
			}
			if self_cap.empty {
				tile_placeholder(b, self_cap.t, sess.name)
			}
			conf_caption(b, self_cap)
			continue
		}
		p := peer_get(id)
		if p == nil {
			continue
		}
		cap := CapInfo {
			t     = p.tile,
			name  = p.info.name,
			muted = !p.info.mic,
			sel   = focused,
			empty = !p.info.cam,
		}
		if cap.empty {
			tile_placeholder(b, cap.t, p.info.name)
		}
		conf_caption(b, cap)
	}
	if screen_owner != 0 {
		p := peer_get(screen_owner)
		if p != nil && p.screen_tile.bw > 0 {
			conf_caption(
				b,
				CapInfo{t = p.screen_tile, name = tprintf("%s [sharing]", p.info.name)},
			)
		}
	} else if screen_local_on() {
		conf_caption(b, CapInfo{t = self_screen_tile, name = "screen (me) [sharing]", own = true})
	}
}

// conf_caption paints one caption on the row below a picture without
// touching the picture area.
conf_caption :: proc(b: ^FB, info: CapInfo) {
	cols, _ := term_size()
	row := info.t.cap
	left := info.t.pcol
	width := min(info.t.bw - (info.t.pcol - info.t.col), cols - left + 1)
	if row < 1 || width < 2 {
		return
	}
	fb_at(b, row, left)
	for _ in 0 ..< width {
		fb_str(b, " ")
	}
	suffix := ""
	if info.muted {
		suffix = " [muted]"
	}
	mark := ""
	if info.sel {
		mark = "▸ "
	}
	body := tprintf("%s%s", mark, info.name)
	nbuf: [256]u8
	shown := cut_text(body, max(width - 1 - disp_width(suffix), 1), nbuf[:])
	fb_at(b, row, left)
	if info.sel || info.own {
		fb_str(b, "\x1b[1m")
	}
	if info.own {
		fb_fg(b, C_BLUE)
	} else if info.sel {
		fb_fg(b, C_YELLOW)
	} else {
		fb_fg(b, C_TEXT)
	}
	fb_str(b, shown)
	if info.muted {
		fb_fg(b, C_RED)
		fb_str(b, suffix)
	}
	fb_reset(b)
}

// state_word maps a device state to its status word and color. Off is
// always red so every switch row looks the same.
state_word :: proc(enabled, active: bool) -> (string, int) {
	if !enabled {
		return tr("off", "关"), C_RED
	}
	if active {
		return tr("on", "开"), C_GREEN
	}
	return tr("off", "关"), C_RED
}

toast_buf: [96]u8
toast_len: int
toast_kind: int
toast_at: time.Time

// toast_show records a transient message for the key row. Kind 1 is
// success, 2 is failure and 0 is plain information.
toast_show :: proc(msg: string, kind: int) {
	n := min(len(msg), len(toast_buf))
	copy(toast_buf[:], msg[:n])
	toast_len = n
	toast_kind = kind
	toast_at = time.now()
}

// toast_active reports whether the toast is still on screen.
toast_active :: proc() -> bool {
	return toast_len > 0 && time.since(toast_at) < 1800 * time.Millisecond
}

// footer_draw paints the centered status row and the key row.
footer_draw :: proc(b: ^FB) {
	cols, rows := term_size()
	cam_word, cam_col := state_word(
		sync.atomic_load(&cam_ready) != 0,
		sync.atomic_load(&send_video) != 0,
	)
	mic_word, mic_col := state_word(mic_enabled, sync.atomic_load(&mic_mute) == 0)
	spk_word, spk_col := state_word(audio_ok, sync.atomic_load(&spk_mute) == 0)
	desk_word, desk_col := state_word(
		sync.atomic_load(&desk_ready) != 0,
		sync.atomic_load(&desk_send) != 0,
	)
	scr_word, scr_col := state_word(
		sync.atomic_load(&screen_ready) != 0,
		sync.atomic_load(&screen_send) != 0,
	)
	cam_pri := 5
	if sync.atomic_load(&send_video) != 0 {
		cam_pri = 1
	}
	desk_pri := 6
	if sync.atomic_load(&desk_send) != 0 {
		desk_pri = 3
	}
	scr_pri := 6
	if sync.atomic_load(&screen_send) != 0 {
		scr_pri = 3
	}
	status := make([dynamic]Piece, 0, 6)
	defer delete(status)
	append(&status, Piece{r = sess.room, rc = C_BLUE, rb = true, pri = 0})
	append(&status, Piece{l = "camera", r = cam_word, rc = cam_col, pri = 1})
	append(&status, Piece{l = "microphone", r = mic_word, rc = mic_col, pri = 2})
	append(&status, Piece{l = "speaker", r = spk_word, rc = spk_col, pri = 3})
	if sync.atomic_load(&desk_send) != 0 {
		append(&status, Piece{l = "desktop", r = "on", rc = C_GREEN, pri = 4})
	}
	if sync.atomic_load(&screen_send) != 0 {
		append(&status, Piece{l = "screen", r = "on", rc = C_GREEN, pri = 4})
	}
	row_draw(b, rows - 1, status[:], cols)
	if quit_armed() {
		pre := "press "
		post := " again to quit   any other key cancels"
		total := disp_width(pre) + disp_width(app_cfg.key_quit) + disp_width(post)
		x := max((cols - total) / 2 + 1, 1)
		fb_at(b, rows, 1)
		fb_str(b, "\x1b[K")
		fb_at(b, rows, x)
		fb_fg(b, C_RED)
		fb_str(b, "\x1b[1m")
		fb_str(b, pre)
		fb_str(b, "\x1b[4m")
		fb_str(b, app_cfg.key_quit)
		fb_str(b, "\x1b[24m")
		fb_str(b, post)
		fb_reset(b)
		return
	}
	if toast_active() {
		kind := toast_kind
		col := C_TEXT
		if kind == 1 {
			col = C_GREEN
		} else if kind == 2 {
			col = C_RED
		}
		hint := [1]Piece{{r = string(toast_buf[:toast_len]), rc = col, rb = true, pri = 0}}
		row_draw(b, rows, hint[:], cols)
		return
	}
	keys := make([dynamic]Piece, 0, 10)
	defer delete(keys)
	append(
		&keys,
		Piece {
			l = app_cfg.key_quit,
			r = "quit",
			lc = C_YELLOW,
			lb = true,
			lu = true,
			rc = C_DIM,
			pri = 1,
		},
	)
	append(
		&keys,
		Piece {
			l = app_cfg.key_share,
			r = "screen",
			lc = C_YELLOW,
			lb = true,
			lu = true,
			rc = C_DIM,
			pri = 2,
		},
	)
	append(
		&keys,
		Piece {
			l = app_cfg.key_mic,
			r = "microphone",
			lc = C_YELLOW,
			lb = true,
			lu = true,
			rc = C_DIM,
			pri = 3,
		},
	)
	append(
		&keys,
		Piece {
			l = app_cfg.key_spk,
			r = "speaker",
			lc = C_YELLOW,
			lb = true,
			lu = true,
			rc = C_DIM,
			pri = 4,
		},
	)
	append(
		&keys,
		Piece {
			l = app_cfg.key_cam,
			r = "camera",
			lc = C_YELLOW,
			lb = true,
			lu = true,
			rc = C_DIM,
			pri = 5,
		},
	)
	append(
		&keys,
		Piece {
			l = app_cfg.key_desk,
			r = "desktop",
			lc = C_YELLOW,
			lb = true,
			lu = true,
			rc = C_DIM,
			pri = 6,
		},
	)
	append(
		&keys,
		Piece {
			l = app_cfg.key_settings,
			r = "settings",
			lc = C_YELLOW,
			lb = true,
			lu = true,
			rc = C_DIM,
			pri = 7,
		},
	)
	append(
		&keys,
		Piece{l = "Tab", r = "order", lc = C_YELLOW, lb = true, lu = true, rc = C_DIM, pri = 8},
	)
	if screen_owner == 0 && !screen_local_on() {
		append(
			&keys,
			Piece {
				l = app_cfg.key_layout,
				r = "layout",
				lc = C_YELLOW,
				lb = true,
				lu = true,
				rc = C_DIM,
				pri = 9,
			},
		)
	} else {
		append(
			&keys,
			Piece {
				l = app_cfg.key_layout,
				r = "swap",
				lc = C_YELLOW,
				lb = true,
				lu = true,
				rc = C_DIM,
				pri = 9,
			},
		)
	}
	append(
		&keys,
		Piece {
			l = app_cfg.key_mirror,
			r = "mirror",
			lc = C_YELLOW,
			lb = true,
			lu = true,
			rc = C_DIM,
			pri = 10,
		},
	)
	append(
		&keys,
		Piece {
			l = app_cfg.key_help,
			r = "help",
			lc = C_YELLOW,
			lb = true,
			lu = true,
			rc = C_DIM,
			pri = 0,
		},
	)
	row_draw(b, rows, keys[:], cols)
}

// piece_width returns the printable width of one footer piece.
piece_width :: proc(p: Piece) -> int {
	w := disp_width(p.l) + disp_width(p.r)
	if p.l != "" && p.r != "" {
		w += 1
	}
	return w
}

// row_draw drops the highest priority pieces until the row fits,
// centers the rest and paints them clamped so the row never wraps.
row_draw :: proc(b: ^FB, row: int, pieces: []Piece, cols: int) {
	work := make([dynamic]Piece, 0, len(pieces))
	defer delete(work)
	for p in pieces {
		append(&work, p)
	}
	for {
		total := 0
		worst := -1
		worst_pri := 0
		for p, i in work {
			total += piece_width(p) + 2
			if p.pri > worst_pri {
				worst_pri = p.pri
				worst = i
			}
		}
		if total <= cols + 2 || worst < 0 {
			break
		}
		unordered_remove(&work, worst)
	}
	total := -2
	for p in work {
		total += piece_width(p) + 2
	}
	x := (cols - total) / 2 + 1
	if x < 1 {
		x = 1
	}
	fb_at(b, row, 1)
	for i in 0 ..< cols {
		fb_str(b, " ")
	}
	used := 0
	for p in work {
		w := piece_width(p) + 2
		if used + w > cols {
			break
		}
		if used > 0 {
			fb_at(b, row, x + used)
			fb_str(b, "  ")
			used += 2
		}
		fb_at(b, row, x + used)
		piece_draw(b, p, cols - x - used + 1)
		used += piece_width(p)
	}
	fb_reset(b)
}

// piece_draw paints one footer piece clamped to max_w cells.
piece_draw :: proc(b: ^FB, p: Piece, max_w: int) {
	used := 0
	if p.l != "" {
		lbuf: [128]u8
		shown := cut_text(p.l, max_w, lbuf[:])
		fb_fg(b, p.lc)
		if p.lb {
			fb_str(b, "\x1b[1m")
		}
		if p.lu {
			fb_str(b, "\x1b[4m")
		}
		fb_str(b, shown)
		if p.lu {
			fb_str(b, "\x1b[24m")
		}
		used += disp_width(shown)
	}
	if p.r != "" && used < max_w {
		if p.l != "" {
			fb_str(b, " ")
			used += 1
		}
		rbuf: [256]u8
		shown := cut_text(p.r, max_w - used, rbuf[:])
		fb_fg(b, p.rc)
		if p.rb {
			fb_str(b, "\x1b[1m")
		}
		fb_str(b, shown)
	}
	fb_reset(b)
}

// help_draw paints the full screen key cheat sheet.
help_draw :: proc() {
	b: FB
	fb_begin(&b)
	cols, rows := term_size()
	lines := [17][2]string {
		{"", "media"},
		{app_cfg.key_mic, "toggle microphone mute"},
		{app_cfg.key_spk, "toggle speaker mute"},
		{app_cfg.key_cam, "toggle camera send"},
		{app_cfg.key_desk, "toggle system audio sharing"},
		{app_cfg.key_share, "toggle screen sharing"},
		{app_cfg.key_settings, "open the settings page"},
		{"Up/Down", "raise or lower volume"},
		{"", "layout"},
		{app_cfg.key_layout, "switch grid and focus layouts or swap the share side"},
		{"Tab", "rotate the member order"},
		{app_cfg.key_mirror, "toggle mirrored self view"},
		{"", "other"},
		{app_cfg.key_code, "show and copy the meeting code"},
		{app_cfg.key_help, "show or hide this page"},
		{app_cfg.key_quit, "quit after one confirmation"},
		{"", ""},
	}
	width := min(56, cols - 2)
	height := len(lines) + 3
	if width < 32 || rows < height {
		ui_small(&b, "Terminal too small for help")
		fb_end(&b)
		return
	}
	left := (cols - width) / 2 + 1
	top := max((rows - height) / 2, 1)
	ui_panel(&b, top, left, width, height, "toom — meeting keys")
	for line, i in lines {
		if line[0] == "" && line[1] == "" {
			continue
		}
		fb_at(&b, top + 2 + i, left + 3)
		if line[0] == "" {
			fb_fg(&b, C_MAUVE)
			fb_str(&b, "\x1b[1m")
			fb_str(&b, line[1])
			fb_reset(&b)
			continue
		}
		kbuf: [32]u8
		dbuf: [128]u8
		fb_fg(&b, C_YELLOW)
		fb_str(&b, "\x1b[1m")
		fb_str(&b, cut_text(line[0], 9, kbuf[:]))
		fb_reset(&b)
		fb_at(&b, top + 2 + i, left + 14)
		fb_fg(&b, C_TEXT)
		fb_str(&b, cut_text(line[1], width - 17, dbuf[:]))
		fb_reset(&b)
	}
	fb_end(&b)
}
