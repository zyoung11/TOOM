package toom

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "core:sync"
import ma "../Aideo/miniaudio"

device_folders := [7]string{"Audio input", "Audio output", "Camera", "Share", "Display", "Meeting", "Windows"}

// DevEnt is one entry in a device folder list.
DevEnt :: struct {
	name:      string,
	path:      string,
	id:        ma.device_id,
	is_default: bool,
}

dev_lists:  [7][dynamic]DevEnt
mon_list:   [dynamic]DevEnt
dev_cur:    [7]int
dev_sel:    [7]int
dev_inited: bool
cam_sel:    int

// cstr_dup copies a NUL terminated char buffer into a string.
cstr_dup :: proc(chars: rawptr) -> string {
	p := ([^]u8)(chars)
	buf: [256]u8
	n := 0
	for n < 255 && p[n] != 0 {
		buf[n] = p[n]
		n += 1
	}
	return strings.clone(string(buf[:n]))
}

// id_str views a Pulse device id as a NUL terminated name.
id_str :: proc(id: ^ma.device_id) -> string {
	n := 0
	for n < len(id.pulse) && id.pulse[n] != 0 {
		n += 1
	}
	return string(([^]u8)(&id.pulse[0])[:n])
}

// id_is_monitor reports whether a device id points at a sink monitor
// loopback source. Pulse monitor sources end with ".monitor".
id_is_monitor :: proc(id: ^ma.device_id) -> bool {
	suffix := ".monitor"
	s := id.pulse[:]
	n := 0
	for n < len(s) && s[n] != 0 {
		n += 1
	}
	if n < len(suffix) {
		return false
	}
	for i in 0..<len(suffix) {
		if s[n - len(suffix) + i] != c.char(suffix[i]) {
			return false
		}
	}
	return true
}

// audio_enum_devs lists the audio devices of one direction. The first
// entry is always the system default. Capture lists hide the sink
// monitor loopback sources.
audio_enum_devs :: proc(capture: bool) -> [dynamic]DevEnt {
	out := make([dynamic]DevEnt, 0, 8)
	append(&out, DevEnt{name = "System default", is_default = true})
	ctx: ma.context_type
	if ma.context_init(nil, 0, nil, &ctx) != .SUCCESS {
		return out
	}
	defer ma.context_uninit(&ctx)
	pdevs: [^]ma.device_info
	pcount: u32
	cdevs: [^]ma.device_info
	ccount: u32
	if ma.context_get_devices(&ctx, &pdevs, &pcount, &cdevs, &ccount) != .SUCCESS {
		return out
	}
	list := pdevs
	n := int(pcount)
	if capture {
		list = cdevs
		n = int(ccount)
	}
	for i in 0..<n {
		d := list[i]
		if capture && id_is_monitor(&d.id) {
			continue
		}
		append(&out, DevEnt{name = cstr_dup(&d.name[0]), id = d.id, is_default = bool(d.isDefault)})
	}
	return out
}

// audio_enum_mon lists the sink monitor loopback sources used for
// system audio sharing.
audio_enum_mon :: proc() -> [dynamic]DevEnt {
	out := make([dynamic]DevEnt, 0, 4)
	ctx: ma.context_type
	if ma.context_init(nil, 0, nil, &ctx) != .SUCCESS {
		return out
	}
	defer ma.context_uninit(&ctx)
	pdevs: [^]ma.device_info
	pcount: u32
	cdevs: [^]ma.device_info
	ccount: u32
	if ma.context_get_devices(&ctx, &pdevs, &pcount, &cdevs, &ccount) != .SUCCESS {
		return out
	}
	for i in 0..<int(ccount) {
		d := cdevs[i]
		if id_is_monitor(&d.id) {
			append(&out, DevEnt{name = cstr_dup(&d.name[0]), id = d.id})
		}
	}
	return out
}

// cam_enum_devs lists the V4L2 capture devices.
cam_enum_devs :: proc() -> [dynamic]DevEnt {
	out := make([dynamic]DevEnt, 0, 4)
	for i in 0..<32 {
		path := fmt.tprintf("/dev/video%d", i)
		buf: [256]u8
		n := min(len(path), 255)
		copy(buf[:], path[:n])
		buf[n] = 0
		fd := cam_open_dev(cast(cstring)&buf[0])
		if fd < 0 {
			continue
		}
		cap: V4l2Capability
		if cam_ioctl(fd, VIDIOC_QUERYCAP, &cap) == 0 && (cap.device_caps & V4L2_CAP_VIDEO_CAPTURE) != 0 {
			append(&out, DevEnt{name = cstr_dup(&cap.card[0]), path = strings.clone(path)})
		}
		cam_close(fd)
	}
	return out
}

// dev_init enumerates every device folder once per program run.
dev_init :: proc() {
	if dev_inited {
		return
	}
	dev_lists[0] = audio_enum_devs(true)
	dev_lists[1] = audio_enum_devs(false)
	dev_lists[2] = cam_enum_devs()
	mon_list = audio_enum_mon()
	dev_share_init()
	dev_settings_init()
	for f in 0..<7 {
		dev_sel[f] = 0
		dev_cur[f] = 0
	}
	for e, i in dev_lists[2] {
		if e.path == cam_dev {
			dev_sel[2] = i
			dev_cur[2] = i
		}
	}
	dev_inited = true
}



// dev_share_init fills the share folder with the outputs and the
// region and cursor settings.
dev_share_init :: proc() {
	outs := screen_outputs()
	defer delete(outs)
	for o in outs {
		append(&dev_lists[3], DevEnt{name = strings.clone(o), path = strings.clone(o)})
	}
	append(&dev_lists[3], DevEnt{name = strings.clone("cursor: show"), path = strings.clone("cursor")})
}

// dev_share_pick applies one pick inside the share folder.
dev_share_pick :: proc(idx: int) {
	if idx < 0 || idx >= len(dev_lists[3]) {
		return
	}
	e := &dev_lists[3][idx]
	if e.path == "cursor" {
		sync.atomic_store(&share_cursor, 1 - sync.atomic_load(&share_cursor))
		if sync.atomic_load(&share_cursor) != 0 {
			dev_set_name(e, "cursor: show")
		} else {
			dev_set_name(e, "cursor: hide")
		}
		share_apply()
	} else {
		dev_sel[3] = idx
		share_output = strings.clone(e.path)
		share_apply()
	}
}

// dev_set_name replaces one entry label with a fresh clone.
dev_set_name :: proc(e: ^DevEnt, s: string) {
	delete(e.name)
	e.name = strings.clone(s)
}

// dev_settings_init fills the display and meeting folders with the
// runtime settings.
dev_settings_init :: proc() {
	append(&dev_lists[4], DevEnt{name = strings.clone("mirror"), path = strings.clone("mirror")})
	append(&dev_lists[4], DevEnt{name = strings.clone("colors"), path = strings.clone("colors")})
	append(&dev_lists[4], DevEnt{name = strings.clone("layout"), path = strings.clone("layout")})
	append(&dev_lists[4], DevEnt{name = strings.clone("volume"), path = strings.clone("volume")})
	append(&dev_lists[5], DevEnt{name = strings.clone("camera"), path = strings.clone("camera")})
	append(&dev_lists[5], DevEnt{name = strings.clone("microphone"), path = strings.clone("microphone")})
	append(&dev_lists[5], DevEnt{name = strings.clone("speaker"), path = strings.clone("speaker")})
	append(&dev_lists[5], DevEnt{name = strings.clone("system audio"), path = strings.clone("dshare")})
	append(&dev_lists[5], DevEnt{name = strings.clone("screen share"), path = strings.clone("screen")})
	dev_settings_refresh()
}

// dev_settings_refresh rewrites the setting labels with the current
// values.
dev_settings_refresh :: proc() {
	for i in 0..<len(dev_lists[4]) {
		e := &dev_lists[4][i]
		switch e.path {
		case "mirror":
			v := "off"
			if sync.atomic_load(&self_mirror) != 0 {
				v = "on"
			}
			dev_set_name(e, tprintf("mirror: %s", v))
		case "colors":
			dev_set_name(e, tprintf("colors: %d", colors_now()))
		case "layout":
			v := "grid"
			if conf_mode == .Focus {
				v = "focus"
			}
			dev_set_name(e, tprintf("layout: %s", v))
		case "volume":
			vol := transmute(f32)u32(sync.atomic_load(&spk_vol_bits))
			dev_set_name(e, tprintf("volume: %d%%", int(vol * 100)))
		}
	}
	for i in 0..<len(dev_lists[5]) {
		e := &dev_lists[5][i]
		switch e.path {
		case "camera":
			v := "off"
			if sync.atomic_load(&send_video) != 0 {
				v = "on"
			}
			dev_set_name(e, tprintf("camera: %s", v))
		case "microphone":
			v := "off"
			if mic_enabled {
				if sync.atomic_load(&mic_mute) == 0 {
					v = "on"
				} else {
					v = "muted"
				}
			}
			dev_set_name(e, tprintf("microphone: %s", v))
		case "speaker":
			v := "muted"
			if sync.atomic_load(&spk_mute) == 0 {
				v = "on"
			}
			dev_set_name(e, tprintf("speaker: %s", v))
		case "dshare":
			v := "off"
			if sync.atomic_load(&desk_send) != 0 {
				v = "on"
			}
			dev_set_name(e, tprintf("system audio: %s", v))
		case "screen":
			v := "off"
			if sync.atomic_load(&screen_send) != 0 {
				v = "on"
			}
			dev_set_name(e, tprintf("screen share: %s", v))
		}
	}
}

// dev_display_pick applies one display setting pick.
dev_display_pick :: proc(idx: int) {
	if idx < 0 || idx >= len(dev_lists[4]) {
		return
	}
	switch dev_lists[4][idx].path {
	case "mirror":
		conf_key(Key{kind = .Char, ch = 'h'})
	case "colors":
		if color_idx >= len(CONF_COLORS) - 1 {
			color_idx = 0
			colors_apply()
			toast_show(tprintf("colors %d", colors_now()), 0)
		} else {
			conf_key(Key{kind = .Char, ch = 'k'})
		}
	case "layout":
		conf_key(Key{kind = .Char, ch = 'f'})
	case "volume":
		conf_key(Key{kind = .Up})
	}
	dev_settings_refresh()
}

// dev_meeting_pick applies one meeting setting pick.
dev_meeting_pick :: proc(idx: int) {
	if idx < 0 || idx >= len(dev_lists[5]) {
		return
	}
	switch dev_lists[5][idx].path {
	case "camera":
		conf_key(Key{kind = .Char, ch = 'c'})
	case "microphone":
		conf_key(Key{kind = .Char, ch = 'n'})
	case "speaker":
		conf_key(Key{kind = .Char, ch = 'm'})
	case "dshare":
		conf_key(Key{kind = .Char, ch = 'a'})
	case "screen":
		conf_key(Key{kind = .Char, ch = 's'})
	}
	dev_settings_refresh()
}

// dev_windows_refresh rebuilds the Windows folder from the window
// provider snapshot.
dev_windows_refresh :: proc() {
	for e in dev_lists[6] {
		delete(e.name)
		delete(e.path)
	}
	clear(&dev_lists[6])
	for e in win_entries {
		delete(e.title)
		delete(e.app)
		delete(e.output)
	}
	clear(&win_entries)
	append(&dev_lists[6], DevEnt{name = strings.clone("whole output"), path = strings.clone("output")})
	if !win_use() {
		append(&dev_lists[6], DevEnt{name = strings.clone("no window source"), path = strings.clone("none")})
		return
	}
	win_entries = win_list()
	for w, i in win_entries {
		label := w.title
		if label == "" {
			label = w.app
		}
		append(&dev_lists[6], DevEnt{name = strings.clone(tprintf("%d. %s", i + 1, label)), path = strings.clone(tprintf("%d", i + 1))})
	}
}

// dev_windows_pick applies one window share pick.
dev_windows_pick :: proc(idx: int) {
	if idx < 0 || idx >= len(dev_lists[6]) {
		return
	}
	dev_sel[6] = idx
	if idx == 0 {
		share_window = 0
		toast_show("sharing the whole output", 1)
	} else {
		w := win_entries[idx - 1]
		share_window = w.id
		toast_show(tprintf("sharing window %s", w.title), 1)
	}
	share_apply()
}

// dev_dir remembers the folder column cursor across menu visits.
dev_dir: int

// dev_off remembers the scroll position of every folder list.
dev_off: [7]int

// scroll_offset keeps the cursor visible with the smallest move.
scroll_offset :: proc(offset, cursor, list_h: int) -> int {
	if list_h <= 0 {
		return 0
	}
	if cursor < offset {
		return cursor
	}
	if cursor >= offset + list_h {
		return cursor - list_h + 1
	}
	return offset
}

// cut_dot shortens text to width and marks the cut with three dots.
cut_dot :: proc(s: string, width: int, buf: []u8) -> string {
	if disp_width(s) <= width {
		return s
	}
	n := 0
	used := 0
	for r in s {
		w := char_width(r)
		if used + w > width - 3 {
			break
		}
		b, k := utf8.encode_rune(r)
		for i in 0..<k {
			buf[n] = b[i]
			n += 1
		}
		used += w
	}
	copy(buf[n:], "...")
	return string(buf[:n + 3])
}

// dev_move shifts the cursor of the focused column.
dev_move :: proc(folder: ^int, inside: bool, delta: int) {
	if !inside {
		folder^ = (folder^ + delta + len(device_folders)) % len(device_folders)
		return
	}
	n := len(dev_lists[folder^])
	if n > 0 {
		dev_cur[folder^] = (dev_cur[folder^] + delta + n) % n
	}
}

// dev_run opens the device menu in the nz and BM browser style: the
// folder column first, a dimmed preview of the highlighted folder on
// the right, reverse video cursor bars and per folder position memory.
// Enter or Space marks the chosen device and the menu stays open.
dev_run :: proc() {
	dev_init()
	dev_windows_refresh()
	folder := dev_dir
	inside := false
	need_draw := true
	for {
		if need_draw {
			tmp := runtime.default_temp_allocator_temp_begin()
			defer runtime.default_temp_allocator_temp_end(tmp)
			b: FB
			fb_begin(&b)
			cols, rows := term_size()
			if cols < 40 || rows < 10 {
				ui_small(&b, "Terminal too small, need at least 40x10")
				fb_end(&b)
				need_draw = false
				continue
			}
			fb_at(&b, 1, max((cols - 7) / 2, 1))
			fb_str(&b, "\x1b[1m")
			fb_fg(&b, C_BLUE)
			fb_str(&b, "Settings")
			fb_reset(&b)
			list_h := rows - 4

			folder_w := 0
			for name, i in device_folders {
				w := disp_width("▸ ") + disp_width(name) + 1
				if dev_sel[i] != 0 {
					w += 1
				}
				folder_w = max(folder_w, w)
			}
			folder_w = min(folder_w + 1, cols / 2)
			folder_x := 2
			list_x := folder_x + folder_w + 1
			list_w := max(cols - list_x - 1, 10)

			nbuf: [512]u8
			dev_off[folder] = scroll_offset(dev_off[folder], dev_cur[folder], list_h)
			folder_off := scroll_offset(0, folder, list_h)

			for row in 0..<list_h {
				y := row + 3
				idx := folder_off + row
				if idx < len(device_folders) {
					name := device_folders[idx]
					mark := "▸ "
					if dev_sel[idx] != 0 {
						mark = "✓ "
					}
					line := tprintf("%s%s", mark, cut_dot(tprintf("%s/", name), folder_w - disp_width(mark), nbuf[:]))
					cursor := idx == folder && !inside
					dev_cell(&b, folder_x, y, folder_w, line, cursor, false, inside)
				}
				if inside {
					e := dev_lists[folder]
					idx2 := dev_off[folder] + row
					if idx2 < len(e) {
						mark := "  "
						if dev_sel[folder] == idx2 {
							mark = "✓ "
						}
						line := tprintf("%s%s", mark, cut_dot(e[idx2].name, list_w - disp_width(mark), nbuf[:]))
						cursor := idx2 == dev_cur[folder]
						dev_cell(&b, list_x, y, list_w, line, cursor, dev_sel[folder] == idx2, false)
					}
				} else {
					e := dev_lists[folder]
					idx2 := dev_off[folder] + row
					if idx2 < len(e) {
						mark := "  "
						if dev_sel[folder] == idx2 {
							mark = "✓ "
						}
						line := tprintf("%s%s", mark, cut_dot(e[idx2].name, list_w - disp_width(mark), nbuf[:]))
						dev_cell(&b, list_x, y, list_w, line, false, dev_sel[folder] == idx2, true)
					}
				}
			}

			total := len(device_folders)
			soff := folder_off
			if inside {
				total = len(dev_lists[folder])
				soff = dev_off[folder]
			}
			dev_scrollbar(&b, cols, 3, list_h, total, soff)
			dev_hint(&b, cols, rows)
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
		pick := false
		#partial switch k.kind {
		case .Quit:
			dev_dir = folder
			return
		case .Tab:
			inside = !inside
		case .Left:
			inside = false
		case .Right:
			inside = true
		case .Up:
			dev_move(&folder, inside, -1)
		case .Down:
			dev_move(&folder, inside, 1)
		case .Enter:
			if !inside {
				inside = true
			} else {
				pick = true
			}
		case .Char:
			switch k.ch {
			case 'q', 'Q':
				dev_dir = folder
				return
			case 'h', 'H':
				inside = false
			case 'l', 'L':
				inside = true
			case 'j', 'J':
				dev_move(&folder, inside, 1)
			case 'k', 'K':
				dev_move(&folder, inside, -1)
			case ' ':
				if !inside {
					inside = true
				} else {
					pick = true
				}
			}
		}
		if pick {
			if folder == 3 {
				dev_share_pick(dev_cur[3])
			} else if folder == 6 {
				dev_windows_pick(dev_cur[6])
			} else if folder == 4 {
				dev_display_pick(dev_cur[4])
			} else if folder == 5 {
				dev_meeting_pick(dev_cur[5])
			} else {
				dev_sel[folder] = dev_cur[folder]
				if folder == 2 && dev_cur[2] < len(dev_lists[2]) {
					cam_sel = dev_cur[2]
					cam_dev = dev_lists[2][dev_cur[2]].path
				}
			}
			dev_move(&folder, inside, 1)
		}
	}
}

// dev_cell draws one padded cell with the reverse video cursor bar.
dev_cell :: proc(b: ^FB, x, y, width: int, line: string, cursor, chosen, dim: bool) {
	nbuf: [512]u8
	shown := cut_dot(line, width, nbuf[:])
	fb_at(b, y, x)
	if chosen {
		fb_fg(b, C_GREEN)
	}
	if cursor {
		fb_str(b, "\x1b[7m")
	}
	if dim {
		fb_str(b, "\x1b[2m")
	}
	fb_str(b, shown)
	for i in disp_width(shown)..<width {
		fb_str(b, " ")
	}
	fb_reset(b)
}

// dev_scrollbar draws the scroll indicator on the right screen edge.
dev_scrollbar :: proc(b: ^FB, cols, top, list_h, total, offset: int) {
	thumb_size := 0
	thumb_start := 0
	if total > list_h {
		thumb_size = max(list_h * list_h / total, 1)
		scroll_range := total - list_h
		thumb_range := list_h - thumb_size
		if scroll_range > 0 {
			thumb_start = offset * thumb_range / scroll_range
		}
	}
	for i in 0..<list_h {
		cell := "│"
		if total <= list_h {
			cell = " "
		} else if i >= thumb_start && i < thumb_start + thumb_size {
			cell = "┃"
		}
		fb_at(b, top + i, cols)
		fb_fg(b, C_BORDER)
		fb_str(b, cell)
		fb_reset(b)
	}
}

// dev_hint draws the operation hints on the bottom line.
dev_hint :: proc(b: ^FB, cols, rows: int) {
	fb_at(b, rows, 1)
	fb_str(b, "\x1b[K")
	items := [4][2]string{
		{"h/j/k/l, arrows", "move"},
		{"Enter", "open or select"},
		{"Space", "select"},
		{"q", "back"},
	}
	total := 0
	for it in items {
		total += disp_width(it[0]) + 1 + disp_width(it[1]) + 4
	}
	x := max((cols - total) / 2, 1)
	for it in items {
		fb_at(b, rows, x)
		fb_fg(b, C_YELLOW)
		fb_str(b, it[0])
		fb_fg(b, C_DIM)
		fb_str(b, " ")
		fb_str(b, it[1])
		fb_reset(b)
		x += disp_width(it[0]) + 1 + disp_width(it[1]) + 4
	}
}
