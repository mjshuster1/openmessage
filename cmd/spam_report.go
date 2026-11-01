package cmd

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/maxghenis/openmessage/internal/app"
	"github.com/maxghenis/openmessage/internal/spamwatch"
)

// RunSpamReport prints the texts the spam watcher would have blocked.
func RunSpamReport(args []string) error {
	fs := flag.NewFlagSet("spam-report", flag.ContinueOnError)
	days := fs.Int("days", 1, "how many days back to show")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *days < 1 {
		return fmt.Errorf("--days must be at least 1")
	}
	since := time.Now().Add(-time.Duration(*days) * 24 * time.Hour)
	path := filepath.Join(app.DefaultDataDir(), spamwatch.LogFileName)
	entries, err := spamwatch.ReadLog(path, since)
	if err != nil {
		return err
	}
	spamwatch.WriteReport(os.Stdout, entries, since)
	return nil
}
