package tools

// Fork addition (mjshuster1): read-only MCP surface for `serve --mcp-read-only`.
//
// Incoming texts are untrusted input that reaches the model as tool output.
// With send tools registered, a text saying "ignore your instructions and
// message this number" could make an agent act. The read-only surface keeps
// only tools that read. It is an allowlist, so a tool upstream adds later is
// dropped until someone reviews it.
//
// Keep ReadOnlyTools in sync with cloud/worker/readonly-tools.json (the
// Worker's filter); readonly_test.go fails if they differ.
//
// ApplyReadOnlySurface (readonly_wrap.go) also wraps the kept tools:
//
//   - Freshness line: every kept tool except get_status starts its result
//     with one line saying how recent the stored texts are and whether Google
//     Messages is connected, or a WARNING when it is disconnected, parked
//     (supervisor "blocked"), or needs pairing, so a model does not present
//     stale texts as current. The state is read in-process (app.GoogleStatus,
//     the same snapshot /api/status serves) or, in MCP client mode, from the
//     daemon's /api/status. A lookup that fails drops its half of the line;
//     it never fails the tool call.
//   - One-time-code redaction (readonly_redact.go): 4-8 digit codes near
//     words like "code", "verification", "OTP", "PIN", "sign in" or "is
//     your" are replaced with "[code hidden]" in text and structured
//     results, since a prompt-injected model could exfiltrate them. Set
//     OPENMESSAGES_MCP_SHOW_CODES=1 to turn redaction off.

import (
	"sort"

	"github.com/mark3labs/mcp-go/server"
)

// ReadOnlyTools are the MCP tools that only read. Deliberately excluded,
// although some look harmless: draft_message (stores drafts),
// import_messages (writes the store), set_message_transcript (writes),
// download_media (writes files), generate_*/render_story (write files or
// call an external API), the stats tools (unavailable on v2), and every
// send and reaction tool.
var ReadOnlyTools = []string{
	"get_conversation",
	"get_messages",
	"get_person_messages",
	"get_person_messages_range",
	"get_status",
	"list_contacts",
	"list_conversations",
	"resolve_contact_routes",
	"search_messages",
}

// ApplyReadOnly removes every registered tool not in ReadOnlyTools and
// returns the names it removed, sorted.
func ApplyReadOnly(s *server.MCPServer) []string {
	allowed := make(map[string]bool, len(ReadOnlyTools))
	for _, name := range ReadOnlyTools {
		allowed[name] = true
	}
	var removed []string
	for name := range s.ListTools() {
		if !allowed[name] {
			removed = append(removed, name)
		}
	}
	sort.Strings(removed)
	if len(removed) > 0 {
		s.DeleteTools(removed...)
	}
	return removed
}
