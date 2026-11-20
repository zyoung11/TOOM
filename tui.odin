package toom

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

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

C_MAUVE  :: 0xc6a0f6
C_BLUE   :: 0x8aadf4
C_GREEN  :: 0xa6da95
C_YELLOW :: 0xeed49f
C_RED    :: 0xed8796
C_TEXT   :: 0xcbcfd6
C_DIM    :: 0x6e7381
C_BG     :: 0x24273a
C_FIELD  :: 0x1e2030

FormMode :: enum {
	Join,
	Create,
}

FieldKind :: enum {
	Text,
	Toggle,
	Action,
}

Field :: struct {
	label: string,
	kind:  FieldKind,
	text:  [dynamic]rune,
	tog:   bool,
	value: string,
}

FormResult :: struct {
	ok:      bool,
	create:  bool,
	name:    string,
	code:    string,
	server:  string,
	room:    string,
	cam:     bool,
	mic:     bool,
	err:     string,
}

MeetingCode :: struct {
	V: int    `json:"v"`,
	H: string `json:"h"`,
	R: string `json:"r"`,
	K: string `json:"k"`,
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

form_center :: proc(fields: []Field, sel: int, msg: string) {
	cols, rows := term_size()
	width := 46
	top := max((rows - len(fields) - 6) / 2, 2)
	left := max((cols - width) / 2, 2)

	put_fill(top, left, width, C_BG)
	put_text(top, left + 2, "toom — 终端视频会议", C_BLUE, C_BG, true)
	put_fill(top + 1, left, width, C_BG)

	for f, i in fields {
		row := top + 2 + i
		put_fill(row, left, width, C_BG)
		label := f.label
		label_w := 0
		for r in label {
			label_w += char_width(r)
		}
		label_w = 12 - label_w
		if label_w < 1 {
			label_w = 1
		}
		sel_mark := "  "
		label_col := C_DIM
		if i == sel {
			sel_mark = "> "
			label_col = C_YELLOW
		}
		put_text(row, left + 2, sel_mark, label_col, C_BG, i == sel)
		put_text(row, left + 4, label, label_col, C_BG, i == sel)
		val_buf: [512]u8
		val := ""
		vcol := C_TEXT
		#partial switch f.kind {
		case .Text:
			val = from_runes(f.text[:], val_buf[:])
			if i == sel {
				n := len(val)
				if n + 3 < len(val_buf) {
					copy(val_buf[n:], "▏")
					val = string(val_buf[:n + 3])
				}
			}
		case .Toggle:
			if f.tog {
				val = "开"
				vcol = C_GREEN
			} else {
				val = "关"
				vcol = C_DIM
			}
		case .Action:
			val = f.value
			vcol = C_GREEN
		}
		put_text(row, left + 18, val, vcol, C_FIELD, i == sel)
	}
	msg_row := top + 2 + len(fields) + 1
	put_fill(msg_row, left, width, C_BG)
	if msg != "" {
		put_text(msg_row, left + 2, msg, C_RED, C_BG, false)
	}
	put_fill(msg_row + 1, left, width, C_BG)
	put_text(msg_row + 1, left + 2, "Tab 切换  Enter 确认  q 退出", C_DIM, C_BG, false)
}

form_loop :: proc(fields: []Field, sel: ^int, msg: string) -> (Key, string) {
	for {
		form_center(fields, sel^, msg)
		k := key_next()
		if k.kind == .None {
			continue
		}
		return k, msg
	}
}

// form_join runs the join screen and returns the chosen parameters.
form_join :: proc() -> FormResult {
	host, _ := term_size()
	_ = host
	fields := [?]Field{
		{label = "名称", kind = .Text, text = to_runes("user")},
		{label = "会议码", kind = .Text, text = to_runes("")},
		{label = "摄像头", kind = .Toggle, tog = true},
		{label = "麦克风", kind = .Toggle, tog = true},
		{label = "加入会议", kind = .Action, value = "Enter"},
		{label = "创建房间", kind = .Action, value = "Enter"},
	}
	sel := 0
	msg := ""
	name_buf: [512]u8
	code_buf: [512]u8
	for {
		k, _ := form_loop(fields[:], &sel, msg)
		msg = ""
		#partial switch k.kind {
		case .Quit:
			return {}
		case .Tab:
			sel = (sel + 1) % len(fields)
		case .Up:
			sel = (sel + len(fields) - 1) % len(fields)
		case .Down:
			sel = (sel + 1) % len(fields)
		case .Backspace:
			if fields[sel].kind == .Text && len(fields[sel].text) > 0 {
				pop(&fields[sel].text)
			}
		case .Char:
			f := &fields[sel]
			#partial switch f.kind {
			case .Text:
				append(&f.text, k.ch)
			case .Toggle:
				if k.ch == ' ' {
					f.tog = !f.tog
				}
			case .Action:
				{}
			}
		case .Enter:
			switch sel {
			case 2, 3:
				fields[sel].tog = !fields[sel].tog
			case 4:
				if len(fields[0].text) == 0 {
					msg = "名称不能为空"
					continue
				}
				if len(fields[1].text) == 0 {
					msg = "会议码不能为空"
					continue
				}
				code_chk := from_runes(fields[1].text[:], code_buf[:])
				if _, ok := meeting_decode(code_chk); !ok {
					msg = "会议码无效"
					continue
				}
				return FormResult{
					ok = true,
					name = strings.clone(from_runes(fields[0].text[:], name_buf[:])),
					code = strings.clone(code_chk),
					cam = fields[2].tog,
					mic = fields[3].tog,
				}
			case 5:
				return FormResult{
					ok = true,
					create = true,
					name = strings.clone(from_runes(fields[0].text[:], name_buf[:])),
					cam = fields[2].tog,
					mic = fields[3].tog,
				}
			}
		}
	}
}

// form_create runs the room creation screen and shows the meeting code.
form_create :: proc(name: string, cam, mic: bool) -> FormResult {
	fields := [?]Field{
		{label = "服务器地址", kind = .Text, text = to_runes("127.0.0.1:4399")},
		{label = "房间名称", kind = .Text, text = to_runes("room")},
		{label = "创建并入会", kind = .Action, value = "Enter"},
	}
	sel := 0
	msg := ""
	name_buf: [512]u8
	code_buf: [512]u8
	for {
		k, _ := form_loop(fields[:], &sel, msg)
		msg = ""
		#partial switch k.kind {
		case .Quit:
			return {}
		case .Tab:
			sel = (sel + 1) % len(fields)
		case .Up:
			sel = (sel + len(fields) - 1) % len(fields)
		case .Down:
			sel = (sel + 1) % len(fields)
		case .Backspace:
			if fields[sel].kind == .Text && len(fields[sel].text) > 0 {
				pop(&fields[sel].text)
			}
		case .Char:
			if fields[sel].kind == .Text {
				append(&fields[sel].text, k.ch)
			}
		case .Enter:
			if sel == 2 {
				server := strings.clone(from_runes(fields[0].text[:], name_buf[:]))
				room := strings.clone(from_runes(fields[1].text[:], code_buf[:]))
				if server == "" || room == "" {
					msg = "地址与房间名不能为空"
					continue
				}
				return FormResult{
					ok = true,
					create = true,
					name = name,
					server = server,
					room = room,
					cam = cam,
					mic = mic,
				}
			}
		}
	}
}

// code_show displays a generated meeting code until the user confirms.
code_show :: proc(code: string) -> bool {
	for {
		cols, rows := term_size()
		width := 62
		top := max((rows - 8) / 2, 2)
		left := max((cols - width) / 2, 2)
		put_fill(top, left, width, C_BG)
		put_text(top, left + 2, "房间已创建", C_GREEN, C_BG, true)
		put_fill(top + 1, left, width, C_BG)
		put_text(top + 1, left + 2, "把下面的会议码发给对方", C_DIM, C_BG, false)
		put_fill(top + 2, left, width, C_BG)
		for i in 0..=(len(code) + 53) / 54 {
			chunk := ""
			start := i * 54
			if start >= len(code) {
				break
			}
			end := min(start + 54, len(code))
			chunk = code[start:end]
			put_fill(top + 3 + i, left, width, C_FIELD)
			put_text(top + 3 + i, left + 2, chunk, C_YELLOW, C_FIELD, false)
		}
		put_fill(top + 7, left, width, C_BG)
		put_text(top + 7, left + 2, "Enter 入会  q 返回", C_DIM, C_BG, false)
		k := key_next()
		if k.kind == .Enter {
			return true
		}
		if k.kind == .Quit {
			return false
		}
	}
}

form_error :: proc(msg: string) {
	cols, rows := term_size()
	w := 40
	top := max((rows - 4) / 2, 2)
	left := max((cols - w) / 2, 2)
	put_fill(top, left, w, C_BG)
	put_text(top, left + 2, tprintf("[-] %s", msg), C_RED, C_BG, false)
	put_fill(top + 1, left, w, C_BG)
	put_text(top + 1, left + 2, "按任意键返回", C_DIM, C_BG, false)
	_ = key_next()
}

tprintf :: proc(fmtstr: string, args: ..any) -> string {
	return fmt.tprintf(fmtstr, ..args)
}
