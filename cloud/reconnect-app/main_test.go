package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
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
