# Setting up a client from their own browser

The client does this on their own computer while you talk them through it, on
a call or with screen sharing. You never hold a sign-in, so there's nothing to
remove at the end. Send them [`CLIENT-PREP.md`](CLIENT-PREP.md) first.

## What to send them on the day

Replace the address with yours, so you get status emails and their status link.
It stays out of this public repository.

> 1. Open https://shell.cloud.google.com/?show=terminal and sign in with your
>    Google account. If it asks to authorize, click Authorize.
> 2. Paste this line and press Return:
>
>    `git -C openmessage pull -q 2>/dev/null || git clone -q --depth 1 https://github.com/mjshuster1/openmessage; openmessage/cloud/setup.sh --helper-email you@example.com`

## What happens (about 30 minutes)

1. It checks their Google billing and asks their first name and time zone.
2. They approve Cloudflare with a link and a code.
3. The server gets built, about 5 minutes, with no clicks.
4. They do the Google sign-in step, about 5 minutes, from three direct links
   printed on screen.
5. They open their Reconnect page, get the Reconnect app, sign in to Google in
   the window it opens, close that window once Google Messages shows, and tap
   the emoji on their phone. Windows may block the app at first; the page says
   how to allow it.
6. They add the connector in claude.ai and ask for their last three texts.
7. It emails both of you their links and shows them the access report.

If anything stops, they fix what it says and paste the same line again. That
includes pressing Ctrl+C by accident, which cancels in that window instead of
copying.
Finished steps are skipped. Cloud Shell closes after about 40 idle minutes;
reopen it and paste the line again.

## Afterwards

Their setup email includes a status link. The email can occasionally be
dropped, so have them copy the links off the screen too. Give the link to Claude Code to add them to
your list of clients:

```bash
cloud/doctor.sh --add-client <first-name> --status-url '<the status link>'
```

The later checks use that link, and it only shows whether they're connected
and how old their newest text is.

Setup also turns on nightly backups (kept 7 days) and an email to both of you
if the server stops answering for about 20 minutes.

## To help later

Most problems they can fix from their Reconnect page: reconnect, restart, or go
back a version. For anything else, they share their screen with you.

**Updates.** The server updates itself, a few days after you publish a release,
so your own server gets it first. The connector doesn't. To refresh it, send
them the same paste line with `--update` on the end. It keeps its address,
sign-in and links, and asks them to approve Cloudflare once.

**Removal.** The same line with `--remove` deletes everything, after they type
their name. Both find the setup from their accounts, so they work even after
Cloud Shell has cleared its files, which happens after 120 unused days. Running
the line without either, once a setup exists, changes nothing and says so.
