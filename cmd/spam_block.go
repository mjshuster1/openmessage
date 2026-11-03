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

	if err := spamBlockOne(positional[0], action); err != nil {
		return err
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

// spamBlockOne sends one block request to the running app.
func spamBlockOne(conversationID, action string) error {
	var out spamwatch.BlockResponse
	status, err := postSpamAPI(spamwatch.BlockPath, spamwatch.BlockRequest{ConversationID: conversationID, Action: action}, &out, 45*time.Second)
	if err != nil {
		if status == http.StatusNotFound {
			return fmt.Errorf("the running app has no spam-block endpoint; restart it with the new build")
		}
		return err
	}
	if !out.OK {
		return fmt.Errorf("%s failed: %s", action, out.Error)
	}
	return nil
}

// postSpamAPI posts JSON to a spam endpoint of the running app and decodes
// the reply. It returns the HTTP status (0 if the app was not reached).
func postSpamAPI(path string, in, out any, timeout time.Duration) (int, error) {
	token := localapi.LoadControlToken(app.DefaultDataDir())
	if token == "" {
		return 0, fmt.Errorf("no control token found; is `openmessage serve` running with this data dir?")
	}
	body, _ := json.Marshal(in)
	req, err := http.NewRequest(http.MethodPost, localapi.DefaultBaseURL()+path, bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := (&http.Client{Timeout: timeout}).Do(req)
	if err != nil {
		return 0, fmt.Errorf("could not reach the running app (is `openmessage serve` running?): %w", err)
	}
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(out); err != nil {
		return resp.StatusCode, fmt.Errorf("unexpected reply from app (HTTP %d)", resp.StatusCode)
	}
	return resp.StatusCode, nil
}
