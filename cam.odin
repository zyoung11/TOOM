package toom

import "core:c"
import "core:fmt"
import "core:strings"
import posix "core:sys/posix"
import "core:time"

CAM_MJPG :: 0x47504A4D
CAM_YUYV :: 0x56595559

V4L2_BUF_TYPE_VIDEO_CAPTURE :: 1
V4L2_BUF_TYPE_VIDEO_OUTPUT :: 3
V4L2_MEMORY_MMAP :: 1
V4L2_CAP_VIDEO_CAPTURE :: 0x00000001
V4L2_CAP_VIDEO_OUTPUT :: 0x00000002
V4L2_FIELD_NONE :: 1

VIDIOC_QUERYCAP :: 0x80685600
VIDIOC_S_FMT :: 0xc0d05605
VIDIOC_REQBUFS :: 0xc0145608
VIDIOC_QUERYBUF :: 0xc0585609
VIDIOC_QBUF :: 0xc058560f
VIDIOC_DQBUF :: 0xc0585611
VIDIOC_STREAMON :: 0x40045612
VIDIOC_STREAMOFF :: 0x40045613

O_RDWR :: 2
O_NONBLOCK :: 0x800
MAP_SHARED :: 0x01
PROT_READ :: 0x1
PROT_WRITE :: 0x2

MAP_FAILED :: rawptr(~uintptr(0))

V4l2Capability :: struct {
	driver:      [16]u8,
	card:        [32]u8,
	bus_info:    [32]u8,
	version:     u32,
	caps:        u32,
	device_caps: u32,
	reserved:    [3]u32,
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
	typ:  u32,
	pad:  u32,
	pix:  V4l2PixFormat,
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

// CamGrab is the outcome of one frame grab. Lost means the device
// disappeared or wedged and the pipeline must restart.
CamGrab :: enum {
	None,
	Frame,
	Lost,
}

EIO :: 5
ENXIO :: 6
ENODEV :: 19

// cam_open_dev opens a V4L2 device non blocking.
cam_open_dev :: proc(path: cstring) -> c.int {
	return c.int(posix.open(path, {.RDWR, .NONBLOCK}))
}

foreign camlib {
	@(link_name = "ioctl")
	cam_ioctl :: proc(fd: c.int, req: u64, arg: rawptr) -> c.int ---
	@(link_name = "mmap")
	cam_mmap :: proc(addr: rawptr, len: u64, prot, flags, fd: c.int, off: u64) -> rawptr ---
	@(link_name = "munmap")
	cam_munmap :: proc(addr: rawptr, len: u64) -> c.int ---
	@(link_name = "close")
	cam_close :: proc(fd: c.int) -> c.int ---
	@(link_name = "flock")
	cam_flock :: proc(fd: c.int, op: c.int) -> c.int ---
	@(link_name = "__errno_location")
	cam_errno_loc :: proc() -> ^c.int ---
}

CAM_LOCK_EX :: 2
CAM_LOCK_NB :: 4
CAM_LOCK_UN :: 8

cam_lock_fd: c.int = -1
cam_fail: string

// cam_bus is the USB bus id of the running camera, used to find the
// device again after it reconnects on another node.
cam_bus: string

// cam_lock takes the per device lock file so one camera is never
// opened by two toom instances at once. The kernel blocks the losing
// instance inside the UVC driver, so the lock must be held before
// any streaming ioctl runs.
cam_lock :: proc(dev: string) -> bool {
	if cam_lock_fd >= 0 {
		return true
	}
	name := dev
	for i := len(dev) - 1; i >= 0; i -= 1 {
		if dev[i] == '/' {
			name = dev[i + 1:]
			break
		}
	}
	buf: [256]u8
	path := fmt.tprintf("/tmp/toom-%s.lock", name)
	fd := posix.open(
		to_cstr(path, buf[:]),
		{.RDWR, .NONBLOCK, .CREAT},
		posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH},
	)
	if fd < 0 {
		cam_fail = "camera: lock file failed"
		return false
	}
	cfd := cast(c.int)fd
	if cam_flock(cfd, CAM_LOCK_EX | CAM_LOCK_NB) != 0 {
		cam_close(cfd)
		cam_fail = "camera in use by another toom"
		return false
	}
	cam_lock_fd = cfd
	return true
}

// cam_unlock releases the per device lock file.
cam_unlock :: proc() {
	if cam_lock_fd >= 0 {
		cam_flock(cam_lock_fd, CAM_LOCK_UN)
		cam_close(cam_lock_fd)
		cam_lock_fd = -1
	}
}

foreign import camlib "system:libc.so.6"

// Camera owns one V4L2 streaming capture device.
Camera :: struct {
	fd:      c.int,
	fmt:     u32,
	w:       int,
	h:       int,
	nbufs:   int,
	mems:    [4]rawptr,
	lens:    [4]u64,
	cur:     int,
	grabbed: bool,
}

// cam_xioctl retries ioctl calls interrupted by signals.
// cam_xioctl retries ioctl calls interrupted by signals and gives up
// after a few attempts on a persistent error.
cam_xioctl :: proc(fd: c.int, req: u64, arg: rawptr) -> c.int {
	r: c.int = -1
	for _ in 0 ..< 4 {
		r = cam_ioctl(fd, req, arg)
		if r == 0 {
			return 0
		}
	}
	return r
}

// cam_start opens the device, negotiates MJPG or YUYV and streams.
cam_start :: proc(cam: ^Camera, dev: string, want_w, want_h: int) -> bool {
	cam_fail = ""
	if !cam_lock(dev) {
		return false
	}
	buf: [256]u8
	n := min(len(dev), len(buf) - 1)
	copy(buf[:], dev[:n])
	buf[n] = 0
	fd := cam_open_dev(cast(cstring)&buf[0])
	if fd < 0 {
		cam_unlock()
		cam_fail = "camera: device cannot be opened"
		return false
	}
	cam.fd = fd

	cap: V4l2Capability
	if cam_xioctl(fd, VIDIOC_QUERYCAP, &cap) != 0 ||
	   (cap.device_caps & V4L2_CAP_VIDEO_CAPTURE) == 0 {
		cam_fail = "camera: not a capture device"
		cam_stop(cam)
		return false
	}
	if cam_bus != "" {
		delete(cam_bus)
	}
	cam_bus = cstr_dup(&cap.bus_info[0])

	picked := false
	for fourcc in ([2]u32{CAM_MJPG, CAM_YUYV}) {
		f := V4l2Format {
			typ = V4L2_BUF_TYPE_VIDEO_CAPTURE,
		}
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
		cam_fail = tprintf("camera: format errno=%d", cam_errno_loc()^)
		cam_stop(cam)
		return false
	}

	req := V4l2Requestbuffers {
		count  = 4,
		typ    = V4L2_BUF_TYPE_VIDEO_CAPTURE,
		memory = V4L2_MEMORY_MMAP,
	}
	if cam_xioctl(fd, VIDIOC_REQBUFS, &req) != 0 || req.count < 2 {
		cam_fail = tprintf("camera: buffer request errno=%d", cam_errno_loc()^)
		cam_stop(cam)
		return false
	}
	cam.nbufs = int(req.count)
	for i in 0 ..< cam.nbufs {
		b := V4l2Buffer {
			typ    = V4L2_BUF_TYPE_VIDEO_CAPTURE,
			memory = V4L2_MEMORY_MMAP,
		}
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
		eno := cam_errno_loc()^
		if eno == 5 {
			cam_fail = "camera: device busy or has no writer"
		} else {
			cam_fail = tprintf("camera: stream start errno=%d", eno)
		}
		cam_stop(cam)
		return false
	}
	return true
}

// cam_probe reports whether the device opens right now.
cam_probe :: proc(path: string) -> bool {
	buf: [256]u8
	n := min(len(path), len(buf) - 1)
	copy(buf[:], path[:n])
	buf[n] = 0
	fd := cam_open_dev(cast(cstring)&buf[0])
	if fd < 0 {
		return false
	}
	cam_close(fd)
	return true
}

// cam_find_bus returns the device node that currently carries the
// given USB bus id. The caller owns the result.
cam_find_bus :: proc(bus: string) -> string {
	if bus == "" {
		return ""
	}
	cams := cam_enum_devs()
	defer dev_list_free(&cams)
	for e in cams {
		if e.bus == bus {
			return strings.clone(e.dev)
		}
	}
	return ""
}

// cam_grab waits for one frame and returns its bytes. Lost reports a
// gone device so the caller can restart the pipeline.
cam_grab :: proc(cam: ^Camera, timeout_ms: int) -> ([]u8, CamGrab) {
	if cam.grabbed {
		return nil, .None
	}
	pfd := posix.pollfd {
		fd     = posix.FD(cam.fd),
		events = {.IN},
	}
	n := posix.poll(&pfd, 1, c.int(timeout_ms))
	if n == 0 {
		return nil, .None
	}
	if n < 0 {
		return nil, .None
	}
	if pfd.revents & {.ERR, .HUP, .NVAL} != {} {
		return nil, .Lost
	}
	b := V4l2Buffer {
		typ    = V4L2_BUF_TYPE_VIDEO_CAPTURE,
		memory = V4L2_MEMORY_MMAP,
	}
	if cam_ioctl(cam.fd, VIDIOC_DQBUF, &b) != 0 {
		ene := cam_errno_loc()^
		if ene == EIO || ene == ENXIO || ene == ENODEV {
			return nil, .Lost
		}
		return nil, .None
	}
	cam.cur = int(b.index)
	cam.grabbed = true
	ptr := ([^]u8)(cam.mems[cam.cur])
	return ptr[:int(b.bytesused)], .Frame
}

cam_ungrab :: proc(cam: ^Camera) {
	if !cam.grabbed {
		return
	}
	b := V4l2Buffer {
		typ    = V4L2_BUF_TYPE_VIDEO_CAPTURE,
		memory = V4L2_MEMORY_MMAP,
	}
	b.index = u32(cam.cur)
	cam_ioctl(cam.fd, VIDIOC_QBUF, &b)
	cam.grabbed = false
}

cam_stop :: proc(cam: ^Camera) {
	cam_unlock()
	if cam.fd > 0 {
		typ := c.int(V4L2_BUF_TYPE_VIDEO_CAPTURE)
		cam_ioctl(cam.fd, VIDIOC_STREAMOFF, &typ)
		for i in 0 ..< cam.nbufs {
			if cam.mems[i] != nil {
				cam_munmap(cam.mems[i], cam.lens[i])
				cam.mems[i] = nil
			}
		}
		cam_close(cam.fd)
		cam.fd = 0
	}
}
