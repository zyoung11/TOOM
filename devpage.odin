package toom

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import ma "../Aideo/miniaudio"

device_folders := [3]string{"Audio input", "Audio output", "Camera"}

// DevEnt is one entry in a device folder list.
DevEnt :: struct {
	name:      string,
	path:      string,
	id:        ma.device_id,
	is_default: bool,
}

dev_lists:  [3][dynamic]DevEnt
dev_cur:    [3]int
dev_sel:    [3]int
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
		append(&out, DevEnt{name = cstr_dup(&d.name[0]), id = d.id})
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
	for f in 0..<3 {
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



// dev_dir remembers the folder column cursor across menu visits.
dev_dir: int

// dev_off remembers the scroll position of every folder list.
dev_off: [3]int

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
			fb_str(&b, "Devices")
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
			dev_sel[folder] = dev_cur[folder]
			if folder == 2 && dev_cur[2] < len(dev_lists[2]) {
				cam_sel = dev_cur[2]
				cam_dev = dev_lists[2][dev_cur[2]].path
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
