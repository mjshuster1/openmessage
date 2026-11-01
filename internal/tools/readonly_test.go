package tools

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/mark3labs/mcp-go/server"

	"github.com/maxghenis/openmessage/internal/localapi"
)

func registeredNames(s *server.MCPServer) []string {
	var names []string
	for name := range s.ListTools() {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func TestApplyReadOnlyKeepsExactlyTheAllowlist(t *testing.T) {
	shapes := map[string]Options{
		"daemon":     {},
		"mcp client": {Daemon: localapi.NewClient("http://127.0.0.1:1", "")},
		"v2 primary": {V2Primary: true},
	}
	for name, opts := range shapes {
		t.Run(name, func(t *testing.T) {
			a := testApp(t)
			s := server.NewMCPServer("test", "0")
			RegisterWithOptions(s, a, opts)
			before := registeredNames(s)

			removed := ApplyReadOnly(s)
			got := registeredNames(s)

			want := append([]string(nil), ReadOnlyTools...)
			sort.Strings(want)
			if strings.Join(got, ",") != strings.Join(want, ",") {
				// A mismatch means upstream renamed or dropped a read tool.
				t.Fatalf("after ApplyReadOnly:\n got  %v\n want %v", got, want)
			}
			if len(removed)+len(got) != len(before) {
				t.Fatalf("removed %d + kept %d != registered %d", len(removed), len(got), len(before))
			}
			for _, w := range []string{"send_message", "send_to_conversation", "send_group_message", "send_media_to_conversation", "react_to_message", "import_messages", "draft_message", "set_message_transcript", "download_media"} {
				if s.GetTool(w) != nil {
					t.Errorf("%s still registered", w)
				}
			}
		})
	}
}

func TestReadOnlyToolsHaveNoWriteLookingNames(t *testing.T) {
	for _, name := range ReadOnlyTools {
		for _, bad := range []string{"send", "react", "import", "draft", "download", "set_", "generate", "render", "delete", "block"} {
			if strings.Contains(name, bad) {
				t.Errorf("read-only tool %q contains %q", name, bad)
			}
		}
	}
}

func TestReadOnlyToolsMatchWorkerList(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "..", "cloud", "worker", "readonly-tools.json"))
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Tools []string `json:"tools"`
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	got := append([]string(nil), doc.Tools...)
	want := append([]string(nil), ReadOnlyTools...)
	sort.Strings(got)
	sort.Strings(want)
	if strings.Join(got, ",") != strings.Join(want, ",") {
		t.Fatalf("cloud/worker/readonly-tools.json %v != ReadOnlyTools %v", got, want)
	}
}
