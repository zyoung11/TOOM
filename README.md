# TOOM

终端内的多人视频会议。摄像头与麦克风采集后经 UDP 发到服务端转发，画面用
sixel 渲染在终端里，房间不超过 10 人，音频客户端混音。

## 架构

1. `server/`（Go）：轻量 SFU。管理房间与成员，挑战应答入会，媒体数据报原样转发。
2. `toom`（Odin）：入会表单、采集、H.264 与 Opus 编解码、多画面渲染、混音。
3. 渲染引擎来自 Aideo 源码包引入（`import aideo "../Aideo"`），Aideo 仓库零改动。

## 构建

依赖：Aideo 仓库（同级目录）、odin、cc、git、cmake、meson、nasm。

```bash
sh build.sh              # x264、libopus、dav1d、静态 FFmpeg、编码垫片、客户端
cd server && go build -ldflags="-s -w" -o toom-server ./cmd/toom-server
```

## 运行

服务端配置 `config.json`，放在二进制同目录或用 `--config` 指定。文件缺失时 `run` 与 `install` 自动写入默认值：

```json
{
  "port": 4400
}
```

服务端命令：

```bash
./server/toom-server run --config config.json    # 前台运行
./server/toom-server run --config config.json --log   # 同时写日志文件
sudo ./server/toom-server install --config config.json   # 安装 systemd 服务并开机自启
sudo ./server/toom-server uninstall                      # 停止并移除服务
```

客户端两步走：

1. 一方在 TUI 里选「创建房间」，输入服务器地址与房间名，拿到会议码。
2. 出码页按 Enter 会把会议码复制进剪贴板并入会，支持 wl-copy、xclip、xsel、pbcopy。
3. 另一方填名称与会议码，选「加入会议」。

加入与创建页的摄像头、麦克风开关只决定入会初始状态，会议内随时可开可关。
两页都能选摄像头、麦克风与音频设备，回车打开设备列表，单选即时生效。
采集列表只列真实输入设备，`.monitor` 回环监听源不显示。

| 选项 | 功能 |
| --- | --- |
| `-d <path>` | 摄像头设备，默认 `/dev/video0` |
| `-s <WxH>` | 采集尺寸，默认 640x480 |
| `-f <n>` | 帧率，1 至 60，默认 15 |
| `-b <n>` | 视频码率 kbps，默认 300 |
| `--enc <n>` | 编码后端，auto x264 vaapi nvenc |
| `-h, --help` | 帮助页 |
| `--version` | 版本 |

## 按键

| 键 | 功能 |
| --- | --- |
| `q` / `ESC` | 退出，3 秒内再按一次确认 |
| `m` | 扬声器静音 / 取消静音 |
| `n` | 麦克风开 / 关，首次开启才启动采集发送 |
| `c` | 摄像头开 / 关，首次开启才启动采集编码 |
| `↑` / `↓` | 音量增 / 减 |
| `f` | 布局循环：自适应网格 / 焦点大图 |
| `h` | 本地预览水平镜像切换，默认镜像，传出画面不镜像 |
| `Tab` / `←` / `→` | 选中成员 |
| `j` / `k` | 色数减 / 增，2 至 256 |
| `?` | 帮助页，任意键关闭 |

## 会议界面

布局自动适应终端尺寸与人数，画面下方一行说明行显示名字与静音状态。

- `grid`（默认）：按画面面积选网格，两人在宽终端左右排、窄终端上下排。
  空格子放房间信息卡，显示房间名、会议码末 4 位与包计数。
- `focus`：选中成员占七成大图，其余进缩略条。宽终端缩略条在右，窄终端在下。
- 底部两行：状态行加按键行。窄终端按优先级丢段，永不折行。
- 画面高度留安全区，sixel 尾部换行不触发屏幕滚动。

## 协议

UDP 单端口全双工。6 字节信封（版本、类型、大端长度）加消息体。

- 控制消息为 JSON，含建房、挑战应答入会、保活、成员事件、订阅。
- 媒体消息为二进制：16 字节明文头（发送者、序号、时间戳、流类型、分片）加分片载荷。
- 加密照搬 nz：入会 HMAC-SHA256 挑战应答，媒体 XChaCha20-Poly1305 全程加密。
- 密钥两级：`k_join = SHA256(secret + "join")` 存服务端验证入会，`k_media =
  SHA256(secret + "media")` 只在客户端，服务端无法解媒体。

## 依赖产物

| 库 | 用途 |
| --- | --- |
| `libavcodec` `libavutil` 等 | H.264 与 MJPEG 编解码，Aideo 播放器路径 |
| `libx264` `h264_nvenc` `h264_vaapi` | 视频编码三后端，运行时探测回退 |
| `libopus` | 音频编解码，48 kHz 单声道 20 ms |
| `miniaudio` | 麦克风采集与扬声器播放 |
| `avx2_quant.o` | sixel 量化，AVX2 内核 |

GPU 编码：NVIDIA 走 NVENC（dlopen 驱动，无链接依赖），Intel 与 AMD 走
VAAPI（运行时依赖 `libva.so.2` 与 `libdrm.so.2`），全部失败回退 libx264。

## 测试

```bash
cd server && go test -race ./...        # 协议与转发
sh server/test/podman.sh                # podman 组网，3 客户端互流
```

帮助页：`./toom-server --help` 为命令总览，`./toom-server run --help` 等为子命令页。

## 限制

- 局域网 IPv4 直连，不做 NAT 穿透。
- 不做回声消除，建议戴耳机。
- x264 为 GPL，二进制按 GPL 发布。
- 会议码是入会凭证，泄露即可入会。房间无人即关闭，同名可重建；从未入会的房间 30 分钟回收。
