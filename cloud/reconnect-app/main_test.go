package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"strings"
	"testing"
	"time"
)

func enc(v any) string {
	b, _ := json.Marshal(v)
	return codePrefix + base64.RawURLEncoding.EncodeToString(b)
}

func TestParseCode(t *testing.T) {
	good := enc(map[string]string{"u": "https://om-mike.example.workers.dev/", "t": "abc.def"})
	c, err := parseCode("  " + good + "\n")
	if err != nil || c.URL != "https://om-mike.example.workers.dev" || c.Token != "abc.def" {
		t.Fatalf("got %+v, %v", c, err)
	}
	for name, in := range map[string]string{
		"empty":     "",
		"no prefix": "hello",
		"garbage":   codePrefix + "!!!",
		"no token":  enc(map[string]string{"u": "https://x.dev"}),
		"http":      enc(map[string]string{"u": "http://x.dev", "t": "a"}),
		"userinfo":  enc(map[string]string{"u": "https://me@x.dev", "t": "a"}),
		"file":      enc(map[string]string{"u": "file:///etc/passwd", "t": "a"}),
	} {
		if _, err := parseCode(in); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestHasRequired(t *testing.T) {
	m := map[string]string{"SID": "a", "SAPISID": "b", "__Secure-1PSID": "c"}
	if hasRequired(m) {
		t.Fatal("accepted without __Secure-1PSIDTS")
	}
	m["__Secure-1PSIDTS"] = "d"
	if !hasRequired(m) {
		t.Fatal("refused a full set")
	}
}

func TestResultPageEscapes(t *testing.T) {
	p := resultPage(false, "<script>x</script>")
	b, _ := base64.StdEncoding.DecodeString(strings.TrimPrefix(p, "data:text/html;charset=utf-8;base64,"))
	if strings.Contains(string(b), "<script>") {
		t.Fatal("not escaped")
	}
}

func TestUploadSendsTokenAndCookies(t *testing.T) {
	var gotAuth string
	var gotBody map[string]map[string]string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		if r.URL.Path != "/reconnect/upload" {
			t.Errorf("path %s", r.URL.Path)
		}
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.WriteHeader(http.StatusAccepted)
	}))
	defer srv.Close()
	if err := upload(context.Background(), code{URL: srv.URL, Token: "tok"}, map[string]string{"SID": "a"}); err != nil {
		t.Fatal(err)
	}
	if gotAuth != "Bearer tok" || gotBody["cookies"]["SID"] != "a" {
		t.Fatalf("auth %q body %v", gotAuth, gotBody)
	}
}

func TestUploadReportsServerErrorAndRefusesRedirect(t *testing.T) {
	hits := 0
	elsewhere := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { hits++ }))
	defer elsewhere.Close()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.Header.Get("Authorization"), "redirect") {
			http.Redirect(w, r, elsewhere.URL, http.StatusTemporaryRedirect)
			return
		}
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte(`{"error":"already tried 3 times today"}`))
	}))
	defer srv.Close()
	err := upload(context.Background(), code{URL: srv.URL, Token: "x"}, map[string]string{"SID": "a"})
	if err == nil || !strings.Contains(err.Error(), "3 times") {
		t.Fatalf("got %v", err)
	}
	if err := upload(context.Background(), code{URL: srv.URL, Token: "redirect"}, map[string]string{"SID": "a"}); err == nil {
		t.Fatal("a redirect counted as success")
	}
	if hits != 0 {
		t.Fatal("followed a redirect with the login")
	}
}

// Real Chrome, headless, no network or sign-in: the DevTools path the app uses.
func TestChromeDevToolsPath(t *testing.T) {
	chrome, err := findChrome()
	if err != nil {
		t.Skip(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	profile := t.TempDir()
	cmd := exec.Command(chrome, "--headless=new", "--user-data-dir="+profile, "--remote-debugging-port=0",
		"--remote-debugging-address=127.0.0.1", "--incognito", "--no-first-run", "--no-default-browser-check", "about:blank")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	exited := make(chan error, 1)
	go func() { exited <- cmd.Wait() }()
	defer func() {
		_ = cmd.Process.Kill()
		<-exited
	}()
	port, err := waitForPort(ctx, profile, exited)
	if err != nil {
		t.Fatal(err)
	}
	d := devtools{port}
	var page tab
	for i := 0; i < 50 && page.WS == ""; i++ {
		ts, _ := d.tabs(ctx)
		for _, x := range ts {
			if x.Type == "page" {
				page = x
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	if page.WS == "" {
		t.Fatal("no page target")
	}
	for _, n := range required {
		err := call(ctx, page.WS, "Network.setCookie", map[string]any{"name": n, "value": "v-" + n, "url": target, "secure": true}, nil)
		if err != nil {
			t.Fatalf("set %s: %v", n, err)
		}
	}
	m, err := cookies(ctx, page)
	if err != nil {
		t.Fatal(err)
	}
	if !hasRequired(m) || m["SID"] != "v-SID" {
		t.Fatalf("cookies: %d found, required present: %v", len(m), hasRequired(m))
	}
	if err := call(ctx, page.WS, "Page.navigate", map[string]any{"url": resultPage(true, "done")}, nil); err != nil {
		t.Fatalf("result page: %v", err)
	}
}
