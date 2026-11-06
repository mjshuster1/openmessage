// OpenMessage Reconnect: the client's half of "reconnect without the
// operator". No terminal and no typing: the client copies the reconnect code
// from their Reconnect page (https://<connector>/reconnect) and opens this
// app. It:
//
//  1. reads the code from the clipboard (omrc1.<base64url {"u": url, "t": token}>);
//  2. opens a throwaway Chrome (temporary profile) at Google sign-in,
//     continuing to Messages Web, with no DevTools attached: Google refuses
//     sign-in ("This browser or app may not be secure") in a Chrome started
//     with a debugging port (Windows, 2026-11-06). The client closes it once
//     Messages Web shows;
//  3. reopens that profile with DevTools on a random loopback port and reads
//     exactly the cookies Chrome would send to messages.google.com/web;
//  4. posts them to <url>/reconnect/upload with the token, which passes them
//     to the client's own server to pair (the Reconnect page shows the emoji);
//  5. shows the result in that window, closes Chrome without signing out,
//     deletes the profile and clears the code from the clipboard.
//
// Nothing is written to disk but Chrome's temporary profile, and the
// cookies go only to the URL in the code (https only). Messages to the
// client appear in the Chrome window, or in a system dialog when Chrome
// can't open. Same method as cloud/vm/capture-google-cookies.mjs, which
// explains why a fresh Incognito login is used.
package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/coder/websocket"
)

const (
	codePrefix  = "omrc1."
	target      = "https://messages.google.com/web/"
	signInLimit = 15 * time.Minute
	readLimit   = 60 * time.Second
)

var (
	startURL = "https://accounts.google.com/ServiceLogin?continue=" + url.QueryEscape(target)
	required = []string{"SID", "SAPISID", "__Secure-1PSID", "__Secure-1PSIDTS"}
)

type code struct {
	URL   string `json:"u"`
	Token string `json:"t"`
}

// parseCode finds and decodes a reconnect code in text (the clipboard).
func parseCode(text string) (code, error) {
	i := strings.Index(text, codePrefix)
	if i < 0 {
		return code{}, errors.New("no reconnect code on the clipboard")
	}
	raw := text[i+len(codePrefix):]
	if j := strings.IndexAny(raw, " \t\r\n\"'"); j >= 0 {
		raw = raw[:j]
	}
	b, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(raw, "="))
	if err != nil {
		return code{}, errors.New("the reconnect code is damaged")
	}
	var c code
	if json.Unmarshal(b, &c) != nil || c.Token == "" {
		return code{}, errors.New("the reconnect code is damaged")
	}
	u, err := url.Parse(c.URL)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil {
		return code{}, errors.New("the reconnect code points somewhere unexpected")
	}
	c.URL = strings.TrimRight(u.Scheme+"://"+u.Host+u.Path, "/")
	return c, nil
}

// hasRequired reports whether the cookies include every one pairing needs.
func hasRequired(m map[string]string) bool {
	for _, n := range required {
		if m[n] == "" {
			return false
		}
	}
	return true
}

func findChrome() (string, error) {
	if p := os.Getenv("CHROME"); p != "" {
		return p, nil
	}
	var cands []string
	switch runtime.GOOS {
	case "darwin":
		home, _ := os.UserHomeDir()
		cands = []string{
			"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
			filepath.Join(home, "Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
		}
	case "windows":
		for _, base := range []string{os.Getenv("PROGRAMFILES"), os.Getenv("PROGRAMFILES(X86)"), os.Getenv("LOCALAPPDATA")} {
			if base != "" {
				cands = append(cands, filepath.Join(base, "Google", "Chrome", "Application", "chrome.exe"))
			}
		}
	default:
		for _, n := range []string{"google-chrome", "google-chrome-stable", "chromium", "chromium-browser"} {
			if p, err := exec.LookPath(n); err == nil {
				cands = append(cands, p)
			}
		}
	}
	for _, c := range cands {
		if _, err := os.Stat(c); err == nil {
			return c, nil
		}
	}
	return "", errors.New("Google Chrome isn't installed on this computer. Install it from google.com/chrome, then try again")
}

// devtools talks to one Chrome over its loopback DevTools port.
type devtools struct{ port string }

type tab struct {
	Type string `json:"type"`
	URL  string `json:"url"`
	WS   string `json:"webSocketDebuggerUrl"`
	ID   string `json:"id"`
}

func (d devtools) tabs(ctx context.Context) ([]tab, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, "http://127.0.0.1:"+d.port+"/json/list", nil)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	var t []tab
	return t, json.NewDecoder(res.Body).Decode(&t)
}

// call sends one DevTools command over a fresh WebSocket and decodes its result.
func call(ctx context.Context, ws, method string, params any, out any) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, ws, nil)
	if err != nil {
		return err
	}
	defer c.CloseNow()
	c.SetReadLimit(8 << 20)
	msg, _ := json.Marshal(map[string]any{"id": 1, "method": method, "params": params})
	if err := c.Write(ctx, websocket.MessageText, msg); err != nil {
		return err
	}
	for {
		_, data, err := c.Read(ctx)
		if err != nil {
			return err
		}
		var r struct {
			ID     int             `json:"id"`
			Result json.RawMessage `json:"result"`
			Error  *struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(data, &r) != nil || r.ID != 1 {
			continue
		}
		if r.Error != nil {
			return errors.New(r.Error.Message)
		}
		if out != nil {
			return json.Unmarshal(r.Result, out)
		}
		return nil
	}
}

// cookies returns what Chrome would send to Messages Web, read through tab t.
func cookies(ctx context.Context, t tab) (map[string]string, error) {
	var res struct {
		Cookies []struct {
			Name  string `json:"name"`
			Value string `json:"value"`
		} `json:"cookies"`
	}
	if err := call(ctx, t.WS, "Network.getCookies", map[string]any{"urls": []string{target}}, &res); err != nil {
		return nil, err
	}
	m := make(map[string]string, len(res.Cookies))
	for _, c := range res.Cookies {
		m[c.Name] = c.Value
	}
	return m, nil
}

func waitForPort(ctx context.Context, profile string, exited <-chan error) (string, error) {
	file := filepath.Join(profile, "DevToolsActivePort")
	for i := 0; i < 150; i++ {
		select {
		case err := <-exited:
			return "", fmt.Errorf("Chrome closed before it was ready (%v)", err)
		case <-ctx.Done():
			return "", ctx.Err()
		case <-time.After(200 * time.Millisecond):
		}
		if b, err := os.ReadFile(file); err == nil {
			if p := strings.TrimSpace(strings.SplitN(string(b), "\n", 2)[0]); p != "" {
				return p, nil
			}
		}
	}
	return "", errors.New("Chrome didn't start properly; close every Chrome window and try again")
}

// upload sends the login to the client's connector. The reply is a short status.
func upload(ctx context.Context, c code, m map[string]string) error {
	body, _ := json.Marshal(map[string]any{"cookies": m})
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, c.URL+"/reconnect/upload", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+c.Token)
	client := &http.Client{
		Timeout: 60 * time.Second,
		// Never follow a redirect with the login in the body.
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	res, err := client.Do(req)
	if err != nil {
		return errors.New("couldn't reach your server. Check your internet connection and try again")
	}
	defer res.Body.Close()
	var r struct {
		Error string `json:"error"`
	}
	_ = json.NewDecoder(io.LimitReader(res.Body, 64<<10)).Decode(&r)
	if res.StatusCode >= 200 && res.StatusCode < 300 {
		return nil
	}
	if r.Error != "" {
		return errors.New(r.Error)
	}
	return fmt.Errorf("your server answered %d", res.StatusCode)
}

func resultPage(ok bool, msg string) string {
	color, mark := "#b42318", "✗"
	if ok {
		color, mark = "#1a7f37", "✓"
	}
	doc := `<!doctype html><meta charset="utf-8"><title>OpenMessage Reconnect</title>` +
		`<body style="font:20px/1.5 system-ui,sans-serif;max-width:32rem;margin:3rem auto;padding:0 16px">` +
		`<p style="font-size:1.5em;color:` + color + `">` + mark + ` ` + html.EscapeString(msg) + `</p>` +
		`<p style="color:#666">This window closes by itself in a few seconds.</p>`
	return "data:text/html;charset=utf-8;base64," + base64.StdEncoding.EncodeToString([]byte(doc))
}

// signInHelp is what the client sees before the sign-in window opens.
func signInHelp() string {
	done := "close the Chrome window"
	if runtime.GOOS == "darwin" {
		done = "quit that Chrome (Command-Q)"
	}
	return "A Chrome window opens next. Sign in to the Google account your Google Messages uses, and wait until Google Messages opens. Then " + done + ". Chrome reopens for a moment by itself to finish."
}

func run(ctx context.Context) (shown bool, err error) {
	clip, _ := readClipboard()
	c, err := parseCode(clip)
	if err != nil {
		return false, fmt.Errorf("%v. Open your Reconnect page, click \"Copy reconnect code\", then open this app again", err)
	}
	chrome, err := findChrome()
	if err != nil {
		return false, err
	}
	profile, err := os.MkdirTemp("", "om-reconnect-")
	if err != nil {
		return false, err
	}
	defer os.RemoveAll(profile)

	base := []string{"--user-data-dir=" + profile, "--no-first-run", "--no-default-browser-check", "--new-window"}

	// Sign-in: an ordinary Chrome, nothing attached.
	alert("OpenMessage Reconnect", signInHelp())
	signIn := exec.Command(chrome, append(append([]string{}, base...), startURL)...)
	if err := signIn.Start(); err != nil {
		return false, fmt.Errorf("couldn't open Chrome: %v", err)
	}
	signedIn := make(chan error, 1)
	go func() { signedIn <- signIn.Wait() }()
	select {
	case <-signedIn:
	case <-time.After(signInLimit):
		_ = signIn.Process.Kill()
		return false, errors.New("the sign-in took too long. Copy a new code from the Reconnect page and try again")
	}

	// Read the login: the same profile, briefly, with the port on.
	cmd := exec.Command(chrome, append(append([]string{}, base...),
		"--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1", target)...)
	if err := cmd.Start(); err != nil {
		return false, fmt.Errorf("couldn't open Chrome: %v", err)
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	port, err := waitForPort(ctx, profile, exited)
	if err != nil {
		_ = cmd.Process.Kill()
		return false, err
	}
	d := devtools{port}
	closeChrome := func() {
		var v struct {
			WS string `json:"webSocketDebuggerUrl"`
		}
		req, _ := http.NewRequest(http.MethodGet, "http://127.0.0.1:"+port+"/json/version", nil)
		if res, err := http.DefaultClient.Do(req); err == nil {
			_ = json.NewDecoder(res.Body).Decode(&v)
			res.Body.Close()
			if v.WS != "" {
				_ = call(context.Background(), v.WS, "Browser.close", map[string]any{}, nil)
			}
		}
		select {
		case <-exited:
		case <-time.After(5 * time.Second):
			_ = cmd.Process.Kill()
		}
	}
	show := func(t tab, ok bool, msg string) {
		_ = call(ctx, t.WS, "Page.navigate", map[string]any{"url": resultPage(ok, msg)}, nil)
		time.Sleep(8 * time.Second)
	}

	deadline := time.Now().Add(readLimit)
	var page tab
	var m map[string]string
	for {
		select {
		case <-exited:
			return false, errors.New("the Chrome window was closed too early. Open this app again to retry")
		case <-time.After(2 * time.Second):
		}
		if time.Now().After(deadline) {
			closeChrome()
			return false, errors.New("the sign-in didn't finish. Copy a new code from the Reconnect page, open this app again, and sign in until Google Messages shows before closing Chrome")
		}
		ts, err := d.tabs(ctx)
		if err != nil {
			continue
		}
		for _, t := range ts {
			if t.Type == "page" && strings.HasPrefix(t.URL, "https://messages.google.com/") {
				if got, err := cookies(ctx, t); err == nil && hasRequired(got) {
					page, m = t, got
				}
				break
			}
		}
		if m != nil {
			break
		}
	}

	err = upload(ctx, c, m)
	clear(m)
	if err != nil {
		show(page, false, "Didn't work: "+err.Error())
		closeChrome()
		return true, err
	}
	clearClipboard(clip)
	show(page, true, "Signed in. Now go back to your Reconnect page and tap the emoji it shows on your phone.")
	closeChrome()
	return true, nil
}

func main() {
	ctx := context.Background()
	shown, err := run(ctx)
	if err != nil {
		if !shown {
			alert("OpenMessage Reconnect", err.Error())
		}
		os.Exit(1)
	}
}
