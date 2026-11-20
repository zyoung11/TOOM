// Package logx prints terminal log lines with the fixed prefix markers
// and Catppuccin Macchiato colors.
package logx

import "fmt"

const (
	colorBlue   = "\x1b[38;2;138;173;244m"
	colorGreen  = "\x1b[38;2;166;218;149m"
	colorYellow = "\x1b[38;2;238;212;159m"
	colorRed    = "\x1b[38;2;237;135;150m"
	colorReset  = "\x1b[0m"
)

// Info prints a status message.
func Info(msg string) {
	fmt.Printf("%s[i]%s %s\n", colorBlue, colorReset, msg)
}

// Success prints a completion message.
func Success(msg string) {
	fmt.Printf("%s[+]%s %s\n", colorGreen, colorReset, msg)
}

// Warn prints a warning message.
func Warn(msg string) {
	fmt.Printf("%s[!]%s %s\n", colorYellow, colorReset, msg)
}

// Error prints an error message.
func Error(msg string) {
	fmt.Printf("%s[-]%s %s\n", colorRed, colorReset, msg)
}
