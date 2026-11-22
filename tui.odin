package toom

import "base:runtime"
import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

C_MAUVE  :: 0xc6a0f6
C_BLUE   :: 0x8aadf4
C_GREEN  :: 0xa6da95
C_YELLOW :: 0xeed49f
C_RED    :: 0xed8796
C_TEXT   :: 0xcbcfd6
C_DIM    :: 0x6e7381
C_BORDER :: 0x555a6b
C_INK    :: 0x1e2030
C_BG     :: 0x24273a
C_FIELD  :: 0x1e2030

FieldKind :: enum {
	Text,
	Toggle,
	Action,
}

Field :: struct {
	label: string,
	kind:  FieldKind,
	text:  [dynamic]rune,
	cur:   int,
	tog:   bool,
	value: string,
	hint:  string,
	def:   string,
}

FormResult :: struct {
	ok:     bool,
	create: bool,
	back:   bool,
	name:   string,
	code:   string,
	server: string,
	room:   string,
	cam:    bool,
	mic:    bool,
}

MeetingCode :: struct {
	V: int    `json:"v"`,
	H: string `json:"h"`,
	R: string `json:"r"`,
	K: string `json:"k"`,
}

// FB accumulates one frame and flushes it with a single write.
FB :: strings.Builder

fb_str :: proc(b: ^FB, s: string) {
	strings.write_bytes(b, transmute([]u8)s)
}

fb_at :: proc(b: ^FB, row, col: int) {
	fb_str(b, fmt.tprintf("\x1b[%d;%dH", row, col))
}

fb_fg :: proc(b: ^FB, rgb: int) {
	fb_str(b, fmt.tprintf("\x1b[38;2;%d;%d;%dm", (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff))
}

fb_bg :: proc(b: ^FB, rgb: int) {
	fb_str(b, fmt.tprintf("\x1b[48;2;%d;%d;%dm", (rgb >> 16) & 0xff, (rgb >> 8) & 0xff, rgb & 0xff))
}

fb_reset :: proc(b: ^FB) {
	fb_str(b, "\x1b[0m")
}

fb_flush :: proc(b: ^FB) {
	s := strings.to_string(b^)
	term_write(transmute([]u8)s)
	strings.builder_reset(b)
}

// fb_begin opens one atomic frame and clears the whole screen.
fb_begin :: proc(b: ^FB) {
	fb_str(b, "\x1b[?2026h\x1b[2J\x1b[H")
}

// fb_keep opens one atomic frame without clearing the screen.
fb_keep :: proc(b: ^FB) {
	fb_str(b, "\x1b[?2026h")
}

// fb_end closes the atomic frame and flushes it.
fb_end :: proc(b: ^FB) {
	fb_str(b, "\x1b[?2026l")
	fb_flush(b)
}

fb_fill_row :: proc(b: ^FB, row, col, width: int, bg: int) {
	fb_at(b, row, col)
	fb_bg(b, bg)
	for i in 0..<width {
		fb_str(b, " ")
	}
	fb_reset(b)
}

// to_runes converts a string into an editable rune buffer.
to_runes :: proc(s: string) -> [dynamic]rune {
	out := make([dynamic]rune, 0, len(s))
	for r in s {
		append(&out, r)
	}
	return out
}

// from_runes encodes runes into buf and returns the string view.
from_runes :: proc(rs: []rune, buf: []u8) -> string {
	n := 0
	for r in rs {
		b, k := utf8.encode_rune(r)
		for i in 0..<k {
			if n < len(buf) {
				buf[n] = b[i]
				n += 1
			}
		}
	}
	return string(buf[:n])
}

disp_width :: proc(s: string) -> int {
	w := 0
	for r in s {
		w += char_width(r)
	}
	return w
}

// cut_text shortens text to width cells and marks the cut with an
// ellipsis. It writes into buf and returns the view, so the caller
// keeps the storage alive while the string is used.
cut_text :: proc(s: string, width: int, buf: []u8) -> string {
	if disp_width(s) <= width {
		return s
	}
	n := 0
	used := 0
	for r in s {
		w := char_width(r)
		if used + w > width - 1 {
			break
		}
		b, k := utf8.encode_rune(r)
		for i in 0..<k {
			buf[n] = b[i]
			n += 1
		}
		used += w
	}
	copy(buf[n:], "…")
	n += 3
	return string(buf[:n])
}

tprintf :: proc(fmtstr: string, args: ..any) -> string {
	return fmt.tprintf(fmtstr, ..args)
}

// ui_panel draws a bordered card with the title in the top border and
// fills the interior with the panel background.
ui_panel :: proc(b: ^FB, row, col, width, height: int, title: string) {
	inner := width - 2
	fb_at(b, row, col)
	fb_fg(b, C_BORDER)
	tbuf: [256]u8
	tcut := cut_text(title, max(width - 8, 4), tbuf[:])
	fb_str(b, "┌─ ")
	fb_fg(b, C_BLUE)
	fb_str(b, tcut)
	fb_fg(b, C_BORDER)
	fb_str(b, " ")
	pad := width - 5 - disp_width(tcut)
	for i in 0..<max(pad, 0) {
		fb_str(b, "─")
	}
	fb_str(b, "┐")
	for r in 1..<height - 1 {
		fb_at(b, row + r, col)
		fb_fg(b, C_BORDER)
		fb_str(b, "│")
		fb_at(b, row + r, col + width - 1)
		fb_str(b, "│")
	}
	fb_at(b, row + height - 1, col)
	fb_fg(b, C_BORDER)
	fb_str(b, "└")
	for i in 0..<inner {
		fb_str(b, "─")
	}
	fb_str(b, "┘")
	fb_reset(b)
}

// ui_hint draws the centered footer hint line on the last row.
ui_hint :: proc(b: ^FB, hint: string) {
	cols, rows := term_size()
	x := max((cols - disp_width(hint)) / 2, 1)
	fb_at(b, rows, 1)
	fb_str(b, "\x1b[K")
	fb_at(b, rows, x)
	fb_fg(b, C_DIM)
	fb_str(b, hint)
	fb_reset(b)
}

ui_small :: proc(b: ^FB, msg: string) {
	cols, rows := term_size()
	fb_at(b, max(rows / 2, 1), max((cols - disp_width(msg)) / 2, 1))
	fb_fg(b, C_DIM)
	fb_str(b, msg)
	fb_reset(b)
}

// ui_field draws one form row inside a panel. Text fields render
// through the scrolling editor view.
ui_field :: proc(b: ^FB, row, col: int, f: ^Field, sel: bool, val: string, val_col: int) {
	label_col := C_DIM
	mark := "  "
	if sel {
		label_col = C_YELLOW
		mark = "▸ "
	}
	fb_at(b, row, col)
	fb_fg(b, label_col)
	fb_str(b, mark)
	fb_str(b, f.label)
	fb_at(b, row, col + 18)
	if f.kind == .Text {
		if sel {
			fb_fg(b, C_TEXT)
		} else {
			fb_fg(b, C_DIM)
		}
		ui_edit(b, row, col + 18, 26, f.text[:], f.cur, sel, f.hint)
		fb_reset(b)
		return
	}
	if sel {
		fb_fg(b, val_col)
		fb_str(b, val)
	} else {
		fb_fg(b, C_DIM)
		fb_str(b, val)
	}
	fb_reset(b)
}

// ui_action draws one action button inside a panel.
ui_action :: proc(b: ^FB, row, col: int, label: string, sel: bool) {
	fb_at(b, row, col)
	if sel {
		fb_fg(b, C_GREEN)
		fb_str(b, tprintf("[ %s ]", label))
	} else {
		fb_fg(b, C_DIM)
		fb_str(b, tprintf("  %s  ", label))
	}
	fb_reset(b)
}

// fb_rune writes one rune as UTF-8 bytes.
fb_rune :: proc(b: ^FB, r: rune) {
	buf, n := utf8.encode_rune(r)
	fb_str(b, string(buf[:n]))
}

// insert_rune inserts one rune at the cursor position.
insert_rune :: proc(t: ^[dynamic]rune, cur: int, r: rune) {
	append(t, r)
	for i := len(t^) - 1; i > cur; i -= 1 {
		t[i] = t[i - 1]
	}
	t[cur] = r
}

// delete_rune removes one rune at the index.
delete_rune :: proc(t: ^[dynamic]rune, idx: int) {
	for i := idx; i < len(t^) - 1; i += 1 {
		t[i] = t[i + 1]
	}
	pop(t)
}

// field_value returns the edited text, or the default value while the
// buffer is empty.
field_value :: proc(f: ^Field, buf: []u8) -> string {
	if len(f.text) == 0 {
		return f.def
	}
	return from_runes(f.text[:], buf)
}

// ui_edit draws an editable text value with a block cursor and a
// scrolling window that follows the cursor.
ui_edit :: proc(b: ^FB, row, col, avail: int, text: []rune, cur: int, sel: bool, hint: string) {
	if len(text) == 0 && hint != "" {
		hbuf: [256]u8
		hshown := cut_text(hint, avail, hbuf[:])
		fb_at(b, row, col)
		if sel {
			first := true
			for r in hshown {
				if first {
					fb_str(b, "\x1b[7m")
					fb_rune(b, r)
					fb_str(b, "\x1b[27m")
					fb_fg(b, C_BORDER)
					first = false
				} else {
					fb_rune(b, r)
				}
			}
			if first {
				fb_str(b, "\x1b[7m \x1b[27m")
			}
		} else {
			fb_fg(b, C_BORDER)
			fb_str(b, hshown)
		}
		fb_reset(b)
		return
	}
	total := 0
	for r in text {
		total += char_width(r)
	}
	start := 0
	if total > avail {
		used := 0
		i := cur
		for i > 0 {
			w := char_width(text[i - 1])
			if used + w > avail - 2 {
				break
			}
			used += w
			i -= 1
		}
		start = i
	}
	fb_at(b, row, col)
	used := 0
	idx := start
	for idx < len(text) {
		w := char_width(text[idx])
		if used + w > avail {
			break
		}
		cursor_here := sel && idx == cur
		if cursor_here {
			fb_str(b, "\x1b[7m")
		}
		fb_rune(b, text[idx])
		if cursor_here {
			fb_str(b, "\x1b[27m")
		}
		used += w
		idx += 1
	}
	if sel && cur >= len(text) {
		fb_str(b, "\x1b[7m \x1b[27m")
		used += 1
	}
	if idx < len(text) && used + 1 <= avail {
		fb_str(b, "…")
		used += 1
	}
	if start > 0 {
		fb_at(b, row, col)
		if !(sel && cur == start) {
			fb_str(b, "…")
		}
	}
	fb_reset(b)
}

// meeting_encode packs server, room and secret into a shareable code.
meeting_encode :: proc(server, room, secret: string) -> string {
	code := MeetingCode{V = 1, H = server, R = room, K = secret}
	data, _ := json.marshal(code)
	defer delete(data)
	return base64.encode(data)
}

// meeting_decode unpacks a shareable code.
meeting_decode :: proc(code: string) -> (MeetingCode, bool) {
	raw, err := base64.decode(code)
	if err != nil {
		return {}, false
	}
	defer delete(raw)
	out: MeetingCode
	if !json_unmarshal(raw, &out) {
		return {}, false
	}
	if out.V != 1 || out.H == "" || out.R == "" || out.K == "" {
		return {}, false
	}
	return out, true
}

form_width :: 48

// MenuChoice is the mode picked on the start screen.
MenuChoice :: enum {
	Join,
	Create,
	Settings,
	Quit,
}

// menu_select asks whether to join or create a meeting.
menu_select :: proc() -> MenuChoice {
	sel := menu_sel_state
	need_draw := true
	for {
		tmp := runtime.default_temp_allocator_temp_begin()
		defer runtime.default_temp_allocator_temp_end(tmp)
		if need_draw {
			b: FB
			fb_begin(&b)
			cols, rows := term_size()
			if cols < 56 || rows < 12 {
				ui_small(&b, "Terminal too small, need at least 56x12")
				fb_end(&b)
				need_draw = false
				continue
			}
			width := 48
			height := 10
			left := (cols - width) / 2
			top := (rows - height) / 2
			ui_panel(&b, top, left, width, height, "toom — terminal video call")
			opts := [3]struct {
				title: string,
				hint:  string,
			}{
				{"Join meeting", "enter a meeting code"},
				{"Create room", "host a new room"},
				{"Settings", "configure devices and defaults"},
			}
			for opt, i in opts {
				mark := "  "
				col := C_DIM
				if i == sel {
					mark = "▸ "
					col = C_GREEN
				}
				fb_at(&b, top + 2 + i * 2, left + 4)
				fb_fg(&b, col)
				fb_str(&b, mark)
				fb_str(&b, opt.title)
				fb_fg(&b, C_DIM)
				hbuf: [256]u8
				fb_at(&b, top + 2 + i * 2, left + 24)
				fb_str(&b, cut_text(opt.hint, width - 27, hbuf[:]))
				fb_reset(&b)
			}
			ui_hint(&b, "wasd, jk, arrows select  Enter confirm  q quit")
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
		menu_sel_state = sel
		#partial switch k.kind {
		case .Quit:
			return .Quit
		case .Up:
			sel = (sel + 2) % 3
		case .Down, .Tab:
			sel = (sel + 1) % 3
		case .Enter:
			if sel == 0 {
				return .Join
			}
			if sel == 1 {
				return .Create
			}
			return .Settings
		case .Char:
			if k.ch == 'q' || k.ch == 'Q' {
				return .Quit
			}
			if k.ch == 'j' || k.ch == 's' {
				sel = (sel + 1) % 3
			} else if k.ch == 'k' || k.ch == 'w' {
				sel = (sel + 2) % 3
			}
		}
		need_draw = true
	}
}

// form_key applies one key to the shared form state. Text fields edit
// at the cursor, other fields move the selection with the same keys.
// It returns 1 for back and 2 for pressing an action button.
form_key :: proc(fields: []Field, sel: ^int, k: Key) -> int {
	idx := sel^
	f := &fields[idx]
	editable := f.kind == .Text
	#partial switch k.kind {
	case .Tab, .Down:
		sel^ = (idx + 1) % len(fields)
	case .Up:
		sel^ = (idx + len(fields) - 1) % len(fields)
	case .Left:
		if editable && f.cur > 0 {
			f.cur -= 1
		} else if !editable {
			sel^ = (idx + len(fields) - 1) % len(fields)
		}
	case .Right:
		if editable && f.cur < len(f.text) {
			f.cur += 1
		} else if !editable {
			sel^ = (idx + 1) % len(fields)
		}
	case .Home:
		if editable {
			f.cur = 0
		}
	case .End:
		if editable {
			f.cur = len(f.text)
		}
	case .Backspace:
		if editable && f.cur > 0 {
			delete_rune(&f.text, f.cur - 1)
			f.cur -= 1
		}
	case .Delete:
		if editable && f.cur < len(f.text) {
			delete_rune(&f.text, f.cur)
		}
	case .Char:
		if editable {
			insert_rune(&f.text, f.cur, k.ch)
			f.cur += 1
		} else if k.ch == 'q' || k.ch == 'Q' {
			return 1
		} else if k.ch == 'j' || k.ch == 's' {
			sel^ = (idx + 1) % len(fields)
		} else if k.ch == 'k' || k.ch == 'w' {
			sel^ = (idx + len(fields) - 1) % len(fields)
		} else if k.ch == 'a' {
			sel^ = (idx + len(fields) - 1) % len(fields)
		} else if k.ch == 'd' {
			sel^ = (idx + 1) % len(fields)
		} else if f.kind == .Toggle && k.ch == ' ' {
			f.tog = !f.tog
		}
	case .Enter:
		#partial switch f.kind {
		case .Action:
			return 2
		case .Toggle:
			f.tog = !f.tog
		case .Text:
			sel^ = (idx + 1) % len(fields)
		}
	}
	return 0
}

menu_sel_state: int
join_sel_state: int = 1
create_sel_state: int = 5

join_fields: [5]Field
join_inited: bool

// join_fields_init fills the join form defaults once so user edits
// survive a trip back to the menu within one program run.
join_fields_init :: proc() {
	if join_inited {
		return
	}
	join_fields[0] = Field{label = "Name", kind = .Text, hint = "user", def = app_cfg.name}
	join_fields[0].text = to_runes(app_cfg.name)
	join_fields[0].cur = len(join_fields[0].text)
	join_fields[1] = Field{label = "Meeting code", kind = .Text, hint = "paste meeting code", def = ""}
	join_fields[2] = Field{label = "Camera", kind = .Toggle, tog = cam_default}
	join_fields[3] = Field{label = "Microphone", kind = .Toggle, tog = mic_default}
	join_fields[4] = Field{label = "Join meeting", kind = .Action, value = "Enter"}
	join_inited = true
}

// form_join collects the parameters for joining a meeting. A q goes
// back to the mode menu.
form_join :: proc() -> FormResult {
	join_fields_init()
	fields := &join_fields
	sel := min(join_sel_state, len(join_fields) - 1)
	msg := ""
	need_draw := true
	name_buf: [512]u8
	code_buf: [512]u8
	for {
		tmp := runtime.default_temp_allocator_temp_begin()
		defer runtime.default_temp_allocator_temp_end(tmp)
		if need_draw {
			b: FB
			fb_begin(&b)
			cols, rows := term_size()
			if cols < 56 || rows < 16 {
				ui_small(&b, "Terminal too small, need at least 56x16")
				fb_end(&b)
				need_draw = false
				continue
			}
			width := 48
			height := 11
			left := (cols - width) / 2
			top := (rows - height) / 2
			ui_panel(&b, top, left, width, height, "toom — join meeting")
			for f, i in fields {
				val := ""
				#partial switch f.kind {
				case .Text:
					{}
				case .Toggle:
					if f.tog {
						val = "on"
					} else {
						val = "off"
					}
				case .Action:
					continue
				}
				vcol := C_TEXT
				if f.kind == .Toggle {
					vcol = C_DIM
					if f.tog {
						vcol = C_GREEN
					}
				}
				ui_field(&b, top + 2 + i, left + 2, &fields[i], i == sel, val, vcol)
			}
			ui_action(&b, top + 7, left + 6, "Join meeting", sel == 4)
			if msg != "" {
				fb_at(&b, top + 9, left + 3)
				fb_fg(&b, C_RED)
				fb_str(&b, msg)
				fb_reset(&b)
			}
			ui_hint(&b, "wasd, jk, arrows move  Enter confirm  Esc back")
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
		if k.kind == .Quit {
			return {back = true}
		}
		act := form_key(fields[:], &sel, k)
		join_sel_state = sel
		if act == 1 {
			return {back = true}
		}
		need_draw = true
		msg = ""
		if act == 2 && sel == 4 {
			name_val := field_value(&fields[0], name_buf[:])
			code_chk := field_value(&fields[1], code_buf[:])
			if name_val == "" {
				msg = "Name is required"
			} else if code_chk == "" {
				msg = "Meeting code is required"
			} else if _, ok := meeting_decode(code_chk); !ok {
				msg = "Invalid meeting code"
			} else {
				return FormResult{
					ok = true,
					name = strings.clone(name_val),
					code = strings.clone(code_chk),
					cam = fields[2].tog,
					mic = fields[3].tog,
				}
			}
		}
	}
}
create_fields: [6]Field
create_inited: bool

// create_fields_init fills the create form defaults once so user edits
// survive a trip back to the menu within one program run.
create_fields_init :: proc() {
	if create_inited {
		return
	}
	create_fields[0] = Field{label = "Server address", kind = .Text, hint = "127.0.0.1:4400", def = app_cfg.server}
	create_fields[0].text = to_runes(app_cfg.server)
	create_fields[0].cur = len(create_fields[0].text)
	create_fields[1] = Field{label = "Room name", kind = .Text, hint = "room", def = app_cfg.room}
	create_fields[1].text = to_runes(app_cfg.room)
	create_fields[1].cur = len(create_fields[1].text)
	create_fields[2] = Field{label = "Name", kind = .Text, hint = "user", def = app_cfg.name}
	create_fields[2].text = to_runes(app_cfg.name)
	create_fields[2].cur = len(create_fields[2].text)
	create_fields[3] = Field{label = "Camera", kind = .Toggle, tog = cam_default}
	create_fields[4] = Field{label = "Microphone", kind = .Toggle, tog = mic_default}
	create_fields[5] = Field{label = "Create and join", kind = .Action, value = "Enter"}
	create_inited = true
}

// form_create collects the parameters for creating a room. A q goes
// back to the mode menu.
form_create :: proc() -> FormResult {
	create_fields_init()
	fields := &create_fields
	sel := min(create_sel_state, len(create_fields) - 1)
	msg := ""
	need_draw := true
	bufs: [3][512]u8
	for {
		tmp := runtime.default_temp_allocator_temp_begin()
		defer runtime.default_temp_allocator_temp_end(tmp)
		if need_draw {
			b: FB
			fb_begin(&b)
			cols, rows := term_size()
			if cols < 56 || rows < 17 {
				ui_small(&b, "Terminal too small, need at least 56x17")
				fb_end(&b)
				need_draw = false
				continue
			}
			width := 48
			height := 12
			left := (cols - width) / 2
			top := (rows - height) / 2
			ui_panel(&b, top, left, width, height, "toom — create room")
			for f, i in fields {
				val := ""
				#partial switch f.kind {
				case .Text:
					{}
				case .Toggle:
					if f.tog {
						val = "on"
					} else {
						val = "off"
					}
				case .Action:
					continue
				}
				vcol := C_TEXT
				if f.kind == .Toggle {
					vcol = C_DIM
					if f.tog {
						vcol = C_GREEN
					}
				}
				ui_field(&b, top + 2 + i, left + 2, &fields[i], i == sel, val, vcol)
			}
			ui_action(&b, top + 8, left + 6, "Create and join", sel == 5)
			if msg != "" {
				fb_at(&b, top + 10, left + 3)
				fb_fg(&b, C_RED)
				fb_str(&b, msg)
				fb_reset(&b)
			}
			ui_hint(&b, "wasd, jk, arrows move  Enter confirm  Esc back")
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
		if k.kind == .Quit {
			return {back = true}
		}
		act := form_key(fields[:], &sel, k)
		create_sel_state = sel
		if act == 1 {
			return {back = true}
		}
		need_draw = true
		msg = ""
		if act == 2 && sel == 5 {
			server := strings.clone(normalize_server(field_value(&fields[0], bufs[0][:])))
			room := strings.clone(field_value(&fields[1], bufs[1][:]))
			name := strings.clone(field_value(&fields[2], bufs[2][:]))
			if server == "" || room == "" {
				msg = "Address and room name are required"
			} else if name == "" {
				msg = "Name is required"
			} else {
				return FormResult{
					ok = true,
					create = true,
					name = name,
					server = server,
					room = room,
					cam = fields[3].tog,
					mic = fields[4].tog,
				}
			}
		}
	}
}
// code_show displays a generated meeting code until the user confirms.
code_show :: proc(code: string) -> bool {
	need_draw := true
	for {
		tmp := runtime.default_temp_allocator_temp_begin()
		defer runtime.default_temp_allocator_temp_end(tmp)
		if need_draw {
			b: FB
			fb_begin(&b)
			cols, rows := term_size()
			width := min(max(disp_width(code) + 6, 44), cols - 4)
			height := 9
			left := (cols - width) / 2
			top := (rows - height) / 2
			ui_panel(&b, top, left, width, height, "Room created")
			fb_at(&b, top + 2, left + 3)
			fb_fg(&b, C_DIM)
			fb_str(&b, "Share this meeting code with the others")
			fb_reset(&b)
			chunk_w := width - 6
			row := top + 4
			i := 0
			for i < len(code) {
				end := i + chunk_w
				if end > len(code) {
					end = len(code)
				}
				fb_at(&b, row, left + 3)
				fb_fg(&b, C_YELLOW)
				fb_str(&b, code[i:end])
				fb_reset(&b)
				row += 1
				i = end
			}
			ui_hint(&b, "Enter copy the code to clipboard and join  q back")
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
		if k.kind == .Enter {
			clip_copy(code)
			return true
		}
		if k.kind == .Quit {
			return false
		}
		if k.kind == .Char && (k.ch == 'q' || k.ch == 'Q') {
			return false
		}
		need_draw = true
	}
}

// form_error shows a centered modal error box until a key is pressed.
form_error :: proc(msg: string) {
	need_draw := true
	for {
		tmp := runtime.default_temp_allocator_temp_begin()
		defer runtime.default_temp_allocator_temp_end(tmp)
		if need_draw {
			b: FB
			fb_begin(&b)
			cols, rows := term_size()
			width := min(max(disp_width(msg) + 8, 32), cols - 4)
			height := 5
			left := (cols - width) / 2
			top := (rows - height) / 2
			ui_panel(&b, top, left, width, height, "Error")
			fb_at(&b, top + 2, left + 3)
			fb_fg(&b, C_RED)
			mbuf: [512]u8
			fb_str(&b, cut_text(msg, width - 6, mbuf[:]))
			fb_reset(&b)
			ui_hint(&b, "Press any key to go back")
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
		return
	}
}

// connecting_draw shows the connection spinner frame.
connecting_draw :: proc(step: int) {
	spinner := [10]string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
	b: FB
	fb_begin(&b)
	cols, rows := term_size()
	width := 34
	height := 5
	left := (cols - width) / 2
	top := (rows - height) / 2
	ui_panel(&b, top, left, width, height, "Connecting")
	fb_at(&b, top + 2, left + 3)
	fb_fg(&b, C_BLUE)
	fb_str(&b, tprintf("%s joining the meeting...", spinner[step % 10]))
	fb_reset(&b)
	fb_end(&b)
}
