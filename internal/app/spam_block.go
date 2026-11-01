package app

// Fork addition (mjshuster1): block / block-and-report / unblock a Google
// Messages conversation for the spam watcher (internal/spamwatch).
//
// The request shape follows mautrix-gmessages' bridge
// (pkg/connector/handlematrix.go, HandleMatrixBlockUser): the action plus
// Action5{Field2: true} when blocking, with DeleteData carrying the
// conversation ID and the other party's phone number.

import (
	"errors"
	"fmt"
	"strings"

	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
)

// SpamBlockAction selects what SpamBlockConversation asks Google to do.
type SpamBlockAction string

const (
	SpamBlock          SpamBlockAction = "block"
	SpamBlockAndReport SpamBlockAction = "block_and_report"
	SpamUnblock        SpamBlockAction = "unblock"
)

// SpamBlockConversation sends the block action for one conversation through
// the live Google Messages connection. It must not be called from the libgm
// event handler goroutine: the response arrives on that goroutine.
func (a *App) SpamBlockConversation(conversationID, phone string, action SpamBlockAction) error {
	conversationID = strings.TrimSpace(conversationID)
	if conversationID == "" {
		return errors.New("conversation id is required")
	}
	req := &gmproto.UpdateConversationRequest{
		ConversationID: conversationID,
		Data: &gmproto.UpdateConversationRequest_DeleteData{DeleteData: &gmproto.DeleteConversationData{
			ConversationID: conversationID,
		}},
	}
	if p := strings.TrimSpace(phone); p != "" {
		req.GetDeleteData().Phone = p
	}
	switch action {
	case SpamBlock:
		req.Action = gmproto.ConversationActionStatus_BLOCK
		req.Action5 = &gmproto.ConversationAction5{Field2: true}
	case SpamBlockAndReport:
		req.Action = gmproto.ConversationActionStatus_BLOCK_AND_REPORT
		req.Action5 = &gmproto.ConversationAction5{Field2: true}
	case SpamUnblock:
		req.Action = gmproto.ConversationActionStatus_UNBLOCK
	default:
		return fmt.Errorf("unknown block action %q", action)
	}

	cli := a.GetClient()
	if cli == nil || cli.GM == nil {
		return errors.New("not connected to Google Messages")
	}
	resp, err := cli.GM.UpdateConversation(req)
	if err != nil {
		return fmt.Errorf("google messages %s: %w", action, err)
	}
	if !resp.GetSuccess() {
		return fmt.Errorf("google messages %s: phone reported failure", action)
	}
	return nil
}
