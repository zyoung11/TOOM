# TOOM

**中文版本**: [README_CN.md](README_CN.md)

Video conferencing in a terminal, written in Odin. H.264 and Opus over UDP through a small SFU, every picture drawn as sixel through the [Aideo](https://github.com/zyoung11/Aideo) rendering engine, vendored here as a static library. Client and server in one binary.

## How it works

- Every client talks only to the server and all data is relayed through it, there is no peer-to-peer path
- UDP single port, default 4400. Join is an HMAC-SHA256 challenge-response keyed by the meeting code
- Media is end-to-end encrypted with XChaCha20-Poly1305, the server forwards ciphertext only
- Camera tiles are 4:3, share tiles are 16:9 or 16:10. The boxes are fixed so the border never moves

## Features

- Sixel video in the terminal, screen sharing, system audio sharing
- H.264 via x264, NVENC or VAAPI with runtime fallback to x264
- Opus audio with webrtc echo cancellation
- Grid and focus layouts, configurable keys and picture border
- Static binary, runs on any glibc distribution

## Build

Dependencies: `odin`, `cc`, `git`, `cmake`, `meson`, `ninja`, `nasm`.

```bash
sh build.sh
```

## Usage

### Server

```bash
./toom run                      # foreground, default port 4400
./toom run --port 4400 --log    # write toom.log
sudo ./toom install --port 4400 # systemd service, auto-start
sudo ./toom uninstall           # stop and remove the service
./toom status --port 4400       # rooms, members and traffic
```

### Client

```bash
./toom                # meeting TUI
./toom --json <json>  # join from json
```

Create a room to get a meeting code, or join with one. The code is the join credential. The TUI refuses to run inside tmux.

### Options

| Option | Function |
|------|------|
| `--json <json>` | Apply config fields and join a meeting from json |
| `-h, --help` | Help page |
| `-V, --version` | Version |

### Shortcuts

Defaults. The `key_*` fields in the config change them.

| Key | Function |
|------|------|
| `q` | Quit, twice within 3 seconds confirms |
| `m` | Microphone on / off |
| `Shift+M` | Speaker mute / unmute |
| `c` | Camera on / off |
| `a` | System audio sharing on / off |
| `s` | Share menu: monitor or window |
| `p` | Settings: sound, picture, sharing |
| `↑` / `↓` | Volume up / down |
| `l` | Cycle grid and focus layouts; swap the share block with the members while sharing |
| `h` | Mirror the local preview only |
| `Tab` | Cycle the focused member |
| `i` | Show and copy the meeting code |
| `?` | Help page |

## Configuration

Everything is in `~/.config/toom/config.json`, written back on every change. `key_*` fields are the shortcuts. Camera device, capture size, frame rate, bitrate and encoder backend are settings here, not flags.

## Limitations

- IPv4 only, no NAT traversal. The server must be reachable by UDP
- The meeting code is the join credential
- Window sharing needs niri, floating windows only for now

## License

GPL-3.0-or-later, see [LICENSE](LICENSE). x264 is GPL v2 or later.
