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

// CmdOpt is one option row of a command help page.
CmdOpt :: struct {
	flag: string,
	desc: string,
}

// Cmd is the shared data source for dispatch and help rendering.
Cmd :: struct {
	name:    string,
	summary: string,
	usage:   string,
	opts:    []CmdOpt,
	run:     proc(args: []string) -> int,
}

cmds: [dynamic]Cmd

ex_run       := [?]string{"toom run", "toom run --port 4400 --log"}
ex_install   := [?]string{"sudo toom install", "sudo toom install --port 4400"}
ex_uninstall := [?]string{"sudo toom uninstall"}
ex_status    := [?]string{"toom status", "toom status --port 4400"}

cmd_examples :: proc(name: string) -> []string {
	switch name {
	case "run":
		return ex_run[:]
	case "install":
		return ex_install[:]
	case "uninstall":
		return ex_uninstall[:]
	case "status":
		return ex_status[:]
	}
	return nil
}

pad_to :: proc(s: string, width: int) -> string {
	return strings.repeat(" ", width - len(s))
}

print_usage :: proc() {
	fmt.printf("\n%s%stoom%s — terminal LAN video call and SFU\n\n", C_BOLD, C_BLUE, C_RESET)
	fmt.printf("%sUSAGE:%s\n", C_BOLD + C_MAUVE, C_RESET)
	fmt.printf("  %stoom%s %s[options]%s\n", C_BLUE, C_RESET, C_YELLOW, C_RESET)
	fmt.printf("  %stoom%s %s<command>%s\n", C_BLUE, C_RESET, C_YELLOW, C_RESET)
	client_rows := [?]CmdOpt{
		{"toom", "Start the meeting TUI"},
		{"--json <json>", "apply config fields and join a meeting from json"},
	}
	opt_rows := [?]CmdOpt{
		{"-h, --help", "show help"},
		{"-V, --version", "show version"},
	}
	width := 0
	for r in client_rows {
		if len(r.flag) > width {
			width = len(r.flag)
		}
	}
	for c in cmds {
		if len(c.name) > width {
			width = len(c.name)
		}
	}
	for r in opt_rows {
		if len(r.flag) > width {
			width = len(r.flag)
		}
	}
	fmt.printf("\n%sCLIENT:%s\n", C_BOLD + C_MAUVE, C_RESET)
	fmt.printf("  %s%s%s%s %s\n", C_GREEN, client_rows[0].flag, pad_to(client_rows[0].flag, width), C_RESET, client_rows[0].desc)
	fmt.printf("  %s%s%s%s %s\n", C_YELLOW, client_rows[1].flag, pad_to(client_rows[1].flag, width), C_RESET, client_rows[1].desc)
	fmt.printf("\n%sSERVER:%s\n", C_BOLD + C_MAUVE, C_RESET)
	for c in cmds {
		fmt.printf("  %s%s%s%s %s\n", C_GREEN, c.name, pad_to(c.name, width), C_RESET, c.summary)
	}
	fmt.printf("\n%sOPTIONS:%s\n", C_BOLD + C_MAUVE, C_RESET)
	for r in opt_rows {
		fmt.printf("  %s%s%s%s %s\n", C_YELLOW, r.flag, pad_to(r.flag, width), C_RESET, r.desc)
	}
	fmt.println()
}

print_command_usage :: proc(c: Cmd) {
	fmt.printf("\n%s%stoom %s%s — %s%s\n\n", C_BOLD, C_BLUE, c.name, C_RESET, c.summary, C_RESET)
	fmt.printf("%sUSAGE:%s\n", C_BOLD + C_MAUVE, C_RESET)
	fmt.printf("  %s%s%s\n", C_BLUE, c.usage, C_RESET)
	if len(c.opts) > 0 {
		fmt.printf("\n%sOPTIONS:%s\n", C_BOLD + C_MAUVE, C_RESET)
		width := 0
		for o in c.opts {
			if len(o.flag) > width {
				width = len(o.flag)
			}
		}
		for o in c.opts {
			fmt.printf("  %s%s%s%s %s\n", C_YELLOW, o.flag, pad_to(o.flag, width), C_RESET, o.desc)
		}
	}
	examples := cmd_examples(c.name)
	if len(examples) > 0 {
		fmt.printf("\n%sEXAMPLES:%s\n", C_BOLD + C_MAUVE, C_RESET)
		for e in examples {
			fmt.printf("  %s%s%s\n", C_BLUE, e, C_RESET)
		}
	}
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

is_help_arg :: proc(s: string) -> bool {
	return s == "-h" || s == "--help" || s == "help"
}

main :: proc() {
	append(&cmds, Cmd{
		name = "run", summary = "Run the SFU in foreground for debugging",
		usage = "toom run [--port <n>] [--log]",
		opts = []CmdOpt{
			{"--port <n>", "listen port, default 4400"},
			{"--log", "write toom.log next to the binary"},
		},
		run = toom.srv_cmd_run,
	})
	append(&cmds, Cmd{
		name = "install", summary = "Start the SFU and enable auto-start",
		usage = "toom install [--port <n>]",
		opts = []CmdOpt{
			{"--port <n>", "listen port, default 4400"},
		},
		run = toom.srv_cmd_install,
	})
	append(&cmds, Cmd{
		name = "uninstall", summary = "Stop the SFU and disable auto-start",
		usage = "toom uninstall",
		run = toom.srv_cmd_uninstall,
	})
	append(&cmds, Cmd{
		name = "status", summary = "Show SFU status and room counters",
		usage = "toom status [--port <n>]",
		opts = []CmdOpt{
			{"--port <n>", "listen port, default 4400"},
		},
		run = toom.srv_cmd_status,
	})

	if len(os.args) >= 2 {
		name := os.args[1]
		switch name {
		case "-h", "--help", "help":
			print_usage()
			return
		case "-V", "-v", "--version", "version":
			print_version()
			return
		}
		for c in cmds {
			if c.name == name {
				if len(os.args) > 2 && is_help_arg(os.args[2]) {
					print_command_usage(c)
					return
				}
				os.exit(c.run(os.args[2:]))
			}
		}
		if name != "--json" {
			fmt.eprintf("%s[-]%s unknown command %s\n", C_YELLOW, C_RESET, name)
			print_usage()
			os.exit(1)
		}
	}

	toom.av_log_set_level(-8)
	if !toom.crypto_self_test() {
		fmt.eprintln("[-] crypto self test failed")
		os.exit(1)
	}

	toom.config_load()
	toom.config_apply()

	json_data := ""
	i := 1
	for i < len(os.args) {
		a := os.args[i]
		if a == "--json" {
			i += 1
			if i >= len(os.args) {
				fmt.eprintln("[-] missing value for --json")
				os.exit(1)
			}
			json_data = os.args[i]
		} else {
			fmt.eprintf("[-] unknown option %s\n", a)
			print_usage()
			os.exit(1)
		}
		i += 1
	}

	join_code := ""
	join_cam := toom.cam_default
	join_mic := toom.mic_default
	if json_data != "" {
		join_code, join_cam, join_mic = toom.config_json_apply(json_data)
	}

	toom.epoch = time.now()
	toom.term_sig_setup()
	toom.term_enter_full()
	thread.create_and_start(toom.input_thread)
	toom.term_sig_unblock()

	if join_code != "" {
		mc, ok := toom.meeting_decode(join_code)
		if !ok {
			toom.term_leave_full()
			fmt.eprintln("[-] invalid meeting code")
			os.exit(1)
		}
		err := toom.conference_run(mc.H, mc.R, toom.app_cfg.name, mc.K, false, join_cam, join_mic)
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
