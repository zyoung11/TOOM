package toom

import "core:c"

CLIP_TOOLS :: [4]string{
	"wl-copy",
	"xclip -selection clipboard",
	"xsel --clipboard --input",
	"pbcopy",
}

foreign import cliplib {
	"system:libc.so.6",
}

foreign cliplib {
	@(link_name="popen")
	clip_popen :: proc(cmd: cstring, mode: cstring) -> rawptr ---
	@(link_name="fputs")
	clip_fputs :: proc(s: cstring, f: rawptr) -> c.int ---
	@(link_name="pclose")
	clip_pclose :: proc(f: rawptr) -> c.int ---
}

// to_cstr copies s into buf as a NUL terminated string.
to_cstr :: proc(s: string, buf: []u8) -> cstring {
	n := min(len(s), len(buf) - 1)
	copy(buf[:], s[:n])
	buf[n] = 0
	return cast(cstring)&buf[0]
}

// clip_copy pushes text into the system clipboard. It tries the common
// clipboard tools in order and reports whether one accepted the text.
clip_copy :: proc(text: string) -> bool {
	mode: [2]u8
	mode[0] = 'w'
	cmd_buf: [64]u8
	text_buf: [1024]u8
	if len(text) >= len(text_buf) {
		return false
	}
	for tool in CLIP_TOOLS {
		cmd := to_cstr(tool, cmd_buf[:])
		f := clip_popen(cmd, cast(cstring)&mode[0])
		if f == nil {
			continue
		}
		clip_fputs(to_cstr(text, text_buf[:]), f)
		if clip_pclose(f) == 0 {
			return true
		}
	}
	return false
}
