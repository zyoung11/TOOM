//go:build !windows

package service

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

const unitName = "toom-server.service"

func install(cfgPath string) error {
	if _, err := os.Stat("/run/systemd/system"); err != nil {
		return fmt.Errorf("systemd is not available, start toom-server run with your init instead")
	}
	if os.Geteuid() != 0 {
		return fmt.Errorf("install requires root, run with sudo")
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	unit := unitText(exe, cfgPath)

	unitPath := filepath.Join("/etc/systemd/system", unitName)
	if err := os.WriteFile(unitPath, []byte(unit), 0644); err != nil {
		return fmt.Errorf("failed to write %s: %w", unitPath, err)
	}
	for _, cmd := range [][]string{
		{"systemctl", "daemon-reload"},
		{"systemctl", "enable", "toom-server"},
		{"systemctl", "restart", "toom-server"},
	} {
		if out, err := exec.Command(cmd[0], cmd[1:]...).CombinedOutput(); err != nil {
			return fmt.Errorf("%s failed: %v (%s)", strings.Join(cmd, " "), err, strings.TrimSpace(string(out)))
		}
	}
	time.Sleep(time.Second)
	out, _ := exec.Command("systemctl", "is-active", "toom-server").Output()
	status := strings.TrimSpace(string(out))
	if status != "active" {
		return fmt.Errorf("service is %q after start, check journalctl -u toom-server", status)
	}
	return nil
}

func uninstall() error {
	if os.Geteuid() != 0 {
		return fmt.Errorf("uninstall requires root, run with sudo")
	}
	exec.Command("systemctl", "stop", "toom-server").Run()
	exec.Command("systemctl", "disable", "toom-server").Run()
	unitPath := filepath.Join("/etc/systemd/system", unitName)
	if err := os.Remove(unitPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to remove %s: %w", unitPath, err)
	}
	exec.Command("systemctl", "daemon-reload").Run()
	return nil
}

func runIfService(run func() error, _ func()) error {
	return run()
}

func unitText(exe, cfgPath string) string {
	return fmt.Sprintf(`[Unit]
Description=toom video call server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=%s run --config %s
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
`, exe, cfgPath)
}
