package toom

import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

VERSION :: "0.1.1"

A_MAUVE :: "\x1b[38;2;198;160;246m"
A_BOLD :: "\x1b[1m"
A_BLUE :: "\x1b[38;2;138;173;244m"
A_GREEN :: "\x1b[38;2;166;218;149m"
A_YELLOW :: "\x1b[38;2;238;212;159m"
A_RED :: "\x1b[38;2;237;135;150m"
A_RESET :: "\x1b[0m"

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

ex_run := [?]string{"toom run", "toom run --port 4400 --log"}
ex_install := [?]string{"sudo toom install", "sudo toom install --port 4400"}
ex_uninstall := [?]string{"sudo toom uninstall"}
ex_status := [?]string{"toom status", "toom status --port 4400"}

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
	fmt.printf("\n%s%stoom%s — terminal LAN video call and SFU\n\n", A_BOLD, A_BLUE, A_RESET)
	fmt.printf("%sUSAGE:%s\n", A_BOLD + A_MAUVE, A_RESET)
	fmt.printf("  %stoom%s %s[options]%s\n", A_BLUE, A_RESET, A_YELLOW, A_RESET)
	fmt.printf("  %stoom%s %s<command>%s\n", A_BLUE, A_RESET, A_YELLOW, A_RESET)
	client_rows := [?]CmdOpt {
		{"toom", "Start the meeting TUI"},
		{"--json <json>", "apply config fields and join a meeting from json"},
	}
	opt_rows := [?]CmdOpt{{"-h, --help", "show help"}, {"-V, --version", "show version"}}
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
	fmt.printf("\n%sCLIENT:%s\n", A_BOLD + A_MAUVE, A_RESET)
	fmt.printf(
		"  %s%s%s%s %s\n",
		A_GREEN,
		client_rows[0].flag,
		pad_to(client_rows[0].flag, width),
		A_RESET,
		client_rows[0].desc,
	)
	fmt.printf(
		"  %s%s%s%s %s\n",
		A_YELLOW,
		client_rows[1].flag,
		pad_to(client_rows[1].flag, width),
		A_RESET,
		client_rows[1].desc,
	)
	fmt.printf("\n%sSERVER:%s\n", A_BOLD + A_MAUVE, A_RESET)
	for c in cmds {
		fmt.printf("  %s%s%s%s %s\n", A_GREEN, c.name, pad_to(c.name, width), A_RESET, c.summary)
	}
	fmt.printf("\n%sOPTIONS:%s\n", A_BOLD + A_MAUVE, A_RESET)
	for r in opt_rows {
		fmt.printf("  %s%s%s%s %s\n", A_YELLOW, r.flag, pad_to(r.flag, width), A_RESET, r.desc)
	}
	fmt.println()
}

print_command_usage :: proc(c: Cmd) {
	fmt.printf("\n%s%stoom %s%s — %s%s\n\n", A_BOLD, A_BLUE, c.name, A_RESET, c.summary, A_RESET)
	fmt.printf("%sUSAGE:%s\n", A_BOLD + A_MAUVE, A_RESET)
	fmt.printf("  %s%s%s\n", A_BLUE, c.usage, A_RESET)
	if len(c.opts) > 0 {
		fmt.printf("\n%sOPTIONS:%s\n", A_BOLD + A_MAUVE, A_RESET)
		width := 0
		for o in c.opts {
			if len(o.flag) > width {
				width = len(o.flag)
			}
		}
		for o in c.opts {
			fmt.printf("  %s%s%s%s %s\n", A_YELLOW, o.flag, pad_to(o.flag, width), A_RESET, o.desc)
		}
	}
	examples := cmd_examples(c.name)
	if len(examples) > 0 {
		fmt.printf("\n%sEXAMPLES:%s\n", A_BOLD + A_MAUVE, A_RESET)
		for e in examples {
			fmt.printf("  %s%s%s\n", A_BLUE, e, A_RESET)
		}
	}
	fmt.println()
}

print_version :: proc() {
	fmt.printf("%stoom%s %s%s%s\n", A_BLUE, A_RESET, A_GREEN, VERSION, A_RESET)
}

random_secret :: proc() -> string {
	buf: [16]u8
	_ = rand_bytes(buf[:])
	out, _ := hex.encode(buf[:])
	s := strings.clone(string(out))
	delete(out)
	return s
}

is_help_arg :: proc(s: string) -> bool {
	return s == "-h" || s == "--help" || s == "help"
}

main :: proc() {
	append(
		&cmds,
		Cmd {
			name = "run",
			summary = "Run the SFU in foreground for debugging",
			usage = "toom run [--port <n>] [--log]",
			opts = []CmdOpt {
				{"--port <n>", "listen port, default 4400"},
				{"--log", "write toom.log next to the binary"},
			},
			run = srv_cmd_run,
		},
	)
	append(
		&cmds,
		Cmd {
			name = "install",
			summary = "Start the SFU and enable auto-start",
			usage = "toom install [--port <n>]",
			opts = []CmdOpt{{"--port <n>", "listen port, default 4400"}},
			run = srv_cmd_install,
		},
	)
	append(
		&cmds,
		Cmd {
			name = "uninstall",
			summary = "Stop the SFU and disable auto-start",
			usage = "toom uninstall",
			run = srv_cmd_uninstall,
		},
	)
	append(
		&cmds,
		Cmd {
			name = "status",
			summary = "Show SFU status and room counters",
			usage = "toom status [--port <n>]",
			opts = []CmdOpt{{"--port <n>", "listen port, default 4400"}},
			run = srv_cmd_status,
		},
	)

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
			fmt.eprintf("%s[-]%s unknown command %s\n", A_RED, A_RESET, name)
			print_usage()
			os.exit(1)
		}
	}

	if os.get_env_alloc("TMUX", context.allocator) != "" {
		fmt.eprintf("%s[-]%s the meeting TUI cannot run inside tmux\n", A_RED, A_RESET)
		fmt.eprintf("%s[i]%s start toom outside tmux\n", A_BLUE, A_RESET)
		os.exit(1)
	}

	av_log_set_level(-8)
	if !crypto_self_test() {
		fmt.eprintf("%s[-]%s crypto self test failed\n", A_RED, A_RESET)
		os.exit(1)
	}

	config_load()
	config_apply()

	json_data := ""
	i := 1
	for i < len(os.args) {
		a := os.args[i]
		if a == "--json" {
			i += 1
			if i >= len(os.args) {
				fmt.eprintf("%s[-]%s missing value for --json\n", A_RED, A_RESET)
				os.exit(1)
			}
			json_data = os.args[i]
		} else {
			fmt.eprintf("%s[-]%s unknown option %s\n", A_RED, A_RESET, a)
			print_usage()
			os.exit(1)
		}
		i += 1
	}

	join_code := ""
	join_cam := cam_default
	join_mic := mic_default
	if json_data != "" {
		join_code, join_cam, join_mic = config_json_apply(json_data)
	}

	epoch = time.now()
	term_sig_setup()
	term_enter_full()
	thread.create_and_start(input_thread)
	term_sig_unblock()

	if join_code != "" {
		mc, ok := meeting_decode(join_code)
		if !ok {
			term_leave_full()
			fmt.eprintf("%s[-]%s invalid meeting code\n", A_RED, A_RESET)
			os.exit(1)
		}
		if !srv_valid_name(mc.R) || !srv_valid_name(app_cfg.name) {
			term_leave_full()
			fmt.eprintf(
				"%s[-]%s room and name must be 1 to 32 printable characters\n",
				A_RED,
				A_RESET,
			)
			os.exit(1)
		}
		err := conference_run(mc.H, mc.R, app_cfg.name, mc.K, false, join_cam, join_mic)
		term_leave_full()
		if err != "" {
			fmt.eprintf("%s[-]%s %s\n", A_RED, A_RESET, err)
			os.exit(1)
		}
		return
	}

	for {
		choice := menu_select()
		if choice == .Quit {
			break
		}
		if choice == .Settings {
			dev_session = false
			dev_run()
			config_store()
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
			cres := form_create()
			if cres.back {
				continue
			}
			config_form_set(cres.server, cres.room, cres.name)
			config_toggle_set(cres.cam, cres.mic)
			config_store()
			secret = random_secret()
			if rerr := room_create_now(cres.server, cres.room, secret); rerr != "" {
				form_error(rerr)
				continue
			}
			code := meeting_encode(cres.server, cres.room, secret)
			if !code_show(code) {
				continue
			}
			server = cres.server
			room = cres.room
			name = cres.name
			cam = cres.cam
			mic = cres.mic
			create = true
		} else {
			res := form_join()
			if res.back {
				continue
			}
			config_form_set("", "", res.name)
			config_toggle_set(res.cam, res.mic)
			config_store()
			mc, ok := meeting_decode(res.code)
			if !ok {
				form_error("Invalid meeting code")
				continue
			}
			server = mc.H
			room = mc.R
			secret = mc.K
			name = res.name
			cam = res.cam
			mic = res.mic
		}
		err := conference_run(server, room, name, secret, create, cam, mic)
		if err != "" {
			form_error(err)
		}
		config_store()
		sync.atomic_store(&app_stop, 0)
	}
	term_leave_full()
}
