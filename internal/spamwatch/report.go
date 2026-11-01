package spamwatch

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"strings"
	"time"
	"unicode"
)

// ReadLog returns log entries whose time is at or after since. Malformed
// lines are skipped.
func ReadLog(path string, since time.Time) ([]Entry, error) {
	f, err := os.Open(path)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []Entry
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		var e Entry
		if json.Unmarshal(sc.Bytes(), &e) != nil {
			continue
		}
		t, err := time.Parse(time.RFC3339, e.Time)
		if err != nil || t.Before(since) {
			continue
		}
		out = append(out, e)
	}
	return out, sc.Err()
}

// WriteReport prints entries for a person to read in a terminal. Message
// text is untrusted, so control characters are stripped before printing.
func WriteReport(w io.Writer, entries []Entry, since time.Time) {
	sinceText := since.Local().Format("Mon Jan 2 3:04 PM")
	if len(entries) == 0 {
		fmt.Fprintf(w, "No spam-watch entries since %s.\n", sinceText)
		return
	}
	numbers := map[string]bool{}
	counts := map[string]int{}
	var order []string
	for _, e := range entries {
		numbers[NumberKey(e.SenderNumber)] = true
		a := actionOf(e)
		if counts[a] == 0 {
			order = append(order, a)
		}
		counts[a]++
	}
	var parts []string
	for _, a := range order {
		parts = append(parts, fmt.Sprintf("%d %s", counts[a], actionLabel(a)))
	}
	fmt.Fprintf(w, "Since %s: %s, from %d numbers.\n\n", sinceText, strings.Join(parts, ", "), len(numbers))
	for _, e := range entries {
		when := e.Time
		if t, err := time.Parse(time.RFC3339, e.Time); err == nil {
			when = t.Local().Format("Mon Jan 2 3:04 PM")
		}
		from := clean(e.SenderNumber)
		if name := clean(e.SenderName); name != "" && name != from {
			from += " (" + name + ")"
		}
		var tags []string
		if e.IsGroup {
			tags = append(tags, "group")
		}
		if e.ShortCode {
			tags = append(tags, "short code")
		}
		if e.ParticipantContID != "" {
			tags = append(tags, "has contact_id")
		}
		tagText := ""
		if len(tags) > 0 {
			tagText = " [" + strings.Join(tags, ", ") + "]"
		}
		fmt.Fprintf(w, "%s  %s%s\n", when, from, tagText)
		action := actionLabel(actionOf(e))
		if e.Note != "" {
			action += " (" + clean(e.Note) + ")"
		}
		fmt.Fprintf(w, "  what happened: %s\n", action)
		fmt.Fprintf(w, "  conversation: %s\n", clean(e.ConversationID))
		if len(e.Matched) > 0 {
			fmt.Fprintf(w, "  matched: %s\n", clean(strings.Join(e.Matched, ", ")))
		}
		if e.Snippet != "" {
			fmt.Fprintf(w, "  text: %s\n", clean(e.Snippet))
		}
		fmt.Fprintln(w)
	}
}

func actionOf(e Entry) string {
	if e.Action == "" {
		return "logged"
	}
	return e.Action
}

func actionLabel(action string) string {
	switch action {
	case "logged":
		return "logged only"
	case "blocked":
		return "auto-blocked"
	case "block_failed":
		return "auto-block failed"
	case "manual_block":
		return "blocked by hand"
	case "manual_block_failed":
		return "hand block failed"
	case "manual_unblock":
		return "unblocked by hand"
	case "manual_unblock_failed":
		return "hand unblock failed"
	}
	return clean(action)
}

func clean(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) {
			return -1
		}
		return r
	}, s)
}
