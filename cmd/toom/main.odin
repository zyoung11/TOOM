package main

import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import toom "../.."

VERSION :: "0.1.0"

C_MAUVE  :: "\x1b[38;2;198;160;246m"
C_BOLD   :: "\x1b[1m"
C_BLUE   :: "\x1b[38;2;138;173;244m"
C_GREEN  :: "\x1b[38;2;166;218;149m"
C_YELLOW :: "\x1b[38;2;238;212;159m"
C_RESET  :: "\x1b[0m"

print_help :: proc() {
	fmt.printf("\n%s%stoom%s — terminal LAN video call\n\n", C_BOLD, C_BLUE, C_RESET)
	fmt.printf("%sUSAGE:%s\n", C_BOLD + C_MAUVE, C_RESET)
	fmt.printf("  %stoom%s %s[options]%s\n", C_BLUE, C_RESET, C_YELLOW, C_RESET)
	rows := [?][2]string{
		{"-d <path>", "camera device, default /dev/video0"},
		{"-s <WxH>", "capture size, default 640x480"},
		{"-f <n>", "frames per second, 1 to 60, default 15"},
		{"-b <n>", "video bitrate in kbps, 50 to 4000, default 300"},
		{"--enc <name>", "encoder backend auto x264 vaapi nvenc"},
		{"--join <code>", "join a meeting directly, skip the forms"},
		{"--name <name>", "display name used by --join"},
		{"--no-cam", "join with the camera off"},
		{"-h, --help", "show help"},
		{"--version", "show version"},
	}
	fmt.printf("\n%sOPTIONS:%s\n", C_BOLD + C_MAUVE, C_RESET)
	width := 0
	for r in rows {
		if len(r[0]) > width {
			width = len(r[0])
		}
	}
	for r in rows {
		pad := strings.repeat(" ", width - len(r[0]))
		fmt.printf("  %s%s%s%s %s\n", C_YELLOW, r[0], pad, C_RESET, r[1])
	}
	fmt.printf("\n%sEXAMPLES:%s\n", C_BOLD + C_MAUVE, C_RESET)
	fmt.printf("  %stoom%s\n", C_BLUE, C_RESET)
	fmt.printf("  %stoom -s 320x240 -f 10 -b 150%s\n", C_BLUE, C_RESET)
	fmt.printf("  %stoom --enc vaapi%s\n", C_BLUE, C_RESET)
	fmt.println()
}

print_version :: proc() {
	fmt.printf("%stoom%s %s%s%s\n", C_BLUE, C_RESET, C_GREEN, VERSION, C_RESET)
}

parse_wh :: proc(s: string) -> (int, int, bool) {
	for i in 0..<len(s) {
		if s[i] == 'x' {
			w, ok1 := strconv.parse_int(s[:i])
			h, ok2 := strconv.parse_int(s[i + 1:])
			if ok1 && ok2 && w > 0 && h > 0 {
				return w, h, true
			}
			return 0, 0, false
		}
	}
	return 0, 0, false
}

random_secret :: proc() -> string {
	buf: [16]u8
	_ = toom.rand_bytes(buf[:])
	out, _ := hex.encode(buf[:])
	s := strings.clone(string(out))
	delete(out)
	return s
}

main :: proc() {
	toom.av_log_set_level(-8)
	if !toom.crypto_self_test() {
		fmt.eprintln("[-] crypto self test failed")
		os.exit(1)
	}

	toom.config_load()
	toom.config_apply()

	join_code := ""
	join_name := ""
	join_nocam := false
	i := 1
	for i < len(os.args) {
		a := os.args[i]
		need := a == "-d" || a == "-s" || a == "-f" || a == "-b" || a == "--enc" || a == "--join" || a == "--name"
		if need {
			i += 1
			if i >= len(os.args) {
				fmt.eprintf("[-] missing value for %s\n", a)
				os.exit(1)
			}
		}
		if a == "-h" || a == "--help" {
			print_help()
			return
		} else if a == "--version" {
			print_version()
			return
		} else if a == "-d" {
			toom.cam_dev = os.args[i]
		} else if a == "-s" {
			w, h, ok := parse_wh(os.args[i])
			if !ok {
				fmt.eprintln("[-] bad size, expected WxH")
				os.exit(1)
			}
			toom.cam_w_req, toom.cam_h_req = w, h
		} else if a == "-f" {
			v, ok := strconv.parse_int(os.args[i])
			if !ok || v < 1 || v > 60 {
				fmt.eprintln("[-] bad fps, expected 1 to 60")
				os.exit(1)
			}
			toom.app_fps = v
		} else if a == "-b" {
			v, ok := strconv.parse_int(os.args[i])
			if !ok || v < 50 || v > 4000 {
				fmt.eprintln("[-] bad bitrate, expected 50 to 4000")
				os.exit(1)
			}
			toom.enc_kbps = v
		} else if a == "--join" {
			join_code = os.args[i]
		} else if a == "--name" {
			join_name = os.args[i]
		} else if a == "--no-cam" {
			join_nocam = true
		} else if a == "--enc" {
			switch os.args[i] {
			case "auto":
				toom.enc_prefer = 0
			case "x264":
				toom.enc_prefer = 1
			case "vaapi":
				toom.enc_prefer = 2
			case "nvenc":
				toom.enc_prefer = 3
			case:
				fmt.eprintln("[-] bad encoder, expected auto x264 vaapi nvenc")
				os.exit(1)
			}
		} else {
			fmt.eprintf("[-] unknown option %s\n", a)
			print_help()
			os.exit(1)
		}
		i += 1
	}

	toom.epoch = time.now()
	toom.term_sig_setup()
	toom.term_enter_full()
	thread.create_and_start(toom.input_thread)

	if join_code != "" {
		mc, ok := toom.meeting_decode(join_code)
		if !ok {
			toom.term_leave_full()
			fmt.eprintln("[-] invalid meeting code")
			os.exit(1)
		}
		name := join_name
		if name == "" {
			name = toom.app_cfg.name
		}
		err := toom.conference_run(mc.H, mc.R, name, mc.K, false, toom.cam_default && !join_nocam, toom.mic_default)
		toom.term_leave_full()
		if err != "" {
			fmt.eprintf("[-] %s\n", err)
			os.exit(1)
		}
		return
	}

	for {
		choice := toom.menu_select()
		if choice == .Quit {
			break
		}
		if choice == .Settings {
			toom.dev_session = false
			toom.dev_run()
			toom.config_store()
			continue
		}
		server := ""
		room := ""
		secret := ""
		name := ""
		cam := false
		mic := false
		create := false
		if choice == .Create {
			cres := toom.form_create()
			if cres.back {
				continue
			}
			toom.config_form_set(cres.server, cres.room, cres.name)
			toom.config_toggle_set(cres.cam, cres.mic)
			toom.config_store()
			secret = random_secret()
			if rerr := toom.room_create_now(cres.server, cres.room, secret); rerr != "" {
				toom.form_error(rerr)
				continue
			}
			code := toom.meeting_encode(cres.server, cres.room, secret)
			if !toom.code_show(code) {
				continue
			}
			server = cres.server
			room = cres.room
			name = cres.name
			cam = cres.cam
			mic = cres.mic
			create = true
		} else {
			res := toom.form_join()
			if res.back {
				continue
			}
			toom.config_form_set("", "", res.name)
			toom.config_toggle_set(res.cam, res.mic)
			toom.config_store()
			mc, ok := toom.meeting_decode(res.code)
			if !ok {
				toom.form_error("Invalid meeting code")
				continue
			}
			server = mc.H
			room = mc.R
			secret = mc.K
			name = res.name
			cam = res.cam
			mic = res.mic
		}
		err := toom.conference_run(server, room, name, secret, create, cam, mic)
		if err != "" {
			toom.form_error(err)
		}
		toom.config_store()
		sync.atomic_store(&toom.app_stop, 0)
	}
	toom.term_leave_full()
}
