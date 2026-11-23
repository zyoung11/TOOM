package toom

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"
import ma "../Aideo/miniaudio"

// DEV_FOLDERS is the number of settings groups.
DEV_FOLDERS :: 5

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
	WinTargets,
	Target,
	Lang,
}

// dev_row_kinds_session lists the settings rows of every group during
// a meeting in display order.
dev_row_kinds_session := [5][]DevKind{
	{.Cam, .CamDev},
	{.Mic, .Spk, .DeskShare, .Volume, .AudioIn, .AudioOut},
	{.Mirror, .Colors, .Layout},
	{.Cursor, .WinTargets},
	{.Lang},
}

// dev_row_kinds_menu lists the settings rows before a meeting. The
// session switches show their join defaults here and system audio is
// left out because it has no useful default.
dev_row_kinds_menu := [5][]DevKind{
	{.Cam, .CamDev},
	{.Mic, .Spk, .Volume, .AudioIn, .AudioOut},
	{.Mirror, .Colors, .Layout},
	{.Cursor, .WinTargets},
	{.Lang},
}

// dev_rows returns the settings rows of one group for the current
// mode.
dev_rows :: proc(folder: int) -> []DevKind {
	if dev_session {
		return dev_row_kinds_session[folder]
	}
	return dev_row_kinds_menu[folder]
}

// dev_folder_name returns the display name of one group.
dev_folder_name :: proc(folder: int) -> string {
	switch folder {
	case 0:
		return tr("Camera", "摄像头")
	case 1:
		return tr("Sound", "声音")
	case 2:
		return tr("Display", "画面")
	case 3:
		return tr("Share", "共享")
	}
	return tr("Language", "语言")
}

// DevEnt is one entry inside an option column.
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

// DevCol is the option column drilled into from a picker row.
DevCol :: struct {
	open: bool,
	kind: DevKind,
	opts: [dynamic]DevEnt,
	cur:  int,
	off:  int,
}

// DevEdit is the modal number editor.
DevEdit :: struct {
	open: bool,
	kind: DevKind,
	text: [dynamic]rune,
	cur:  int,
}

// dev_session marks the meeting settings mode where the switches
// control live session state instead of the join defaults.
dev_session: bool

dev_dir:        int
dev_row:        [5]int
dev_pick:       [2]DevPick
dev_col:        DevCol
dev_edit:       DevEdit
dev_cam_name:   string
dev_target_name: string

// dev_prev caches the preview column of the picker row under the
// cursor so browsing rows never re-enumerates devices.
dev_prev_kind: DevKind
dev_prev_have: bool
dev_prev_opts: [dynamic]DevEnt

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
	dev_prev_have = false
}

// cam_auto_pick installs the first available camera when the current
// camera path cannot be opened and no camera was picked by hand.
cam_auto_pick :: proc() {
	if dev_cam_name != "" {
		return
	}
	buf: [256]u8
	n := min(len(cam_dev), 255)
	copy(buf[:], cam_dev[:n])
	buf[n] = 0
	fd := cam_open_dev(cast(cstring)&buf[0])
	if fd >= 0 {
		cam_close(fd)
		return
	}
	cams := cam_enum_devs()
	defer dev_list_free(&cams)
	if len(cams) > 0 {
		cam_set(cams[0].dev)
		dev_set_name(&dev_cam_name, cams[0].name)
	}
}

// id_is_zero reports whether a device id carries no name.
id_is_zero :: proc(id: ^ma.device_id) -> bool {
	return id.pulse[0] == 0
}

// dev_audio_id returns the picked audio device id of one direction.
// ok is false when the system default is picked. A pick restored from
// the config file only carries the id string, so the runtime id is
// resolved back from the device list here.
dev_audio_id :: proc(capture: bool) -> (ma.device_id, bool) {
	idx := 0
	if !capture {
		idx = 1
	}
	if dev_pick[idx].use == "" {
		return {}, false
	}
	if id_is_zero(&dev_pick[idx].id) {
		list := audio_enum_devs(capture)
		defer dev_list_free(&list)
		for &e in list {
			if !e.is_default && id_str(&e.id) == dev_pick[idx].use {
				dev_pick[idx].id = e.id
				break
			}
		}
	}
	if id_is_zero(&dev_pick[idx].id) {
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

// dev_sub_build fills one option list and returns the picked index.
dev_sub_build :: proc(kind: DevKind, opts: ^[dynamic]DevEnt) -> int {
	picked := 0
	#partial switch kind {
	case .AudioIn:
		src := audio_enum_devs(true)
		for &e in src {
			e.picked = (e.is_default && dev_pick[0].use == "") || (!e.is_default && id_str(&e.id) == dev_pick[0].use)
			if e.picked {
				picked = len(opts^)
			}
			append(opts, e)
		}
		delete(src)
	case .AudioOut:
		src := audio_enum_devs(false)
		for &e in src {
			e.picked = (e.is_default && dev_pick[1].use == "") || (!e.is_default && id_str(&e.id) == dev_pick[1].use)
			if e.picked {
				picked = len(opts^)
			}
			append(opts, e)
		}
		delete(src)
	case .CamDev:
		src := cam_enum_devs()
		for &e in src {
			e.picked = e.dev == cam_dev
			if e.picked {
				picked = len(opts^)
			}
			append(opts, e)
		}
		delete(src)
	case .Colors:
		for lv, i in CONF_COLORS {
			append(opts, DevEnt{name = strings.clone(tprintf("%d colors", lv)), picked = i == color_idx})
			if i == color_idx {
				picked = len(opts^) - 1
			}
		}
	case .Target:
		active := sync.atomic_load(&screen_send) != 0
		outs := screen_outputs()
		for o in outs {
			append(opts, DevEnt{
				name = strings.clone(tprintf("output: %s", o)),
				dev = strings.clone(o),
				picked = active && share_window == 0 && share_output == o,
			})
			if opts[len(opts^) - 1].picked {
				picked = len(opts^) - 1
			}
		}
		delete(outs)
		if sync.atomic_load(&share_win_menu) != 0 {
			dev_win_refresh()
			for w in win_entries {
				label := w.title
				if label == "" {
					label = w.app
				}
				append(opts, DevEnt{
					name = strings.clone(tprintf("window: %s", label)),
					win = w.id,
					picked = active && share_window != 0 && share_window == w.id,
				})
				if opts[len(opts^) - 1].picked {
					picked = len(opts^) - 1
				}
			}
		}
	}
	return picked
}

// dev_col_open builds the option column of one picker row and moves
// the column focus into it.
dev_col_open :: proc(kind: DevKind) {
	dev_col.kind = kind
	dev_col.open = true
	dev_col.off = 0
	dev_list_free(&dev_col.opts)
	dev_col.cur = dev_sub_build(kind, &dev_col.opts)
	dev_dir = 2
}

// dev_col_close leaves the option column and releases its entries.
dev_col_close :: proc() {
	dev_col.open = false
	dev_list_free(&dev_col.opts)
	if dev_dir > 1 {
		dev_dir = 1
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

// dev_col_apply installs the picked option. The cursor stays on the
// entry so single choices never move the browsing position.
dev_col_apply :: proc() {
	if dev_col.cur < 0 || dev_col.cur >= len(dev_col.opts) {
		return
	}
	e := &dev_col.opts[dev_col.cur]
	#partial switch dev_col.kind {
	case .AudioIn:
		dev_set_pick(0, e)
	case .AudioOut:
		dev_set_pick(1, e)
	case .CamDev:
		cam_set(e.dev)
		dev_set_name(&dev_cam_name, e.name)
	case .Colors:
		color_idx = dev_col.cur
		colors_apply()
		toast_show(tprintf("colors %d", colors_now()), 0)
	}
	for i in 0..<len(dev_col.opts) {
		dev_col.opts[i].picked = i == dev_col.cur
	}
	dev_prev_have = false
}

// dev_edit_open shows the number editor for one value row.
dev_edit_open :: proc(kind: DevKind) {
	dev_edit.kind = kind
	dev_edit.open = true
	dev_edit.cur = 0
	clear(&dev_edit.text)
	#partial switch kind {
	case .Volume:
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
		if !dev_session {
			mic_default = !mic_default
			v := "off"
			if mic_default {
				v = "on"
			}
			toast_show(tprintf("microphone default %s", v), 0)
			return
		}
		conf_key(Key{kind = .Char, ch = 'n'})
	case .Spk:
		if !dev_session {
			spk_default = !spk_default
			v := "off"
			if spk_default {
				v = "on"
			}
			toast_show(tprintf("speaker default %s", v), 0)
			return
		}
		conf_key(Key{kind = .Char, ch = 'm'})
	case .DeskShare:
		conf_key(Key{kind = .Char, ch = 'a'})
	case .Cam:
		if !dev_session {
			cam_default = !cam_default
			v := "off"
			if cam_default {
				v = "on"
			}
			toast_show(tprintf("camera default %s", v), 0)
			return
		}
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
	case .WinTargets:
		sync.atomic_store(&share_win_menu, 1 - sync.atomic_load(&share_win_menu))
		v := tr("off", "关")
		if sync.atomic_load(&share_win_menu) != 0 {
			v = tr("on", "开")
		}
		toast_show(tprintf("%s %s", tr("windows listed", "窗口列出"), v), 0)
	case .Lang:
		lang_zh = !lang_zh
	}
}

// dev_row_label returns the label text of one settings row.
dev_row_label :: proc(kind: DevKind) -> string {
	switch kind {
	case .Mic:
		return tr("microphone", "麦克风")
	case .Spk:
		return tr("speaker", "扬声器")
	case .DeskShare:
		return tr("system audio", "系统音频")
	case .Cam:
		return tr("camera", "摄像头")
	case .Mirror:
		return tr("mirror", "镜像")
	case .Cursor:
		return tr("cursor", "光标")
	case .Volume:
		return tr("volume", "音量")
	case .Colors:
		return tr("colors", "色数")
	case .Layout:
		return tr("layout", "布局")
	case .AudioIn:
		return tr("input device", "输入设备")
	case .AudioOut:
		return tr("output device", "输出设备")
	case .CamDev:
		return tr("camera device", "摄像头设备")
	case .WinTargets:
		return tr("windows", "窗口")
	case .Lang:
		return tr("language", "语言")
	case .Target:
		return tr("share target", "共享目标")
	}
	return ""
}

// dev_row_value returns the value text of one settings row and the
// color to paint it with.
dev_row_value :: proc(kind: DevKind) -> (string, int) {
	switch kind {
	case .Mic:
		if !dev_session {
			v := tr("off", "关")
			c := C_RED
			if mic_default {
				v = tr("on", "开")
				c = C_GREEN
			}
			return tprintf("%s: %s", tr("default", "默认"), v), c
		}
		return state_word(mic_enabled, sync.atomic_load(&mic_mute) == 0)
	case .Spk:
		if !dev_session {
			v := tr("off", "关")
			c := C_RED
			if spk_default {
				v = tr("on", "开")
				c = C_GREEN
			}
			return tprintf("%s: %s", tr("default", "默认"), v), c
		}
		return state_word(audio_ok, sync.atomic_load(&spk_mute) == 0)
	case .DeskShare:
		return state_word(true, sync.atomic_load(&desk_send) != 0)
	case .Cam:
		if !dev_session {
			v := tr("off", "关")
			c := C_RED
			if cam_default {
				v = tr("on", "开")
				c = C_GREEN
			}
			return tprintf("%s: %s", tr("default", "默认"), v), c
		}
		return state_word(true, sync.atomic_load(&send_video) != 0)
	case .Mirror:
		return state_word(true, sync.atomic_load(&self_mirror) != 0)
	case .Cursor:
		return state_word(true, sync.atomic_load(&share_cursor) != 0)
	case .Volume:
		return tprintf("%d%%", vol_pct()), C_YELLOW
	case .Colors:
		return tprintf("%d", colors_now()), C_YELLOW
	case .Layout:
		if screen_owner != 0 || screen_local_on() {
			return tr("share", "共享"), C_MAUVE
		}
		if conf_mode == .Focus {
			return tr("focus", "聚焦"), C_MAUVE
		}
		return tr("grid", "网格"), C_MAUVE
	case .Lang:
		if lang_zh {
			return "中文", C_GREEN
		}
		return "english", C_GREEN
	case .AudioIn:
		if dev_pick[0].name == "" {
			return tr("System default", "系统默认"), C_GREEN
		}
		return dev_pick[0].name, C_GREEN
	case .AudioOut:
		if dev_pick[1].name == "" {
			return tr("System default", "系统默认"), C_GREEN
		}
		return dev_pick[1].name, C_GREEN
	case .CamDev:
		if dev_cam_name == "" {
			return "default", C_GREEN
		}
		return dev_cam_name, C_GREEN
	case .WinTargets:
		return state_word(true, sync.atomic_load(&share_win_menu) != 0)
	case .Target:
		if dev_target_name == "" {
			return "none", C_DIM
		}
		return dev_target_name, C_GREEN
	}
	return "", C_TEXT
}

// dev_row_folder reports whether one settings row drills into an
// option column like a folder.
dev_row_folder :: proc(kind: DevKind) -> bool {
	#partial switch kind {
	case .Colors, .AudioIn, .AudioOut, .CamDev:
		return true
	}
	return false
}

// dev_group_marked reports whether one group holds a concrete picked
// choice instead of a system default.
dev_group_marked :: proc(folder: int) -> bool {
	for kind in dev_rows(folder) {
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

// dev_run opens the settings page as a Miller column browser like the
// BM library: the group column, the settings rows of the group and an
// option column drilled into from a picker row. A picker row also
// previews its options in a dimmed column on the right.
dev_run :: proc() {
	dev_dir = 0
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
			dev_draw(&b, cols, rows)
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
		#partial switch k.kind {
		case .Quit:
			if !dev_back() {
				return
			}
		case .Left:
			_ = dev_back()
		case .Right:
			dev_fwd()
		case .Up:
			dev_move(-1)
		case .Down:
			dev_move(1)
		case .Enter:
			dev_enter()
		case .Char:
			switch k.ch {
			case 'q', 'Q':
				if !dev_back() {
					return
				}
			case 'h', 'H', 'a', 'A':
				_ = dev_back()
			case 'l', 'L', 'd', 'D':
				dev_fwd()
			case 'j', 'J', 's', 'S':
				dev_move(1)
			case 'k', 'K', 'w', 'W':
				dev_move(-1)
			case ' ':
				dev_enter()
			}
		}
	}
}

// dev_back steps one column out and reports whether the page stays
// open.
dev_back :: proc() -> bool {
	if dev_dir == 2 {
		dev_col_close()
		return true
	}
	if dev_dir == 1 {
		dev_dir = 0
		return true
	}
	return false
}

// dev_fwd steps one column deeper where the focused entry allows it.
dev_fwd :: proc() {
	if dev_dir == 0 {
		dev_dir = 1
		return
	}
	if dev_dir == 1 {
		kind := dev_rows(dev_focus_folder)[dev_row[dev_focus_folder]]
		if dev_row_folder(kind) {
			dev_col_open(kind)
		}
	}
}

dev_focus_folder: int

// dev_move shifts the cursor of the focused column.
dev_move :: proc(delta: int) {
	if dev_dir == 0 {
		dev_focus_folder = (dev_focus_folder + delta + DEV_FOLDERS) % DEV_FOLDERS
		if dev_col.open {
			dev_col_close()
		}
		return
	}
	if dev_dir == 1 {
		n := len(dev_rows(dev_focus_folder))
		if n > 0 {
			dev_row[dev_focus_folder] = (dev_row[dev_focus_folder] + delta + n) % n
		}
		return
	}
	n := len(dev_col.opts)
	if n > 0 {
		dev_col.cur = (dev_col.cur + delta + n) % n
	}
}

// dev_enter applies one Enter or Space on the focused entry.
dev_enter :: proc() {
	if dev_dir == 0 {
		dev_dir = 1
		return
	}
	if dev_dir == 2 {
		dev_col_apply()
		return
	}
	kind := dev_rows(dev_focus_folder)[dev_row[dev_focus_folder]]
	if dev_row_folder(kind) {
		dev_col_open(kind)
		return
	}
	#partial switch kind {
	case .Mic, .Spk, .DeskShare, .Cam, .Mirror, .Cursor, .Layout, .WinTargets, .Lang:
		dev_toggle(kind)
	case .Volume:
		dev_edit_open(kind)
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

// dev_draw paints the Miller columns: groups, settings rows and the
// option column or its preview.
dev_draw :: proc(b: ^FB, cols, rows: int) {
	fb_at(b, 1, max((cols - 7) / 2, 1))
	fb_str(b, "\x1b[1m")
	fb_fg(b, C_BLUE)
	fb_str(b, "Settings")
	fb_reset(b)

	nbuf: [512]u8
	folder := dev_focus_folder
	kinds := dev_rows(folder)

	need0 := 0
	for i in 0..<DEV_FOLDERS {
		name := dev_folder_name(i)
		need0 = max(need0, disp_width("▸ ") + disp_width(name) + 1)
	}
	label_w := 0
	for kind in kinds {
		label_w = max(label_w, disp_width(dev_row_label(kind)))
	}
	need1 := 0
	for kind in kinds {
		w := disp_width("▸ ") + label_w + 2
		if !dev_row_folder(kind) {
			v, _ := dev_row_value(kind)
			w += disp_width(v) + 2
		}
		need1 = max(need1, w)
	}
	w0 := min(need0, max(cols / 4, 8))
	w1 := min(need1, max(cols / 3, 12))
	x0 := 2
	x1 := x0 + w0 + 1
	x2 := x1 + w1 + 1
	avail2 := max(cols - x2, 8)

	for idx in 0..<DEV_FOLDERS {
		y := idx + 3
		line := cut_dot(tprintf("▸ %s", dev_folder_name(idx)), w0 - 1, nbuf[:])
		dev_cell(b, x0, y, w0, line, idx == folder && dev_dir == 0, false, dev_dir > 0, 0)
	}

	for kind, i in kinds {
		y := i + 3
		label := dev_row_label(kind)
		value, vcol := dev_row_value(kind)
		cursor := i == dev_row[folder] && dev_dir == 1
		dev_row_draw(b, x1, y, w1, label_w, label, value, vcol, cursor, dev_dir != 1, dev_row_folder(kind))
	}

	if dev_col.open {
		dev_col_draw(b, x2, 3, avail2, rows - 4, dev_col.opts[:], dev_col.cur, dev_col.off, dev_dir == 2, false)
		return
	}

	kind := kinds[dev_row[folder]]
	if !dev_row_folder(kind) {
		return
	}
	if !dev_prev_have || dev_prev_kind != kind {
		dev_list_free(&dev_prev_opts)
		_ = dev_sub_build(kind, &dev_prev_opts)
		dev_prev_kind = kind
		dev_prev_have = true
	}
	dev_col_draw(b, x2, 3, avail2, rows - 4, dev_prev_opts[:], -1, 0, false, true)
}

// dev_col_draw paints one option column. A negative cursor draws the
// dimmed preview variant without a focus bar.
dev_col_draw :: proc(b: ^FB, x, y, width, list_h: int, opts: []DevEnt, cursor, offset: int, focused, dim: bool) {
	nbuf: [512]u8
	off := offset
	if cursor >= 0 {
		off = scroll_offset(offset, cursor, list_h)
	}
	for row in 0..<list_h {
		idx := off + row
		if idx >= len(opts) {
			break
		}
		e := opts[idx]
		mark := "  "
		if e.picked {
			mark = "✓ "
		}
		line := tprintf("%s%s", mark, cut_dot(e.name, width - disp_width(mark), nbuf[:]))
		is_cur := idx == cursor
		bg := 0
		if e.picked {
			bg = C_GREEN
		}
		dev_cell(b, x, y + row, width, line, is_cur && focused, e.picked, dim && !is_cur, bg)
	}
}

// dev_row_draw paints one settings row. Folder rows carry a drill
// marker and hide the value. Labels right align into one column and
// the values start at one shared tab stop like the form pages. The
// cursor paints one bar that ends two columns past the content like
// the BM cursor padding.
dev_row_draw :: proc(b: ^FB, x, y, width, label_w: int, label, value: string, vcol: int, cursor, dim, folder_row: bool) {
	nbuf: [512]u8
	vbuf: [512]u8
	mark := "  "
	if folder_row {
		mark = "▸ "
	}
	value_x := disp_width(mark) + label_w + 2
	value_cut := ""
	if !folder_row {
		value_cut = cut_dot(value, max(width - value_x - 2, 3), vbuf[:])
	}
	content := disp_width(mark) + disp_width(label)
	if value_cut != "" {
		content = value_x + disp_width(value_cut)
	}
	bar := min(content + 2, width)
	fb_at(b, y, x)
	ink := false
	if cursor {
		if folder_row {
			fb_str(b, "\x1b[7m")
		} else {
			fb_bg(b, vcol)
			fb_fg(b, C_INK)
			ink = true
		}
	}
	if dim && !cursor {
		fb_str(b, "\x1b[2m")
	}
	fb_str(b, mark)
	fb_str(b, label)
	if value_cut != "" {
		for _ in 0..<(value_x - disp_width(mark) - disp_width(label)) {
			fb_str(b, " ")
		}
		if !cursor {
			fb_fg(b, vcol)
		}
		fb_str(b, value_cut)
	}
	if ink {
		fb_bg(b, vcol)
	}
	for _ in 0..<max(bar - content, 0) {
		fb_str(b, " ")
	}
	fb_reset(b)
	for _ in 0..<max(width - bar, 0) {
		fb_str(b, " ")
	}
}

// dev_edit_draw paints the modal number editor panel over the page.
dev_edit_draw :: proc(b: ^FB, cols, rows: int) {
	width := min(cols - 8, 46)
	height := 7
	left := (cols - width) / 2 + 1
	top := max((rows - height) / 2, 1)
	ui_panel(b, top, left, width, height, dev_row_label(dev_edit.kind))
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

// dev_cell draws one padded cell. The cursor paints one bar that ends
// two columns past the content like the BM cursor padding.
dev_cell :: proc(b: ^FB, x, y, width: int, line: string, cursor, chosen, dim: bool, bg: int) {
	nbuf: [512]u8
	shown := cut_dot(line, width, nbuf[:])
	bar := min(disp_width(shown) + 2, width)
	fb_at(b, y, x)
	if cursor {
		if bg != 0 {
			fb_bg(b, bg)
			fb_fg(b, C_INK)
		} else {
			fb_str(b, "\x1b[7m")
		}
	} else if chosen {
		fb_fg(b, C_GREEN)
	}
	if dim {
		fb_str(b, "\x1b[2m")
	}
	fb_str(b, shown)
	for i in disp_width(shown)..<bar {
		fb_str(b, " ")
	}
	fb_reset(b)
	for _ in bar..<width {
		fb_str(b, " ")
	}
}

// hint_draw paints one centered hint line on the bottom row.
hint_draw :: proc(b: ^FB, cols, rows: int, items: [4][2]string) {
	fb_at(b, rows, 1)
	fb_str(b, "\x1b[K")
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

// dev_hint draws the operation hints on the bottom line. A live
// toast replaces the hints so failures stay visible inside the
// settings page too.
dev_hint :: proc(b: ^FB, cols, rows: int) {
	if toast_active() {
		col := C_TEXT
		if toast_kind == 1 {
			col = C_GREEN
		} else if toast_kind == 2 {
			col = C_RED
		}
		fb_at(b, rows, 1)
		fb_str(b, "\x1b[K")
		msg := string(toast_buf[:toast_len])
		x := max((cols - disp_width(msg)) / 2, 1)
		fb_at(b, rows, x)
		fb_fg(b, col)
		fb_str(b, msg)
		fb_reset(b)
		return
	}
	items: [4][2]string
	if dev_edit.open {
		items = [4][2]string{
			{"0-9", tr("type value", "输入数值")},
			{"Enter", tr("confirm", "确认")},
			{"Esc", tr("cancel", "取消")},
			{"", ""},
		}
	} else if dev_dir == 2 {
		items = [4][2]string{
			{"wasd, jk, arrows", tr("move", "移动")},
			{"Enter/Space", tr("select", "选择")},
			{"h/q", tr("back", "返回")},
			{"", ""},
		}
	} else {
		items = [4][2]string{
			{"wasd, hjkl, arrows", tr("move", "移动")},
			{"Enter/Space", tr("open or toggle", "打开或切换")},
			{"q", tr("back", "返回")},
			{"", ""},
		}
	}
	hint_draw(b, cols, rows, items)
}
