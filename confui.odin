package toom

import "core:sync"
import "core:time"

CONF_COLORS :: [7]int{2, 8, 16, 32, 64, 128, 256}

// CapInfo is one caption rendered on the row below a picture.
CapInfo :: struct {
	t:     Tile,
	name:  string,
	muted: bool,
	sel:   bool,
}

// Piece is one footer group: a label part and a value part. Higher
// pri is dropped first when the row is too narrow.
Piece :: struct {
	l:   string,
	lc:  int,
	lb:  bool,
	r:   string,
	rc:  int,
	rb:  bool,
	pri: int,
}

conf_mode:      LayoutMode
conf_focus:     int
conf_tiles:     []Tile
conf_card:      Tile
conf_has_card:  bool
conf_code_tail: string
color_idx:      int = 4
help_open:      bool
quit_on:        bool
quit_at:        time.Time

// quit_armed reports whether the quit confirmation is still pending.
quit_armed :: proc() -> bool {
	return quit_on && time.since(quit_at) < 3 * time.Second
}

// colors_now returns the selected palette size.
colors_now :: proc() -> int {
	levels := CONF_COLORS
	return levels[color_idx]
}

// conf_draw paints the captions, the info card and the footer in one
// synchronized frame without touching the picture areas.
conf_draw :: proc(backend: string) {
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
	card_draw(&b)
	footer_draw(&b, backend)
	fb_end(&b)
}

// caps_draw paints one caption row under every picture in display
// order: self first, then peers by rising id.
caps_draw :: proc(b: ^FB) {
	ids := peer_ids_sorted()
	defer delete(ids)
	self_cap := CapInfo{
		t = self_tile,
		name = tprintf("%s (me)", sess.name),
		muted = sync.atomic_load(&mic_mute) != 0,
		sel = conf_focus == 0,
	}
	conf_caption(b, self_cap)
	for id, i in ids {
		p := peer_get(id)
		if p == nil {
			continue
		}
		cap := CapInfo{
			t = p.tile,
			name = p.info.name,
			muted = !p.info.mic,
			sel = conf_focus == i + 1,
		}
		conf_caption(b, cap)
	}
}

// conf_caption paints one caption on the row below a picture without
// touching the picture area.
conf_caption :: proc(b: ^FB, info: CapInfo) {
	cols, _ := term_size()
	row := info.t.cap
	left := info.t.col
	width := min(info.t.bw, cols - left + 1)
	if row < 1 || width < 2 {
		return
	}
	fb_at(b, row, left)
	for _ in 0..<width {
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
	if info.sel {
		fb_fg(b, C_YELLOW)
		fb_str(b, "\x1b[1m")
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

// card_draw paints the room info card inside the first empty grid
// block.
card_draw :: proc(b: ^FB) {
	if !conf_has_card {
		return
	}
	t := conf_card
	if t.bw < 22 || t.bh < 7 {
		return
	}
	ui_panel(b, t.row, t.col, t.bw, t.bh, "room info")
	rbuf: [256]u8
	fb_at(b, t.row + 2, t.col + 2)
	fb_fg(b, C_DIM)
	fb_str(b, "room ")
	fb_fg(b, C_TEXT)
	fb_str(b, cut_text(sess.room, t.bw - 9, rbuf[:]))
	fb_at(b, t.row + 3, t.col + 2)
	fb_fg(b, C_DIM)
	fb_str(b, "code ")
	fb_fg(b, C_YELLOW)
	fb_str(b, conf_code_tail)
	fb_at(b, t.row + 4, t.col + 2)
	fb_fg(b, C_DIM)
	fb_str(b, tprintf("tx %d  rx %d", sync.atomic_load(&tx_audio_n), sync.atomic_load(&rx_audio_n)))
	fb_reset(b)
}

// footer_draw paints the status row and the key row above the bottom
// edge.
footer_draw :: proc(b: ^FB, backend: string) {
	cols, rows := term_size()
	cam_mark, cam_col := state_mark(sync.atomic_load(&cam_ready) != 0, sync.atomic_load(&send_video) != 0)
	mic_mark, mic_col := state_mark(mic_enabled, sync.atomic_load(&mic_mute) == 0)
	spk_mark, spk_col := state_mark(audio_ok, sync.atomic_load(&spk_mute) == 0)
	members := 1 + peer_count()
	status := make([dynamic]Piece, 0, 10)
	defer delete(status)
	append(&status, Piece{r = sess.room, rc = C_BLUE, rb = true, pri = 0})
	append(&status, Piece{r = tprintf("%d", members), rc = C_TEXT, pri = 0})
	append(&status, Piece{l = "cam", r = cam_mark, rc = cam_col, pri = 1})
	append(&status, Piece{l = "mic", r = mic_mark, rc = mic_col, pri = 1})
	append(&status, Piece{r = level_bar(int(sync.atomic_load(&cap_level))), rc = C_GREEN, pri = 2})
	append(&status, Piece{l = "spk", r = spk_mark, rc = spk_col, pri = 1})
	append(&status, Piece{r = level_bar(int(sync.atomic_load(&rx_level))), rc = C_GREEN, pri = 2})
	append(&status, Piece{r = backend, rc = C_DIM, pri = 3})
	append(&status, Piece{r = tprintf("%dc", colors_now()), rc = C_DIM, pri = 3})
	append(&status, Piece{
		r = tprintf("tx %d rx %d", sync.atomic_load(&tx_audio_n), sync.atomic_load(&rx_audio_n)),
		rc = C_DIM,
		pri = 4,
	})
	row_draw(b, rows - 1, status[:], cols)
	if quit_armed() {
		hint := [1]Piece{{r = "press q again to quit   any other key cancels", rc = C_RED, rb = true, pri = 0}}
		row_draw(b, rows, hint[:], cols)
		return
	}
	keys := make([dynamic]Piece, 0, 8)
	defer delete(keys)
	append(&keys, Piece{l = "q", r = "quit", lc = C_YELLOW, lb = true, rc = C_DIM, pri = 1})
	append(&keys, Piece{l = "m", r = "spk", lc = C_YELLOW, lb = true, rc = C_DIM, pri = 2})
	append(&keys, Piece{l = "n", r = "mic", lc = C_YELLOW, lb = true, rc = C_DIM, pri = 3})
	append(&keys, Piece{l = "c", r = "cam", lc = C_YELLOW, lb = true, rc = C_DIM, pri = 4})
	append(&keys, Piece{l = "f", r = "layout", lc = C_YELLOW, lb = true, rc = C_DIM, pri = 5})
	append(&keys, Piece{l = "j/k", r = "colors", lc = C_YELLOW, lb = true, rc = C_DIM, pri = 6})
	append(&keys, Piece{l = "Tab ←/→", r = "pick", lc = C_YELLOW, lb = true, rc = C_DIM, pri = 7})
	append(&keys, Piece{l = "?", r = "help", lc = C_YELLOW, lb = true, rc = C_DIM, pri = 0})
	row_draw(b, rows, keys[:], cols)
}

// state_mark maps a device state to its mark and color.
state_mark :: proc(enabled, active: bool) -> (string, int) {
	if !enabled {
		return "○", C_DIM
	}
	if active {
		return "●", C_GREEN
	}
	return "○", C_RED
}

// piece_width returns the printable width of one footer piece.
piece_width :: proc(p: Piece) -> int {
	w := disp_width(p.l) + disp_width(p.r)
	if p.l != "" && p.r != "" {
		w += 1
	}
	return w
}

// row_draw drops the highest priority pieces until the row fits and
// paints the rest. Painting is width clamped so the row never wraps.
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
	fb_at(b, row, 1)
	for _ in 0..<cols {
		fb_str(b, " ")
	}
	fb_at(b, row, 1)
	used := 0
	for p in work {
		if used + piece_width(p) + 2 > cols {
			break
		}
		if used > 0 {
			fb_str(b, "  ")
			used += 2
		}
		piece_draw(b, p, cols - used)
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
		fb_str(b, shown)
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
	lines := [13][2]string{
		{"", "media"},
		{"m", "toggle speaker mute"},
		{"n", "toggle microphone mute"},
		{"c", "toggle camera send"},
		{"Up/Down", "raise or lower volume"},
		{"", "layout"},
		{"f", "cycle grid and focus layouts"},
		{"Tab ←/→", "pick the focused member"},
		{"", "other"},
		{"j/k", "decrease or increase color count"},
		{"?", "show or hide this page"},
		{"q/Esc", "quit after one confirmation"},
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
