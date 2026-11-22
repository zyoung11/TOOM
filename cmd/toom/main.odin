package main

import "core:encoding/hex"
import "core:fmt"
import "core:os"
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
		{"-h, --help", "show help"},
		{"-V, --version", "show version"},
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
	fmt.println()
}

print_version :: proc() {
	fmt.printf("%stoom%s %s%s%s\n", C_BLUE, C_RESET, C_GREEN, VERSION, C_RESET)
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

	i := 1
	for i < len(os.args) {
		a := os.args[i]
		if a == "-h" || a == "--help" {
			print_help()
			return
		} else if a == "-V" || a == "--version" {
			print_version()
			return
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
