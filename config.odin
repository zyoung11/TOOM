package toom

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

// AppConfig holds every persistable setting and form value. The file
// ~/.config/toom/config.json always carries all fields so hand
// editing stays easy.
AppConfig :: struct {
	server:        string `json:"server"`,
	room:          string `json:"room"`,
	name:          string `json:"name"`,
	camera:        string `json:"camera"`,
	width:         int    `json:"width"`,
	height:        int    `json:"height"`,
	fps:           int    `json:"fps"`,
	kbps:          int    `json:"kbps"`,
	encoder:       string `json:"encoder"`,
	input_device:  string `json:"input_device"`,
	input_name:    string `json:"input_name"`,
	output_device: string `json:"output_device"`,
	output_name:   string `json:"output_name"`,
	mirror:        bool   `json:"mirror"`,
	colors:        int    `json:"colors"`,
	layout:        string `json:"layout"`,
	volume:        int    `json:"volume"`,
	cursor:        bool   `json:"cursor"`,
	windows:       bool   `json:"windows"`,
	mic_default:   bool   `json:"mic_default"`,
	spk_default:   bool   `json:"spk_default"`,
	cam_default:   bool   `json:"cam_default"`,
	canvas_width:  int    `json:"canvas_width"`,
	language:      string `json:"language"`,
	key_quit:      string `json:"key_quit"`,
	key_help:      string `json:"key_help"`,
	key_mic:       string `json:"key_mic"`,
	key_spk:       string `json:"key_spk"`,
	key_cam:       string `json:"key_cam"`,
	key_desk:      string `json:"key_desk"`,
	key_share:     string `json:"key_share"`,
	key_settings:  string `json:"key_settings"`,
	key_layout:    string `json:"key_layout"`,
	key_mirror:    string `json:"key_mirror"`,
	key_code:      string `json:"key_code"`,
}

app_cfg: AppConfig

// mic_default, spk_default and cam_default are the join defaults for
// the session switches.
mic_default: bool = true
spk_default: bool = true
cam_default: bool = true

// config_default returns the first run configuration with owned
// strings so later updates can free them.
config_default :: proc() -> AppConfig {
	return AppConfig{
		server = strings.clone("127.0.0.1:4400"),
		room = strings.clone("room"),
		name = strings.clone("user"),
		camera = strings.clone("/dev/video0"),
		width = 640,
		height = 480,
		fps = 15,
		kbps = 300,
		encoder = strings.clone("auto"),
		input_device = strings.clone(""),
		input_name = strings.clone(""),
		output_device = strings.clone(""),
		output_name = strings.clone(""),
		mirror = true,
		colors = 64,
		layout = strings.clone("grid"),
		volume = 100,
		cursor = true,
		windows = false,
		mic_default = true,
		spk_default = true,
		cam_default = true,
		canvas_width = 200,
		language = strings.clone("en"),
		key_quit = strings.clone("q"),
		key_help = strings.clone("?"),
		key_mic = strings.clone("m"),
		key_spk = strings.clone("M"),
		key_cam = strings.clone("c"),
		key_desk = strings.clone("a"),
		key_share = strings.clone("s"),
		key_settings = strings.clone("p"),
		key_layout = strings.clone("l"),
		key_mirror = strings.clone("h"),
		key_code = strings.clone("i"),
	}
}

// config_dir returns the toom configuration directory.
config_dir :: proc() -> string {
	home := os.get_env_alloc("HOME", context.allocator)
	if home == "" {
		return strings.clone(".config/toom")
	}
	s := fmt.tprintf("%s/.config/toom", home)
	delete(home)
	return strings.clone(s)
}

// config_path returns the toom configuration file path.
config_path :: proc() -> string {
	dir := config_dir()
	s := fmt.tprintf("%s/config.json", dir)
	delete(dir)
	return strings.clone(s)
}

// config_set_str replaces one owned config string.
config_set_str :: proc(dst: ^string, s: string) {
	if len(dst^) > 0 {
		delete(dst^)
	}
	dst^ = strings.clone(s)
}

// encoder_name maps one encoder preference to its config name.
encoder_name :: proc(idx: int) -> string {
	switch idx {
	case 1:
		return "x264"
	case 2:
		return "vaapi"
	case 3:
		return "nvenc"
	}
	return "auto"
}

// encoder_index maps one config encoder name to its preference.
encoder_index :: proc(name: string) -> int {
	switch name {
	case "x264":
		return 1
	case "vaapi":
		return 2
	case "nvenc":
		return 3
	}
	return 0
}

// color_index returns the palette slot closest to one color count.
color_index :: proc(colors: int) -> int {
	best := 0
	best_d := abs(CONF_COLORS[0] - colors)
	for v, i in CONF_COLORS {
		d := abs(v - colors)
		if d < best_d {
			best_d = d
			best = i
		}
	}
	return best
}

// config_collect copies the live settings into the config.
config_collect :: proc() {
	config_set_str(&app_cfg.camera, cam_dev)
	app_cfg.width = cam_w_req
	app_cfg.height = cam_h_req
	app_cfg.fps = app_fps
	app_cfg.kbps = enc_kbps
	config_set_str(&app_cfg.encoder, encoder_name(enc_prefer))
	config_set_str(&app_cfg.input_device, dev_pick[0].use)
	config_set_str(&app_cfg.input_name, dev_pick[0].name)
	config_set_str(&app_cfg.output_device, dev_pick[1].use)
	config_set_str(&app_cfg.output_name, dev_pick[1].name)
	app_cfg.mirror = sync.atomic_load(&self_mirror) != 0
	levels := CONF_COLORS
	app_cfg.colors = levels[color_idx]
	config_set_str(&app_cfg.layout, "grid")
	if conf_mode == .Focus {
		config_set_str(&app_cfg.layout, "focus")
	}
	app_cfg.volume = vol_pct()
	app_cfg.cursor = sync.atomic_load(&share_cursor) != 0
	app_cfg.windows = sync.atomic_load(&share_win_menu) != 0
	app_cfg.mic_default = mic_default
	app_cfg.spk_default = spk_default
	app_cfg.cam_default = cam_default
	app_cfg.canvas_width = canvas_width
	config_set_str(&app_cfg.language, "en")
	if lang_zh {
		config_set_str(&app_cfg.language, "zh")
	}
}

// config_apply installs the persisted settings as live defaults.
config_apply :: proc() {
	if len(app_cfg.camera) > 0 {
		cam_set(app_cfg.camera)
	}
	cam_w_req = app_cfg.width
	cam_h_req = app_cfg.height
	app_fps = app_cfg.fps
	enc_kbps = app_cfg.kbps
	enc_prefer = encoder_index(app_cfg.encoder)
	config_set_str(&dev_pick[0].use, app_cfg.input_device)
	config_set_str(&dev_pick[0].name, app_cfg.input_name)
	config_set_str(&dev_pick[1].use, app_cfg.output_device)
	config_set_str(&dev_pick[1].name, app_cfg.output_name)
	if app_cfg.mirror {
		sync.atomic_store(&self_mirror, 1)
	} else {
		sync.atomic_store(&self_mirror, 0)
	}
	color_idx = color_index(app_cfg.colors)
	conf_mode = .Grid
	if app_cfg.layout == "focus" {
		conf_mode = .Focus
	}
	audio_vol_set(f32(clamp(app_cfg.volume, 0, 200)) / 100)
	if app_cfg.cursor {
		sync.atomic_store(&share_cursor, 1)
	} else {
		sync.atomic_store(&share_cursor, 0)
	}
	if app_cfg.windows {
		sync.atomic_store(&share_win_menu, 1)
	} else {
		sync.atomic_store(&share_win_menu, 0)
	}
	mic_default = app_cfg.mic_default
	spk_default = app_cfg.spk_default
	cam_default = app_cfg.cam_default
	if app_cfg.canvas_width >= 20 {
		canvas_width = app_cfg.canvas_width
	}
	lang_zh = app_cfg.language == "zh"
}

// config_form_set stores the submitted form values. Empty values keep
// the stored ones so the join form can save only the name.
config_form_set :: proc(server, room, name: string) {
	if server != "" {
		config_set_str(&app_cfg.server, server)
	}
	if room != "" {
		config_set_str(&app_cfg.room, room)
	}
	if name != "" {
		config_set_str(&app_cfg.name, name)
	}
}

// config_toggle_set stores the form toggles as the new join defaults.
config_toggle_set :: proc(cam, mic: bool) {
	cam_default = cam
	mic_default = mic
	app_cfg.cam_default = cam
	app_cfg.mic_default = mic
}

// config_save writes the config file as it is.
config_save :: proc() {
	data, err := json.marshal(app_cfg, {pretty = true})
	if err != nil {
		return
	}
	defer delete(data)
	dir := config_dir()
	root := dir[:max(len(dir) - 5, 0)]
	_ = os.make_directory(root)
	_ = os.make_directory(dir)
	delete(dir)
	path := config_path()
	defer delete(path)
	_ = os.write_entire_file_from_bytes(path, data)
}

// config_store collects the live settings and writes the config file.
config_store :: proc() {
	config_collect()
	config_save()
}

// config_json_apply overlays one automation spec on the live config
// and returns the meeting join request. Every config field is accepted
// plus join_code, camera_on and microphone_on. Missing fields keep
// their current values.
config_json_apply :: proc(data: string) -> (string, bool, bool) {
	raw := transmute([]u8)data
	if json.unmarshal(raw, &app_cfg) != nil {
		fmt.eprintln("[-] --json: bad config json")
		return "", false, false
	}
	extra: struct {
		JoinCode: string `json:"join_code"`,
		CamOn:    bool   `json:"camera_on"`,
		MicOn:    bool   `json:"microphone_on"`,
	}
	_ = json.unmarshal(raw, &extra)
	config_apply()
	return extra.JoinCode, extra.CamOn, extra.MicOn
}

// config_load reads the config file and writes it on first run. The
// defaults are loaded first so missing fields keep sane values.
config_load :: proc() {
	app_cfg = config_default()
	path := config_path()
	defer delete(path)
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		config_save()
		return
	}
	defer delete(data)
	if json.unmarshal(data, &app_cfg) != nil {
		app_cfg = config_default()
		config_save()
		return
	}
	if app_cfg.width <= 0 || app_cfg.height <= 0 || app_cfg.fps <= 0 {
		app_cfg = config_default()
		config_save()
	}
}
