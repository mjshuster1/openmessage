package main

import (
	"os/exec"
	"runtime"
	"strings"
)

// readClipboard returns the clipboard's text.
func readClipboard() (string, error) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("pbpaste")
	case "windows":
		cmd = exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", "Get-Clipboard -Raw")
	default:
		if _, err := exec.LookPath("wl-paste"); err == nil {
			cmd = exec.Command("wl-paste", "--no-newline")
		} else {
			cmd = exec.Command("xclip", "-selection", "clipboard", "-o")
		}
	}
	hideWindow(cmd)
	out, err := cmd.Output()
	return string(out), err
}

// clearClipboard empties the clipboard if it still holds was (the code).
func clearClipboard(was string) {
	now, err := readClipboard()
	if err != nil || strings.TrimSpace(now) != strings.TrimSpace(was) {
		return
	}
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("pbcopy")
	case "windows":
		cmd = exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", "Set-Clipboard -Value $null")
	default:
		if _, err := exec.LookPath("wl-copy"); err == nil {
			cmd = exec.Command("wl-copy", "--clear")
		} else {
			cmd = exec.Command("xclip", "-selection", "clipboard", "-i")
		}
	}
	cmd.Stdin = strings.NewReader("")
	hideWindow(cmd)
	_ = cmd.Run()
}

// alert shows a message box (used when Chrome can't show one).
func alert(title, msg string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("osascript", "-e",
			`on run argv`, "-e", `display dialog (item 2 of argv) with title (item 1 of argv) buttons {"OK"} default button 1`, "-e", `end run`,
			title, msg)
	case "windows":
		ps := `Add-Type -AssemblyName PresentationFramework; [System.Windows.MessageBox]::Show($args[1], $args[0]) | Out-Null`
		cmd = exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", ps, title, msg)
	default:
		if _, err := exec.LookPath("zenity"); err == nil {
			cmd = exec.Command("zenity", "--info", "--title", title, "--text", msg)
		} else {
			println(title + ": " + msg)
			return
		}
	}
	hideWindow(cmd)
	_ = cmd.Run()
}
