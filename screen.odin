package toom

import "core:c"
import "core:strings"

// ScreenCap wraps one wlr-screencopy capture session.
ScreenCap :: struct {
	handle: rawptr,
}

// screen_open starts capturing the picked output.
screen_open :: proc(s: ^ScreenCap, output_index: int) -> bool {
	s.handle = toom_screen_open(c.int(output_index))
	return s.handle != nil
}

// screen_poll pumps the capture until a frame is ready. It returns 1
// for a frame, 0 on timeout and -1 on failure.
screen_poll :: proc(s: ^ScreenCap, timeout_ms: int) -> int {
	return int(toom_screen_poll(s.handle, c.int(timeout_ms)))
}

// screen_frame returns the newest frame and its geometry.
screen_frame :: proc(s: ^ScreenCap, w, h, stride, y_invert: ^int) -> []u8 {
	fw: c.int
	fh: c.int
	fs: c.int
	fy: c.int
	p := toom_screen_frame(s.handle, &fw, &fh, &fs, &fy)
	if p == nil {
		return nil
	}
	w^ = int(fw)
	h^ = int(fh)
	stride^ = int(fs)
	y_invert^ = int(fy)
	return p[:int(fs) * int(fh)]
}

// screen_close stops the capture and releases every resource.
screen_close :: proc(s: ^ScreenCap) {
	if s.handle != nil {
		toom_screen_close(s.handle)
		s.handle = nil
	}
}

// screen_open_ex starts capturing one output with an optional slurp
// style region.
screen_open_ex :: proc(s: ^ScreenCap, name, region: string, cursor: bool) -> bool {
	nbuf: [80]u8
	rbuf: [128]u8
	ncstr: cstring = nil
	rcstr: cstring = nil
	if name != "" {
		ncstr = to_cstr(name, nbuf[:])
	}
	if region != "" {
		rcstr = to_cstr(region, rbuf[:])
	}
	ci := 0
	if cursor {
		ci = 1
	}
	s.handle = toom_screen_open_ex(ncstr, rcstr, c.int(ci))
	return s.handle != nil
}

// screen_outputs lists the available output names.
screen_outputs :: proc() -> [dynamic]string {
	buf := make([]u8, 8192)
	defer delete(buf)
	n := int(toom_screen_list(raw_data(buf), 8192))
	out: [dynamic]string
	start := 0
	found := 0
	for i in 0..<len(buf) {
		if buf[i] == 0 {
			if i > start && found < n {
				append(&out, strings.clone(string(buf[start:i])))
				found += 1
			}
			start = i + 1
		}
	}
	return out
}
