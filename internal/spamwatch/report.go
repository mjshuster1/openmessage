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
	if len(entries) == 0 {
		fmt.Fprintf(w, "No would-block texts since %s.\n", since.Local().Format("Mon Jan 2 3:04 PM"))
		return
	}
	numbers := map[string]bool{}
	for _, e := range entries {
		numbers[NumberKey(e.SenderNumber)] = true
	}
	fmt.Fprintf(w, "%d would-block texts from %d numbers since %s (log only, nothing was blocked).\n\n",
		len(entries), len(numbers), since.Local().Format("Mon Jan 2 3:04 PM"))
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
		fmt.Fprintf(w, "  matched: %s\n", clean(strings.Join(e.Matched, ", ")))
		fmt.Fprintf(w, "  text: %s\n\n", clean(e.Snippet))
	}
}

func clean(s string) string {
	return strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) {
			return -1
		}
		return r
	}, s)
}
