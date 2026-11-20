package toom

import "core:c"
import posix "core:sys/posix"

CAM_MJPG :: 0x47504A4D
CAM_YUYV :: 0x56595559

V4L2_BUF_TYPE_VIDEO_CAPTURE :: 1
V4L2_MEMORY_MMAP            :: 1
V4L2_CAP_VIDEO_CAPTURE      :: 0x00000001

VIDIOC_QUERYCAP  :: 0x80685600
VIDIOC_S_FMT     :: 0xc0d05605
VIDIOC_REQBUFS   :: 0xc0145608
VIDIOC_QUERYBUF  :: 0xc0585609
VIDIOC_QBUF      :: 0xc058560f
VIDIOC_DQBUF     :: 0xc0585611
VIDIOC_STREAMON  :: 0x40045612
VIDIOC_STREAMOFF :: 0x40045613

O_RDWR      :: 2
O_NONBLOCK  :: 0x800
MAP_SHARED  :: 0x01
PROT_READ   :: 0x1
PROT_WRITE  :: 0x2

MAP_FAILED :: rawptr(~uintptr(0))

V4l2Capability :: struct {
	driver:    [16]u8,
	card:      [32]u8,
	bus_info:  [32]u8,
	version:   u32,
	caps:      u32,
	device_caps: u32,
	reserved:  [3]u32,
}

V4l2PixFormat :: struct {
	width:        u32,
	height:       u32,
	pixelformat:  u32,
	field:        u32,
	bytesperline: u32,
	sizeimage:    u32,
	colorspace:   u32,
	flags:        u32,
	quantization: u32,
	ycbcr_enc:    u32,
}

V4l2Format :: struct {
	typ: u32,
	pad: u32,
	pix: V4l2PixFormat,
	rest: [160]u8,
}

V4l2Requestbuffers :: struct {
	count:  u32,
	typ:    u32,
	memory: u32,
	caps:   u32,
	flags:  u8,
	pad:    [3]u8,
}

V4l2Timeval :: struct {
	sec:  i64,
	usec: i64,
}

V4l2Buffer :: struct {
	index:     u32,
	typ:       u32,
	bytesused: u32,
	flags:     u32,
	field:     u32,
	pad0:      u32,
	timestamp: V4l2Timeval,
	timecode:  [16]u8,
	sequence:  u32,
	memory:    u32,
	m:         u64,
	length:    u32,
	tail:      [12]u8,
}

// cam_open_dev opens a V4L2 device non blocking.
cam_open_dev :: proc(path: cstring) -> c.int {
	return c.int(posix.open(path, {.RDWR, .NONBLOCK}))
}

// cam_poll_fd waits until the device is readable.
cam_poll_fd :: proc(fd: c.int, timeout_ms: c.int) -> bool {
	pfd := posix.pollfd{fd = posix.FD(fd), events = {.IN}}
	return posix.poll(&pfd, 1, timeout_ms) > 0
}

foreign camlib {
	@(link_name="ioctl")
	cam_ioctl :: proc(fd: c.int, req: u64, arg: rawptr) -> c.int ---
	@(link_name="mmap")
	cam_mmap :: proc(addr: rawptr, len: u64, prot, flags, fd: c.int, off: u64) -> rawptr ---
	@(link_name="munmap")
	cam_munmap :: proc(addr: rawptr, len: u64) -> c.int ---
	@(link_name="close")
	cam_close :: proc(fd: c.int) -> c.int ---
}

foreign import camlib {
	"system:libc.so.6",
}

// Camera owns one V4L2 streaming capture device.
Camera :: struct {
	fd:     c.int,
	fmt:    u32,
	w:      int,
	h:      int,
	nbufs:  int,
	mems:   [4]rawptr,
	lens:   [4]u64,
	cur:    int,
	grabbed: bool,
}

// cam_xioctl retries ioctl calls interrupted by signals.
cam_xioctl :: proc(fd: c.int, req: u64, arg: rawptr) -> c.int {
	for {
		r := cam_ioctl(fd, req, arg)
		if r == 0 {
			return 0
		}
	}
}

// cam_start opens the device, negotiates MJPG or YUYV and streams.
cam_start :: proc(cam: ^Camera, dev: string, want_w, want_h: int) -> bool {
	buf: [256]u8
	n := min(len(dev), len(buf) - 1)
	copy(buf[:], dev[:n])
	buf[n] = 0
	fd := cam_open_dev(cast(cstring)&buf[0])
	if fd < 0 {
		return false
	}
	cam.fd = fd

	cap: V4l2Capability
	if cam_xioctl(fd, VIDIOC_QUERYCAP, &cap) != 0 || (cap.device_caps & V4L2_CAP_VIDEO_CAPTURE) == 0 {
		cam_stop(cam)
		return false
	}

	picked := false
	for fourcc in ([2]u32{CAM_MJPG, CAM_YUYV}) {
		f := V4l2Format{typ = V4L2_BUF_TYPE_VIDEO_CAPTURE}
		f.pix.width = u32(want_w)
		f.pix.height = u32(want_h)
		f.pix.pixelformat = fourcc
		if cam_xioctl(fd, VIDIOC_S_FMT, &f) == 0 && f.pix.pixelformat == fourcc {
			cam.fmt = fourcc
			cam.w = int(f.pix.width)
			cam.h = int(f.pix.height)
			picked = true
			break
		}
	}
	if !picked {
		cam_stop(cam)
		return false
	}

	req := V4l2Requestbuffers{count = 4, typ = V4L2_BUF_TYPE_VIDEO_CAPTURE, memory = V4L2_MEMORY_MMAP}
	if cam_xioctl(fd, VIDIOC_REQBUFS, &req) != 0 || req.count < 2 {
		cam_stop(cam)
		return false
	}
	cam.nbufs = int(req.count)
	for i in 0..<cam.nbufs {
		b := V4l2Buffer{typ = V4L2_BUF_TYPE_VIDEO_CAPTURE, memory = V4L2_MEMORY_MMAP}
		b.index = u32(i)
		if cam_xioctl(fd, VIDIOC_QUERYBUF, &b) != 0 {
			cam_stop(cam)
			return false
		}
		cam.lens[i] = u64(b.length)
		addr := cam_mmap(nil, u64(b.length), PROT_READ | PROT_WRITE, MAP_SHARED, fd, b.m)
		if addr == MAP_FAILED {
			cam.mems[i] = nil
			cam_stop(cam)
			return false
		}
		cam.mems[i] = addr
		if cam_xioctl(fd, VIDIOC_QBUF, &b) != 0 {
			cam_stop(cam)
			return false
		}
	}
	typ := c.int(V4L2_BUF_TYPE_VIDEO_CAPTURE)
	if cam_ioctl(fd, VIDIOC_STREAMON, &typ) != 0 {
		cam_stop(cam)
		return false
	}
	return true
}

// cam_grab waits for one frame and returns its bytes.
cam_grab :: proc(cam: ^Camera, timeout_ms: int) -> ([]u8, bool) {
	if cam.grabbed {
		return nil, false
	}
	if !cam_poll_fd(cam.fd, c.int(timeout_ms)) {
		return nil, false
	}
	b := V4l2Buffer{typ = V4L2_BUF_TYPE_VIDEO_CAPTURE, memory = V4L2_MEMORY_MMAP}
	if cam_ioctl(cam.fd, VIDIOC_DQBUF, &b) != 0 {
		return nil, false
	}
	cam.cur = int(b.index)
	cam.grabbed = true
	ptr := ([^]u8)(cam.mems[cam.cur])
	return ptr[:int(b.bytesused)], true
}

cam_ungrab :: proc(cam: ^Camera) {
	if !cam.grabbed {
		return
	}
	b := V4l2Buffer{typ = V4L2_BUF_TYPE_VIDEO_CAPTURE, memory = V4L2_MEMORY_MMAP}
	b.index = u32(cam.cur)
	cam_ioctl(cam.fd, VIDIOC_QBUF, &b)
	cam.grabbed = false
}

cam_stop :: proc(cam: ^Camera) {
	if cam.fd > 0 {
		typ := c.int(V4L2_BUF_TYPE_VIDEO_CAPTURE)
		cam_ioctl(cam.fd, VIDIOC_STREAMOFF, &typ)
		for i in 0..<cam.nbufs {
			if cam.mems[i] != nil {
				cam_munmap(cam.mems[i], cam.lens[i])
				cam.mems[i] = nil
			}
		}
		cam_close(cam.fd)
		cam.fd = 0
	}
}
