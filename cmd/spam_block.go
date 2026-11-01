package cmd

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/maxghenis/openmessage/internal/app"
	"github.com/maxghenis/openmessage/internal/localapi"
	"github.com/maxghenis/openmessage/internal/spamwatch"
)

// RunSpamBlock asks the running app to block-and-report (default), block, or
// unblock one conversation. It goes through the app because the app owns the
// only Google Messages connection.
func RunSpamBlock(args []string) error {
	action := spamwatch.ActionBlockAndReport
	var positional []string
	for _, a := range args {
		switch a {
		case "--unblock":
			action = spamwatch.ActionUnblock
		case "--no-report":
			if action != spamwatch.ActionUnblock {
				action = spamwatch.ActionBlock
			}
		default:
			if strings.HasPrefix(a, "-") {
				return fmt.Errorf("unknown flag %s", a)
			}
			positional = append(positional, a)
		}
	}
	if len(positional) != 1 {
		return fmt.Errorf("usage: openmessage spam-block <conversation_id> [--no-report] [--unblock]")
	}

	token := localapi.LoadControlToken(app.DefaultDataDir())
	if token == "" {
		return fmt.Errorf("no control token found; is `openmessage serve` running with this data dir?")
	}
	body, _ := json.Marshal(spamwatch.BlockRequest{ConversationID: positional[0], Action: action})
	req, err := http.NewRequest(http.MethodPost, localapi.DefaultBaseURL()+spamwatch.BlockPath, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := (&http.Client{Timeout: 45 * time.Second}).Do(req)
	if err != nil {
		return fmt.Errorf("could not reach the running app (is `openmessage serve` running?): %w", err)
	}
	defer resp.Body.Close()
	var out spamwatch.BlockResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		if resp.StatusCode == http.StatusNotFound {
			return fmt.Errorf("the running app has no spam-block endpoint; restart it with the new build")
		}
		return fmt.Errorf("unexpected reply from app (HTTP %d)", resp.StatusCode)
	}
	if !out.OK {
		return fmt.Errorf("%s failed: %s", action, out.Error)
	}
	switch action {
	case spamwatch.ActionUnblock:
		fmt.Println("Unblocked. Check the phone to confirm.")
	case spamwatch.ActionBlock:
		fmt.Println("Blocked (not reported). Check the phone's Blocked list to confirm.")
	default:
		fmt.Println("Blocked and reported as spam. Check the phone's Spam & blocked list to confirm.")
	}
	return nil
}
