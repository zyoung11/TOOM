package toom

import "core:c"
import "core:fmt"
import "core:os"
import posix "core:sys/posix"
import "core:strings"
import "core:sync"
import "core:time"

SRV_LOG_FILE    :: "toom.log"
SRV_UNIT_NAME   :: "toom.service"

srv_color_blue   :: "\x1b[38;2;138;173;244m"
srv_color_green  :: "\x1b[38;2;166;218;149m"
srv_color_yellow :: "\x1b[38;2;238;212;159m"
srv_color_red    :: "\x1b[38;2;237;135;150m"
srv_color_reset  :: "\x1b[0m"

srv_log_info :: proc(msg: string) {
	fmt.printf("%s[i]%s %s\n", srv_color_blue, srv_color_reset, msg)
}

srv_log_success :: proc(msg: string) {
	fmt.printf("%s[+]%s %s\n", srv_color_green, srv_color_reset, msg)
}

srv_log_warn :: proc(msg: string) {
	fmt.printf("%s[!]%s %s\n", srv_color_yellow, srv_color_reset, msg)
}

srv_log_error :: proc(msg: string) {
	fmt.printf("%s[-]%s %s\n", srv_color_red, srv_color_reset, msg)
}

srv_quit_handler :: proc "c" (_: c.int) {
	sync.atomic_store(&srv_stop, 1)
}

foreign srvlib {
	@(link_name="readlink")
	srv_readlink :: proc(path: cstring, buf: rawptr, n: u64) -> i64 ---
	@(link_name="system")
	srv_system :: proc(cmd: cstring) -> c.int ---
	@(link_name="popen")
	srv_popen :: proc(cmd: cstring, mode: cstring) -> rawptr ---
	@(link_name="pclose")
	srv_pclose :: proc(f: rawptr) -> c.int ---
	@(link_name="fread")
	srv_fread :: proc(buf: rawptr, size: u64, n: u64, f: rawptr) -> u64 ---
	@(link_name="fclose")
	srv_fclose :: proc(f: rawptr) -> c.int ---
	@(link_name="dup2")
	srv_dup2 :: proc(oldfd: c.int, newfd: c.int) -> c.int ---
	@(link_name="geteuid")
	srv_geteuid :: proc() -> u32 ---
}

foreign import srvlib {
	"system:libc.so.6",
}

// srv_exe_path returns the path of the running binary.
srv_exe_path :: proc() -> string {
	buf: [512]u8
	n := srv_readlink("/proc/self/exe", &buf[0], u64(len(buf) - 1))
	if n <= 0 {
		return ""
	}
	return strings.clone(string(buf[:n]))
}

// srv_capture runs one shell command and returns its trimmed stdout.
srv_capture :: proc(cmd: string) -> string {
	cbuf: [256]u8
	n := min(len(cmd), len(cbuf) - 1)
	copy(cbuf[:], cmd[:n])
	cbuf[n] = 0
	f := srv_popen(cast(cstring)&cbuf[0], "r")
	if f == nil {
		return ""
	}
	obuf: [512]u8
	total := srv_fread(&obuf[0], 1, u64(len(obuf) - 1), f)
	_ = srv_pclose(f)
	out := strings.trim_right(string(obuf[:total]), " \t\r\n")
	return strings.clone(out)
}

// srv_unit_text renders the systemd unit file for the server.
srv_unit_text :: proc(exe: string, port: int) -> string {
	return fmt.tprintf(`[Unit]
Description=toom video call server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=%s run --port %d
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
`, exe, port)
}

// srv_args_parse reads the --port and --log options from one command
// line.
srv_args_parse :: proc(args: []string) -> (int, bool, bool) {
	port := DEFAULT_PORT
	log_flag := false
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		if a == "--port" {
			i += 1
			if i >= len(args) {
				srv_log_error("missing value for --port")
				return port, log_flag, false
			}
			p, valid := parse_port(args[i])
			if !valid {
				srv_log_error(fmt.tprintf("bad port %s", args[i]))
				return port, log_flag, false
			}
			port = p
		} else if a == "--log" {
			log_flag = true
		} else {
			srv_log_error(fmt.tprintf("unknown option %s", a))
			return port, log_flag, false
		}
	}
	return port, log_flag, true
}

SRV_O_WRONLY :: 1
SRV_O_CREAT  :: 64
SRV_O_APPEND :: 1024

// srv_log_file redirects stdout and stderr to the log file next to
// the binary.
srv_log_file :: proc() -> bool {
	exe := srv_exe_path()
	defer delete(exe)
	if exe == "" {
		return false
	}
	i := strings.last_index_byte(exe, '/')
	path := fmt.tprintf("%s/%s", exe[:i], SRV_LOG_FILE)
	pbuf: [512]u8
	fd := posix.open(to_cstr(path, pbuf[:]), {.WRONLY, .CREAT, .APPEND}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd < 0 {
		return false
	}
	_ = srv_dup2(c.int(fd), 1)
	_ = srv_dup2(c.int(fd), 2)
	return true
}

// srv_cmd_run runs the SFU in the foreground and returns the exit
// code.
srv_cmd_run :: proc(args: []string) -> int {
	port, log_flag, ok := srv_args_parse(args)
	if !ok {
		return 1
	}
	if log_flag {
		if !srv_log_file() {
			srv_log_error("failed to open log file")
			return 1
		}
	}
	signal(2, cast(rawptr)srv_quit_handler)
	signal(15, cast(rawptr)srv_quit_handler)
	s := srv_new(port)
	forwarded, dropped := srv_run(s)
	srv_log_info(fmt.tprintf("forwarded %d datagrams, dropped %d", forwarded, dropped))
	srv_log_success("stopped")
	return 0
}

// srv_cmd_install registers the server as a systemd service and
// returns the exit code.
srv_cmd_install :: proc(args: []string) -> int {
	port, _, ok := srv_args_parse(args)
	if !ok {
		return 1
	}
	if srv_geteuid() != 0 {
		srv_log_error("install requires root, run with sudo")
		return 1
	}
	_, sys_err := os.stat("/run/systemd/system", context.allocator)
	if sys_err != nil {
		srv_log_error("systemd is not available, start toom run with your init instead")
		return 1
	}
	exe := srv_exe_path()
	if exe == "" {
		srv_log_error("cannot resolve binary path")
		return 1
	}
	unit := srv_unit_text(exe, port)
	unit_path := fmt.tprintf("/etc/systemd/system/%s", SRV_UNIT_NAME)
	if werr := os.write_entire_file_from_string(unit_path, unit); werr != nil {
		srv_log_error(fmt.tprintf("failed to write %s", unit_path))
		return 1
	}
	steps := [?]string{"systemctl daemon-reload", "systemctl enable toom", "systemctl restart toom"}
	for cmd in steps {
		cbuf: [128]u8
		n := min(len(cmd), len(cbuf) - 1)
		copy(cbuf[:], cmd[:n])
		cbuf[n] = 0
		if srv_system(cast(cstring)&cbuf[0]) != 0 {
			srv_log_error(fmt.tprintf("%s failed", cmd))
			return 1
		}
	}
	time.sleep(1 * time.Second)
	if srv_capture("systemctl is-active toom") != "active" {
		srv_log_error("service is not active after start, check journalctl -u toom")
		return 1
	}
	srv_log_success("server started and auto-start enabled")
	return 0
}

// srv_cmd_uninstall removes the systemd service and returns the exit
// code.
srv_cmd_uninstall :: proc(_: []string) -> int {
	if srv_geteuid() != 0 {
		srv_log_error("uninstall requires root, run with sudo")
		return 1
	}
	_ = srv_system("systemctl stop toom")
	_ = srv_system("systemctl disable toom")
	unit_path := fmt.tprintf("/etc/systemd/system/%s", SRV_UNIT_NAME)
	_, stat_err := os.stat(unit_path, context.allocator)
	if stat_err == nil {
		_ = os.remove(unit_path)
	}
	_ = srv_system("systemctl daemon-reload")
	srv_log_success("server stopped and auto-start disabled")
	return 0
}

// srv_cmd_status prints the service state, the port reachability and
// the room counters and returns the exit code.
srv_cmd_status :: proc(args: []string) -> int {
	port, _, ok := srv_args_parse(args)
	if !ok {
		return 1
	}
	active := srv_capture("systemctl is-active toom")
	enabled := srv_capture("systemctl is-enabled toom")
	srv_log_info(fmt.tprintf("service: %s", active))
	srv_log_info(fmt.tprintf("autostart: %s", enabled))
	rpy := srv_stats_query(port)
	if rpy == nil {
		srv_log_error(fmt.tprintf("port %d: no answer", port))
		return 1
	}
	srv_log_info(fmt.tprintf("port %d: answering", port))
	srv_log_info(fmt.tprintf("rooms: %d, members: %d", rpy.Rooms, rpy.Members))
	srv_log_info(fmt.tprintf("forwarded %d datagrams, dropped %d", rpy.Forwarded, rpy.Dropped))
	return 0
}

// srv_stats_query asks one server for its counters and returns nil
// when it does not answer.
srv_stats_query :: proc(port: int) -> ^StatsRpyMsg {
	fd := net_open()
	if fd < 0 {
		return nil
	}
	defer sock_close(c.int(fd))
	srv_addr, ok := net_addr("127.0.0.1", u16(port))
	if !ok {
		return nil
	}
	body := json_marshal(StatsMsg{})
	defer delete(body)
	env := env_marshal(Envelope{typ = MSG_STATS, body = body})
	defer delete(env)
	net_send(fd, &srv_addr, env)
	buf: [2048]u8
	addr: SockAddr
	for i := 0; i < 15; i += 1 {
		n := net_recv(fd, buf[:], &addr)
		if n <= 0 {
			continue
		}
		e, good := env_unmarshal(buf[:n])
		if !good || e.typ != MSG_STATS {
			continue
		}
		rpy := new(StatsRpyMsg)
		if !json_unmarshal(e.body, rpy) {
			free(rpy)
			return nil
		}
		return rpy
	}
	return nil
}
