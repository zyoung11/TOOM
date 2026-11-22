package toom

import "core:c"
import "core:os"
import posix "core:sys/posix"
import "core:sync"
import "core:time"
import aideo "../Aideo"

Termios :: struct {
	iflag:  u32,
	oflag:  u32,
	cflag:  u32,
	lflag:  u32,
	line:   u8,
	cc:     [32]u8,
	ispeed: u32,
	ospeed: u32,
}

WinSize :: struct {
	row:    u16,
	col:    u16,
	xpixel: u16,
	ypixel: u16,
}

Sigset :: struct {
	bits: [16]u64,
}

TCSANOW     :: 0
TCGETS      :: 0x5401
TCSETS      :: 0x5402
TIOCGWINSZ  :: 0x5413
SIGWINCH    :: 28
SIG_BLOCK   :: 0
SIG_UNBLOCK :: 1
POLLIN      :: 0x1

foreign import syslib {
	"system:libc.so.6",
}

foreign syslib {
	tcgetattr :: proc(fd: c.int, t: ^Termios) -> c.int ---
	tcsetattr :: proc(fd: c.int, act: c.int, t: ^Termios) -> c.int ---
	ioctl :: proc(fd: c.int, req: u64, arg: rawptr) -> c.int ---
	signal :: proc(sig: c.int, handler: rawptr) -> rawptr ---
	sigprocmask :: proc(how: c.int, set, old: ^Sigset) -> c.int ---
}

// term_write writes raw bytes to the terminal under the aideo write
// lock so the sixel streams and the text layer never interleave.
term_write :: proc(data: []u8) {
	sync.mutex_lock(&aideo.stdout_mu)
	os.write(os.stdout, data)
	sync.mutex_unlock(&aideo.stdout_mu)
}

term_orig:    Termios
term_raw:     bool
winch_flag:   i32
in_head:      i64
in_tail:      i64
in_buf:       [512]u8
in_mu:        sync.Mutex

winch_handler :: proc "c" (_: c.int) {
	sync.atomic_store(&winch_flag, 1)
}

// term_sig_setup installs the winch handler with SIGWINCH blocked, so
// threads created afterwards never see the signal. Call
// term_sig_unblock after the render threads exist.
term_sig_setup :: proc() {
	set: Sigset
	set.bits[SIGWINCH / 64] = 1 << u64(SIGWINCH % 64)
	sigprocmask(SIG_BLOCK, &set, nil)
	signal(SIGWINCH, cast(rawptr)winch_handler)
}

term_sig_unblock :: proc() {
	set: Sigset
	set.bits[SIGWINCH / 64] = 1 << u64(SIGWINCH % 64)
	sigprocmask(SIG_UNBLOCK, &set, nil)
}

term_take_winch :: proc() -> bool {
	if sync.atomic_load(&winch_flag) != 0 {
		sync.atomic_store(&winch_flag, 0)
		return true
	}
	return false
}

term_enter_raw :: proc() {
	if tcgetattr(0, &term_orig) != 0 {
		return
	}
	raw := term_orig
	raw.lflag &= ~u32(0x8 | 0x2 | 0x1 | 0x40000)
	raw.iflag &= ~u32(0x100 | 0x400 | 0x2 | 0x10 | 0x1 | 0x200 | 0x20 | 0x8)
	raw.oflag &= ~u32(0x1 | 0x4)
	raw.cc[6] = 1
	raw.cc[5] = 0
	tcsetattr(0, TCSANOW, &raw)
	term_raw = true
}

term_full: bool

// term_enter_full enters raw mode, switches to the alternate screen
// and hides the cursor so the program owns the whole terminal.
term_enter_full :: proc() {
	term_enter_raw()
	seq: string = "\x1b[?1049h\x1b[?25l"
	os.write(os.stdout, transmute([]u8)seq)
	term_full = true
}

// term_leave_full restores the cursor and the main screen.
term_leave_full :: proc() {
	if term_full {
		seq: string = "\x1b[?25h\x1b[?1049l"
		os.write(os.stdout, transmute([]u8)seq)
		term_full = false
	}
	term_leave_raw()
}

// screen_clear wipes the whole visible screen.
screen_clear :: proc() {
	if sync.atomic_load(&ui_modal) != 0 {
		return
	}
	seq: string = "\x1b[2J\x1b[3J\x1b[H"
	term_write(transmute([]u8)seq)
}

term_leave_raw :: proc() {
	if term_raw {
		tcsetattr(0, TCSANOW, &term_orig)
		term_raw = false
	}
}

term_size :: proc() -> (int, int) {
	ws: WinSize
	if ioctl(1, TIOCGWINSZ, &ws) != 0 || ws.col == 0 {
		return 80, 24
	}
	return int(ws.col), int(ws.row)
}

term_cell_pixels :: proc() -> (int, int) {
	ws: WinSize
	if ioctl(1, TIOCGWINSZ, &ws) != 0 || ws.xpixel == 0 || ws.col == 0 {
		return 8, 16
	}
	return int(ws.xpixel) / int(ws.col), int(ws.ypixel) / int(ws.row)
}

// input_thread reads stdin bytes into the decode queue.
input_thread :: proc() {
	buf: [256]u8
	for {
		pfd := posix.pollfd{fd = 0, events = {.IN}}
		if posix.poll(&pfd, 1, 200) <= 0 {
			continue
		}
		n, err := os.read(os.stdin, buf[:])
		if err != nil || n <= 0 {
			input_push(0)
			return
		}
		for i in 0..<n {
			input_push(buf[i])
		}
	}
}

input_push :: proc(b: u8) {
	sync.mutex_lock(&in_mu)
	if in_head - in_tail < i64(len(in_buf)) {
		in_buf[in_head % i64(len(in_buf))] = b
		in_head += 1
	}
	sync.mutex_unlock(&in_mu)
}

input_pop :: proc() -> (u8, bool) {
	sync.mutex_lock(&in_mu)
	defer sync.mutex_unlock(&in_mu)
	if in_head == in_tail {
		return 0, false
	}
	b := in_buf[in_tail % i64(len(in_buf))]
	in_tail += 1
	return b, true
}

input_wait :: proc(timeout_ms: int) -> bool {
	deadline := time.now()
	for {
		if in_head > in_tail {
			return true
		}
		if i64(time.since(deadline)) >= i64(time.Duration(timeout_ms) * time.Millisecond) {
			return false
		}
		time.sleep(2 * time.Millisecond)
	}
}

KeyKind :: enum {
	None,
	Char,
	Quit,
	Up,
	Down,
	Left,
	Right,
	Enter,
	Backspace,
	Delete,
	Home,
	End,
	Tab,
	FocusIn,
}

Key :: struct {
	kind: KeyKind,
	ch:   rune,
}

// key_next decodes one key press. A lone ESC is confirmed by waiting
// 20 ms for continuation bytes.
key_next :: proc() -> Key {
	if !input_wait(100) {
		return {}
	}
	b, ok := input_pop()
	if !ok {
		return {}
	}
	if b == 27 {
		if !input_wait(20) {
			return {kind = .Quit}
		}
		b2, ok2 := input_pop()
		if !ok2 {
			return {kind = .Quit}
		}
		if b2 == '[' || b2 == 'O' {
			if !input_wait(20) {
				return {kind = .Quit}
			}
			b3, ok3 := input_pop()
			if !ok3 {
				return {kind = .Quit}
			}
			switch b3 {
			case 'A':
				return {kind = .Up}
			case 'B':
				return {kind = .Down}
			case 'C':
				return {kind = .Right}
			case 'D':
				return {kind = .Left}
			case 'I':
				return {kind = .FocusIn}
			case '3':
				if input_wait(20) {
					_, _ = input_pop()
				}
				return {kind = .Delete}
			case 'H':
				return {kind = .Home}
			case 'F':
				return {kind = .End}
			case '1':
				if input_wait(20) {
					_, _ = input_pop()
				}
				return {kind = .Home}
			case '4':
				if input_wait(20) {
					_, _ = input_pop()
				}
				return {kind = .End}
			}
			return {kind = .None}
		}
		return {kind = .Quit}
	}
	if b == 3 || b == 4 {
		return {kind = .Quit}
	}
	if b == '\r' || b == '\n' {
		return {kind = .Enter}
	}
	if b == 0x7f || b == 0x08 {
		return {kind = .Backspace}
	}
	if b == '\t' {
		return {kind = .Tab}
	}
	if b < 0x20 {
		return {kind = .None}
	}
	return {kind = .Char, ch = utf8_take(b)}
}

// utf8_take assembles one rune from the queue continuation bytes.
utf8_take :: proc(first: u8) -> rune {
	if first < 0x80 {
		return rune(first)
	}
	need := 0
	val := rune(first)
	if first >= 0xf0 {
		need = 3
		val = rune(first & 0x07)
	} else if first >= 0xe0 {
		need = 2
		val = rune(first & 0x0f)
	} else if first >= 0xc0 {
		need = 1
		val = rune(first & 0x1f)
	} else {
		return 0xfffd
	}
	for i in 0..<need {
		if !input_wait(20) {
			return 0xfffd
		}
		b, ok := input_pop()
		if !ok || (b & 0xc0) != 0x80 {
			return 0xfffd
		}
		val = val << 6 | rune(b & 0x3f)
	}
	return val
}

// char_width reports the terminal cell width of one rune.
char_width :: proc(r: rune) -> int {
	if r == 0 {
		return 0
	}
	if r < 0x20 || (r >= 0x7f && r < 0xa0) {
		return 0
	}
	if r < 0x7f {
		return 1
	}
	if (r >= 0x1100 && r <= 0x115f) ||
		(r >= 0x2e80 && r <= 0x303e) ||
		(r >= 0x3041 && r <= 0x33ff) ||
		(r >= 0x3400 && r <= 0x4dbf) ||
		(r >= 0x4e00 && r <= 0x9fff) ||
		(r >= 0xa000 && r <= 0xa4cf) ||
		(r >= 0xac00 && r <= 0xd7a3) ||
		(r >= 0xf900 && r <= 0xfaff) ||
		(r >= 0xfe30 && r <= 0xfe4f) ||
		(r >= 0xff00 && r <= 0xff60) ||
		(r >= 0xffe0 && r <= 0xffe6) ||
		(r >= 0x1f300 && r <= 0x1f64f) ||
		(r >= 0x20000 && r <= 0x3fffd) {
		return 2
	}
	return 1
}

sgr_color :: proc(buf: []u8, base: int, rgb: int) -> int {
	if rgb < 0 {
		return 0
	}
	n := 0
	s := "\x1b[38;2;"
	if base == 48 {
		s = "\x1b[48;2;"
	}
	copy(buf[n:], transmute([]u8)s)
	n += len(s)
	v := [3]u8{u8(rgb >> 16), u8(rgb >> 8), u8(rgb)}
	for idx in 0..<3 {
		if v[idx] >= 100 {
			buf[n] = '0' + v[idx] / 100
			n += 1
		}
		if v[idx] >= 10 {
			buf[n] = '0' + (v[idx] / 10) % 10
			n += 1
		}
		buf[n] = '0' + v[idx] % 10
		n += 1
		if idx < 2 {
			buf[n] = ';'
			n += 1
		}
	}
	buf[n] = 'm'
	n += 1
	return n
}

// put_text draws one string in a single write. fg and bg are 0xRRGGBB
// or -1 for the terminal default. Returns the cells consumed.
put_text :: proc(row, col: int, s: string, fg, bg: int, bold: bool) -> int {
	buf := make([]u8, len(s) + 64)
	defer delete(buf)
	n := 0
	n += cursor_seq(buf[n:], row, col)
	copy(buf[n:], "\x1b[0m")
	n += 4
	if bold {
		copy(buf[n:], "\x1b[1m")
		n += 4
	}
	n += sgr_color(buf[n:], 38, fg)
	n += sgr_color(buf[n:], 48, bg)
	cells := 0
	for r in s {
		w := char_width(r)
		if w == 0 {
			continue
		}
		cells += w
	}
	copy(buf[n:], transmute([]u8)s)
	n += len(s)
	copy(buf[n:], "\x1b[0m")
	n += 4
	os.write(os.stdout, buf[:n])
	return cells
}

// put_fill paints cells with one background color in a single write.
put_fill :: proc(row, col, cells, bg: int) {
	buf := make([]u8, cells + 64)
	defer delete(buf)
	n := 0
	n += cursor_seq(buf[n:], row, col)
	copy(buf[n:], "\x1b[0m")
	n += 4
	n += sgr_color(buf[n:], 48, bg)
	for i in 0..<cells {
		buf[n] = ' '
		n += 1
	}
	copy(buf[n:], "\x1b[0m")
	n += 4
	os.write(os.stdout, buf[:n])
}

cursor_seq :: proc(buf: []u8, row, col: int) -> int {
	n := 0
	buf[n] = 0x1b
	n += 1
	buf[n] = '['
	n += 1
	n += num_seq(buf[n:], row)
	buf[n] = ';'
	n += 1
	n += num_seq(buf[n:], col)
	buf[n] = 'H'
	n += 1
	return n
}

num_seq :: proc(buf: []u8, v: int) -> int {
	tmp: [8]u8
	n := 0
	x := v
	if x <= 0 {
		buf[0] = '0'
		return 1
	}
	for x > 0 {
		tmp[n] = '0' + u8(x % 10)
		n += 1
		x /= 10
	}
	for i in 0..<n {
		buf[i] = tmp[n - 1 - i]
	}
	return n
}
