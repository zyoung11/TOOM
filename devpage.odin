package toom

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"
import ma "../Aideo/miniaudio"

device_folders := [3]string{"Sound", "Display", "Share"}

// DevKind names one settings row and drives its behavior.
DevKind :: enum u8 {
	Mic,
	Spk,
	DeskShare,
	Cam,
	Mirror,
	Cursor,
	Volume,
	Colors,
	Layout,
	AudioIn,
	AudioOut,
	CamDev,
	Target,
}

// dev_row_kinds lists the settings rows of every group in display
// order.
dev_row_kinds := [3][]DevKind{
	{.Mic, .Spk, .DeskShare, .Volume, .AudioIn, .AudioOut},
	{.Cam, .Mirror, .Colors, .Layout, .CamDev},
	{.Cursor, .Target},
}

// DevEnt is one option inside a modal picker.
DevEnt :: struct {
	name:       string,
	dev:        string,
	win:        u64,
	id:         ma.device_id,
	is_default: bool,
	picked:     bool,
}

// DevPick remembers one picked device for a picker row. An empty use
// id marks the system default choice.
DevPick :: struct {
	id:   ma.device_id,
	name: string,
	use:  string,
}

// DevSub is the modal single choice picker.
DevSub :: struct {
	open:  bool,
	kind:  DevKind,
	title: string,
	opts:  [dynamic]DevEnt,
	cur:   int,
	off:   int,
}

// DevEdit is the modal number editor.
DevEdit :: struct {
	open:  bool,
	kind:  DevKind,
	title: string,
	text:  [dynamic]rune,
	cur:   int,
}

dev_dir:   int
dev_row:   [3]int
dev_pick:  [2]DevPick
dev_sub:   DevSub
dev_edit:  DevEdit
dev_cam_name:    string
dev_target_name: string

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
	append(&out, DevEnt{name = strings.clone("System default"), is_default = true})
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

// cam_enum_devs lists the V4L2 capture devices. Nodes sharing one bus
// address belong to the same physical camera, so only the first
// capture node per bus address is listed.
cam_enum_devs :: proc() -> [dynamic]DevEnt {
	out := make([dynamic]DevEnt, 0, 4)
	seen: [dynamic]string
	defer {
		for s in seen {
			delete(s)
		}
		delete(seen)
	}
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
			bus := cstr_dup(&cap.bus_info[0])
			dup := false
			for s in seen {
				if s == bus {
					dup = true
					break
				}
			}
			if dup {
				delete(bus)
			} else {
				append(&seen, bus)
				append(&out, DevEnt{name = cstr_dup(&cap.card[0]), dev = strings.clone(path)})
			}
		}
		cam_close(fd)
	}
	return out
}

cam_dev_owned: bool

// cam_set installs the active camera path with owned storage.
cam_set :: proc(path: string) {
	if cam_dev_owned {
		delete(cam_dev)
	}
	cam_dev = strings.clone(path)
	cam_dev_owned = true
}

// dev_audio_id returns the picked audio device id of one direction.
// ok is false when the system default is picked.
dev_audio_id :: proc(capture: bool) -> (ma.device_id, bool) {
	idx := 0
	if !capture {
		idx = 1
	}
	if dev_pick[idx].use == "" {
		return {}, false
	}
	return dev_pick[idx].id, true
}

// dev_list_free releases one option list with its cloned strings.
dev_list_free :: proc(l: ^[dynamic]DevEnt) {
	for e in l^ {
		if len(e.name) > 0 {
			delete(e.name)
		}
		if len(e.dev) > 0 {
			delete(e.dev)
		}
	}
	delete(l^)
	l^ = nil
}

// dev_win_refresh reloads the window snapshot used by the share
// target picker.
dev_win_refresh :: proc() {
	for e in win_entries {
		delete(e.title)
		delete(e.app)
		delete(e.output)
	}
	clear(&win_entries)
	if win_use() {
		win_entries = win_list()
	}
}

// dev_sub_open builds the options of one picker and shows it.
dev_sub_open :: proc(kind: DevKind) {
	dev_sub.kind = kind
	dev_sub.open = true
	dev_sub.cur = 0
	dev_sub.off = 0
	dev_list_free(&dev_sub.opts)
	#partial switch kind {
	case .AudioIn:
		dev_sub.title = "input device"
		opts := audio_enum_devs(true)
		for &e in opts {
			e.picked = (e.is_default && dev_pick[0].use == "") || (!e.is_default && id_str(&e.id) == dev_pick[0].use)
			if e.picked {
				dev_sub.cur = len(dev_sub.opts)
			}
			append(&dev_sub.opts, e)
		}
		delete(opts)
	case .AudioOut:
		dev_sub.title = "output device"
		opts := audio_enum_devs(false)
		for &e in opts {
			e.picked = (e.is_default && dev_pick[1].use == "") || (!e.is_default && id_str(&e.id) == dev_pick[1].use)
			if e.picked {
				dev_sub.cur = len(dev_sub.opts)
			}
			append(&dev_sub.opts, e)
		}
		delete(opts)
	case .CamDev:
		dev_sub.title = "camera device"
		opts := cam_enum_devs()
		for &e in opts {
			e.picked = e.dev == cam_dev
			if e.picked {
				dev_sub.cur = len(dev_sub.opts)
			}
			append(&dev_sub.opts, e)
		}
		delete(opts)
	case .Colors:
		dev_sub.title = "color count"
		for lv, i in CONF_COLORS {
			append(&dev_sub.opts, DevEnt{name = strings.clone(tprintf("%d colors", lv)), picked = i == color_idx})
			if i == color_idx {
				dev_sub.cur = len(dev_sub.opts) - 1
			}
		}
	case .Target:
		dev_sub.title = "share target"
		outs := screen_outputs()
		for o in outs {
			append(&dev_sub.opts, DevEnt{
				name = strings.clone(tprintf("output: %s", o)),
				dev = strings.clone(o),
				picked = share_window == 0 && share_output == o,
			})
			if dev_sub.opts[len(dev_sub.opts) - 1].picked {
				dev_sub.cur = len(dev_sub.opts) - 1
			}
		}
		delete(outs)
		dev_win_refresh()
		for w in win_entries {
			label := w.title
			if label == "" {
				label = w.app
			}
			append(&dev_sub.opts, DevEnt{
				name = strings.clone(tprintf("window: %s", label)),
				win = w.id,
				picked = share_window != 0 && share_window == w.id,
			})
			if dev_sub.opts[len(dev_sub.opts) - 1].picked {
				dev_sub.cur = len(dev_sub.opts) - 1
			}
		}
	}
}

// dev_set_pick stores one picked device and its display name.
dev_set_pick :: proc(idx: int, e: ^DevEnt) {
	if len(dev_pick[idx].use) > 0 {
		delete(dev_pick[idx].use)
	}
	if len(dev_pick[idx].name) > 0 {
		delete(dev_pick[idx].name)
	}
	dev_pick[idx].use = ""
	dev_pick[idx].name = strings.clone(e.name)
	dev_pick[idx].id = e.id
	if !e.is_default {
		dev_pick[idx].use = strings.clone(id_str(&e.id))
	}
}

// dev_set_name replaces one owned name with a fresh clone.
dev_set_name :: proc(dst: ^string, s: string) {
	if len(dst^) > 0 {
		delete(dst^)
	}
	dst^ = strings.clone(s)
}

// dev_sub_apply installs the picked option and closes the picker.
dev_sub_apply :: proc() {
	if dev_sub.cur < 0 || dev_sub.cur >= len(dev_sub.opts) {
		return
	}
	e := &dev_sub.opts[dev_sub.cur]
	sharing := sync.atomic_load(&screen_send) != 0
	#partial switch dev_sub.kind {
	case .AudioIn:
		dev_set_pick(0, e)
	case .AudioOut:
		dev_set_pick(1, e)
	case .CamDev:
		cam_set(e.dev)
		dev_set_name(&dev_cam_name, e.name)
	case .Colors:
		color_idx = dev_sub.cur
		colors_apply()
		toast_show(tprintf("colors %d", colors_now()), 0)
	case .Target:
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
		if sharing {
			share_apply()
		} else {
			toast_show(tprintf("share target %s", e.name), 0)
		}
	}
	dev_sub.open = false
}

// dev_edit_open shows the number editor for one value row.
dev_edit_open :: proc(kind: DevKind) {
	dev_edit.kind = kind
	dev_edit.open = true
	dev_edit.cur = 0
	clear(&dev_edit.text)
	#partial switch kind {
	case .Volume:
		dev_edit.title = "volume"
		for r in tprintf("%d", vol_pct()) {
			append(&dev_edit.text, r)
		}
		dev_edit.cur = len(dev_edit.text)
	}
}

// dev_edit_apply parses the typed number and installs the value.
dev_edit_apply :: proc() {
	buf: [32]u8
	s := from_runes(dev_edit.text[:], buf[:])
	v := 0
	ok := len(s) > 0
	for r in s {
		if r < '0' || r > '9' {
			ok = false
			break
		}
		v = v * 10 + int(r - '0')
	}
	if ok {
		#partial switch dev_edit.kind {
		case .Volume:
			v = clamp(v, 0, 200)
			audio_vol_set(f32(v) / 100)
			toast_show(tprintf("volume %d%%", vol_pct()), 0)
		}
	}
	dev_edit.open = false
}

// dev_toggle applies one in place switch or cycle on a settings row.
dev_toggle :: proc(kind: DevKind) {
	#partial switch kind {
	case .Mic:
		conf_key(Key{kind = .Char, ch = 'n'})
	case .Spk:
		conf_key(Key{kind = .Char, ch = 'm'})
	case .DeskShare:
		conf_key(Key{kind = .Char, ch = 'a'})
	case .Cam:
		conf_key(Key{kind = .Char, ch = 'c'})
	case .Mirror:
		conf_key(Key{kind = .Char, ch = 'h'})
	case .Layout:
		conf_key(Key{kind = .Char, ch = 'f'})
	case .Cursor:
		sync.atomic_store(&share_cursor, 1 - sync.atomic_load(&share_cursor))
		if sync.atomic_load(&screen_send) != 0 {
			share_apply()
		} else {
			v := "off"
			if sync.atomic_load(&share_cursor) != 0 {
				v = "on"
			}
			toast_show(tprintf("share cursor %s", v), 0)
		}
	}
}

// dev_row_label returns the label text of one settings row.
dev_row_label :: proc(kind: DevKind) -> string {
	switch kind {
	case .Mic:
		return "microphone"
	case .Spk:
		return "speaker"
	case .DeskShare:
		return "system audio"
	case .Cam:
		return "camera"
	case .Mirror:
		return "mirror"
	case .Cursor:
		return "cursor"
	case .Volume:
		return "volume"
	case .Colors:
		return "colors"
	case .Layout:
		return "layout"
	case .AudioIn:
		return "input device"
	case .AudioOut:
		return "output device"
	case .CamDev:
		return "camera device"
	case .Target:
		return "share target"
	}
	return ""
}

// dev_row_value returns the value text of one settings row and the
// color to paint it with.
dev_row_value :: proc(kind: DevKind) -> (string, int) {
	switch kind {
	case .Mic:
		return state_word(mic_enabled, sync.atomic_load(&mic_mute) == 0)
	case .Spk:
		return state_word(audio_ok, sync.atomic_load(&spk_mute) == 0)
	case .DeskShare:
		return state_word(true, sync.atomic_load(&desk_send) != 0)
	case .Cam:
		return state_word(true, sync.atomic_load(&send_video) != 0)
	case .Mirror:
		return state_word(true, sync.atomic_load(&self_mirror) != 0)
	case .Cursor:
		return state_word(true, sync.atomic_load(&share_cursor) != 0)
	case .Volume:
		return tprintf("%d%%", vol_pct()), C_TEXT
	case .Colors:
		return tprintf("%d", colors_now()), C_TEXT
	case .Layout:
		if screen_owner != 0 || screen_local_on() {
			return "share", C_MAUVE
		}
		if conf_mode == .Focus {
			return "focus", C_MAUVE
		}
		return "grid", C_MAUVE
	case .AudioIn:
		if dev_pick[0].name == "" {
			return "System default", C_GREEN
		}
		return dev_pick[0].name, C_GREEN
	case .AudioOut:
		if dev_pick[1].name == "" {
			return "System default", C_GREEN
		}
		return dev_pick[1].name, C_GREEN
	case .CamDev:
		if dev_cam_name == "" {
			return "default", C_GREEN
		}
		return dev_cam_name, C_GREEN
	case .Target:
		if dev_target_name == "" {
			return "none", C_DIM
		}
		return dev_target_name, C_GREEN
	}
	return "", C_TEXT
}

// dev_group_marked reports whether one group holds a concrete picked
// choice instead of a system default.
dev_group_marked :: proc(folder: int) -> bool {
	for kind in dev_row_kinds[folder] {
		#partial switch kind {
		case .AudioIn:
			if dev_pick[0].use != "" {
				return true
			}
		case .AudioOut:
			if dev_pick[1].use != "" {
				return true
			}
		case .CamDev:
			if dev_cam_name != "" {
				return true
			}
		case .Target:
			if share_window != 0 || share_output != "" {
				return true
			}
		}
	}
	return false
}

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

// dev_run opens the settings page: a group column on the left and the
// settings rows of the focused group on the right. Switch rows toggle
// in place, value rows open a number editor and picker rows open a
// modal single choice list.
dev_run :: proc() {
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
			dev_draw(&b, dev_dir, inside, cols, rows)
			if dev_sub.open {
				dev_sub_draw(&b, cols, rows)
			}
			if dev_edit.open {
				dev_edit_draw(&b, cols, rows)
			}
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
		if dev_edit.open {
			dev_edit_key(k)
			continue
		}
		if dev_sub.open {
			#partial switch k.kind {
			case .Quit:
				dev_sub.open = false
			case .Up:
				if dev_sub.cur > 0 {
					dev_sub.cur -= 1
				}
			case .Down:
				if dev_sub.cur + 1 < len(dev_sub.opts) {
					dev_sub.cur += 1
				}
			case .Enter:
				dev_sub_apply()
			case .Char:
				if k.ch == 'q' || k.ch == 'Q' {
					dev_sub.open = false
				} else if k.ch == 'k' || k.ch == 'K' {
					if dev_sub.cur > 0 {
						dev_sub.cur -= 1
					}
				} else if k.ch == 'j' || k.ch == 'J' {
					if dev_sub.cur + 1 < len(dev_sub.opts) {
						dev_sub.cur += 1
					}
				}
			}
			continue
		}
		#partial switch k.kind {
		case .Quit:
			return
		case .Tab:
			inside = !inside
		case .Left:
			inside = false
		case .Right:
			inside = true
		case .Up:
			dev_move(dev_dir, inside, -1)
		case .Down:
			dev_move(dev_dir, inside, 1)
		case .Enter:
			if !inside {
				inside = true
			} else {
				dev_row_enter(dev_dir)
			}
		case .Char:
			switch k.ch {
			case 'q', 'Q':
				return
			case 'h', 'H':
				inside = false
			case 'l', 'L':
				inside = true
			case 'j', 'J':
				dev_move(dev_dir, inside, 1)
			case 'k', 'K':
				dev_move(dev_dir, inside, -1)
			case ' ':
				if !inside {
					inside = true
				} else {
					dev_row_enter(dev_dir)
				}
			}
		}
	}
}

// dev_move shifts the cursor of the group column or the row list.
dev_move :: proc(folder: int, inside: bool, delta: int) {
	if !inside {
		dev_dir = (folder + delta + len(device_folders)) % len(device_folders)
		return
	}
	n := len(dev_row_kinds[folder])
	if n > 0 {
		dev_row[folder] = (dev_row[folder] + delta + n) % n
	}
}

// dev_row_enter applies one Enter or Space on the focused row.
dev_row_enter :: proc(folder: int) {
	idx := dev_row[folder]
	if idx < 0 || idx >= len(dev_row_kinds[folder]) {
		return
	}
	kind := dev_row_kinds[folder][idx]
	switch kind {
	case .Mic, .Spk, .DeskShare, .Cam, .Mirror, .Cursor, .Layout:
		dev_toggle(kind)
	case .Volume:
		dev_edit_open(kind)
	case .Colors, .AudioIn, .AudioOut, .CamDev, .Target:
		dev_sub_open(kind)
	}
}

// dev_edit_key applies one key inside the number editor.
dev_edit_key :: proc(k: Key) {
	#partial switch k.kind {
	case .Quit:
		dev_edit.open = false
	case .Enter:
		dev_edit_apply()
	case .Backspace:
		if dev_edit.cur > 0 {
			delete_rune(&dev_edit.text, dev_edit.cur - 1)
			dev_edit.cur -= 1
		}
	case .Left:
		if dev_edit.cur > 0 {
			dev_edit.cur -= 1
		}
	case .Right:
		if dev_edit.cur < len(dev_edit.text) {
			dev_edit.cur += 1
		}
	case .Char:
		if k.ch >= '0' && k.ch <= '9' {
			insert_rune(&dev_edit.text, dev_edit.cur, k.ch)
			dev_edit.cur += 1
		}
	}
}

// dev_draw paints the group column and the settings rows of one
// group.
dev_draw :: proc(b: ^FB, folder: int, inside: bool, cols, rows: int) {
	fb_at(b, 1, max((cols - 7) / 2, 1))
	fb_str(b, "\x1b[1m")
	fb_fg(b, C_BLUE)
	fb_str(b, "Settings")
	fb_reset(b)

	folder_w := 0
	for name, i in device_folders {
		w := disp_width("▸ ") + disp_width(name) + 1
		if dev_group_marked(i) {
			w += 1
		}
		folder_w = max(folder_w, w)
	}
	folder_w = min(folder_w + 1, cols / 2)
	folder_x := 2
	list_x := folder_x + folder_w + 1
	list_w := max(cols - list_x - 1, 10)

	nbuf: [512]u8
	for idx in 0..<len(device_folders) {
		y := idx + 3
		name := device_folders[idx]
		mark := "▸ "
		if dev_group_marked(idx) {
			mark = "✓ "
		}
		line := tprintf("%s%s", mark, cut_dot(tprintf("%s/", name), folder_w - disp_width(mark), nbuf[:]))
		cursor := idx == folder && !inside
		dev_cell(b, folder_x, y, folder_w, line, cursor, false, inside)
	}

	kinds := dev_row_kinds[folder]
	for kind, i in kinds {
		y := i + 3
		label := dev_row_label(kind)
		value, vcol := dev_row_value(kind)
		cursor := i == dev_row[folder] && inside
		dev_row_draw(b, list_x, y, list_w, label, value, vcol, cursor, !inside)
	}
}

// dev_row_draw paints one settings row: label on the left, value on
// the right and the cursor bar when focused.
dev_row_draw :: proc(b: ^FB, x, y, width: int, label, value: string, vcol: int, cursor, dim: bool) {
	nbuf: [512]u8
	vbuf: [512]u8
	label_cut := cut_dot(label, max(width / 2, 6), nbuf[:])
	value_cut := cut_dot(value, max(width - disp_width(label_cut) - 3, 6), vbuf[:])
	fb_at(b, y, x)
	if cursor {
		fb_str(b, "\x1b[7m")
	}
	if dim {
		fb_str(b, "\x1b[2m")
	}
	fb_str(b, " ")
	fb_str(b, label_cut)
	used := 1 + disp_width(label_cut)
	gap := max(width - used - disp_width(value_cut) - 1, 1)
	for _ in 0..<gap {
		fb_str(b, " ")
	}
	if cursor {
		fb_str(b, "\x1b[27m")
	}
	fb_fg(b, vcol)
	fb_str(b, value_cut)
	fb_reset(b)
	for _ in 0..<max(width - used - gap - disp_width(value_cut), 0) {
		fb_str(b, " ")
	}
}

// dev_sub_draw paints the modal picker panel over the page.
dev_sub_draw :: proc(b: ^FB, cols, rows: int) {
	opts := dev_sub.opts
	width := min(cols - 8, 60)
	height := min(len(opts) + 4, rows - 4)
	left := (cols - width) / 2 + 1
	top := max((rows - height) / 2, 1)
	ui_panel(b, top, left, width, height, dev_sub.title)
	list_h := height - 3
	dev_sub.off = scroll_offset(dev_sub.off, dev_sub.cur, list_h)
	nbuf: [512]u8
	for row in 0..<list_h {
		idx := dev_sub.off + row
		if idx >= len(opts) {
			break
		}
		e := opts[idx]
		mark := "  "
		if e.picked {
			mark = "✓ "
		}
		line := tprintf("%s%s", mark, cut_dot(e.name, width - 6 - disp_width(mark), nbuf[:]))
		fb_at(b, top + 2 + row, left + 2)
		if idx == dev_sub.cur {
			fb_str(b, "\x1b[7m")
		}
		if e.picked {
			fb_fg(b, C_GREEN)
		}
		fb_str(b, line)
		for _ in disp_width(line)..<width - 4 {
			fb_str(b, " ")
		}
		fb_reset(b)
	}
	thumb_size := 0
	thumb_start := 0
	if len(opts) > list_h {
		thumb_size = max(list_h * list_h / len(opts), 1)
		scroll_range := len(opts) - list_h
		thumb_range := list_h - thumb_size
		if scroll_range > 0 {
			thumb_start = dev_sub.off * thumb_range / scroll_range
		}
	}
	for i in 0..<list_h {
		cell := "│"
		if len(opts) <= list_h {
			cell = " "
		} else if i >= thumb_start && i < thumb_start + thumb_size {
			cell = "┃"
		}
		fb_at(b, top + 2 + i, left + width - 1)
		fb_fg(b, C_BORDER)
		fb_str(b, cell)
		fb_reset(b)
	}
}

// dev_edit_draw paints the modal number editor panel over the page.
dev_edit_draw :: proc(b: ^FB, cols, rows: int) {
	width := min(cols - 8, 46)
	height := 7
	left := (cols - width) / 2 + 1
	top := max((rows - height) / 2, 1)
	ui_panel(b, top, left, width, height, dev_edit.title)
	fb_at(b, top + 2, left + 3)
	fb_fg(b, C_DIM)
	fb_str(b, "value")
	fb_reset(b)
	ui_edit(b, top + 2, left + 10, width - 14, dev_edit.text[:], dev_edit.cur, true, "")
	fb_at(b, top + 4, left + 3)
	fb_fg(b, C_DIM)
	#partial switch dev_edit.kind {
	case .Volume:
		fb_str(b, "range 0 to 200")
	}
	fb_reset(b)
}

// dev_hint draws the operation hints on the bottom line.
dev_hint :: proc(b: ^FB, cols, rows: int) {
	fb_at(b, rows, 1)
	fb_str(b, "\x1b[K")
	items: [4][2]string
	if dev_edit.open {
		items = [4][2]string{
			{"0-9", "type value"},
			{"Enter", "confirm"},
			{"Esc", "cancel"},
			{"", ""},
		}
	} else if dev_sub.open {
		items = [4][2]string{
			{"j/k, arrows", "move"},
			{"Enter", "select"},
			{"q", "back"},
			{"", ""},
		}
	} else {
		items = [4][2]string{
			{"h/j/k/l, arrows", "move"},
			{"Enter", "open or toggle"},
			{"Space", "toggle"},
			{"q", "back"},
		}
	}
	total := 0
	for it in items {
		if it[0] == "" {
			continue
		}
		total += disp_width(it[0]) + 1 + disp_width(it[1]) + 4
	}
	x := max((cols - total) / 2, 1)
	for it in items {
		if it[0] == "" {
			continue
		}
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
