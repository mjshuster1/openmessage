package cmd

import (
	"flag"
	"fmt"
	"net/http"
	"strings"
	"time"
	"unicode"

	"github.com/maxghenis/openmessage/internal/spamwatch"
)

// RunSpamScan checks stored history against the spam rules through the
// running app and lists matching threads. With --block it block-and-reports
// up to --max of them, one at a time, pausing between each.
func RunSpamScan(args []string) error {
	fs := flag.NewFlagSet("spam-scan", flag.ContinueOnError)
	days := fs.Int("days", 30, "how many days of history to check")
	block := fs.Bool("block", false, "block and report the blockable threads listed")
	max := fs.Int("max", 25, "most threads to block in one run")
	delay := fs.Duration("delay", 3*time.Second, "pause between blocks")
	noReport := fs.Bool("no-report", false, "block without reporting as spam")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 0 {
		return fmt.Errorf("usage: openmessage spam-scan [--days N] [--block] [--max N] [--delay 3s] [--no-report]")
	}
	if *days < 1 || *days > spamwatch.MaxScanDays {
		return fmt.Errorf("--days must be between 1 and %d", spamwatch.MaxScanDays)
	}
	if *max < 1 || *max > 200 {
		return fmt.Errorf("--max must be between 1 and 200")
	}
	if *delay < time.Second {
		return fmt.Errorf("--delay must be at least 1s")
	}

	var resp spamwatch.ScanResponse
	status, err := postSpamAPI(spamwatch.ScanPath, spamwatch.ScanRequest{Days: *days}, &resp, 5*time.Minute)
	if err != nil {
		if status == http.StatusNotFound {
			return fmt.Errorf("the running app has no spam-scan endpoint; restart it with the new build")
		}
		return err
	}
	if !resp.OK {
		return fmt.Errorf("scan failed: %s", resp.Error)
	}

	var todo []spamwatch.ScanCandidate
	fmt.Printf("Checked %d threads with activity in the last %d days. %d matched.\n\n", resp.Scanned, *days, len(resp.Candidates))
	for _, c := range resp.Candidates {
		state := "will block"
		switch {
		case c.AlreadyBlocked:
			state = "already blocked"
		case !c.Blockable:
			state = "skip: " + c.Skip
		default:
			todo = append(todo, c)
		}
		when := time.UnixMilli(c.LastMatchMS).Local().Format("Jan 2 3:04 PM")
		fmt.Printf("%-6s  %-14s  %-16s  %s\n", c.ConversationID, when, c.SenderNumber, state)
		fmt.Printf("        %d msg, %s\n", c.Matches, strings.Join(c.Matched, ", "))
		fmt.Printf("        %s\n\n", oneLine(c.Snippet, 100))
	}
	fmt.Printf("%d can be blocked now.\n", len(todo))
	if !*block {
		if len(todo) > 0 {
			fmt.Println("Nothing was changed. Read the list; if it is all spam, run again with --block.")
		}
		return nil
	}

	action := spamwatch.ActionBlockAndReport
	if *noReport {
		action = spamwatch.ActionBlock
	}
	if len(todo) > *max {
		todo = todo[:*max]
	}
	ok, failed := 0, 0
	for i, c := range todo {
		if i > 0 {
			time.Sleep(*delay)
		}
		if err := spamBlockOne(c.ConversationID, action); err != nil {
			failed++
			fmt.Printf("FAILED  %s  %s: %v\n", c.ConversationID, c.SenderNumber, err)
			continue
		}
		ok++
		fmt.Printf("blocked %s  %s\n", c.ConversationID, c.SenderNumber)
	}
	fmt.Printf("\nBlocked %d, failed %d. Check the phone's Spam & blocked list.\n", ok, failed)
	return nil
}

// oneLine strips control characters (message text is untrusted) and trims.
func oneLine(s string, n int) string {
	s = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == '\t' {
			return ' '
		}
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, s)
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > n {
		s = string(r[:n]) + "..."
	}
	return s
}
