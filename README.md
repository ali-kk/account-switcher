# Claude Accounts

A menu bar app for this Mac that keeps several Claude Code logins and switches between them.

- Lists every Claude account you have signed in to, with plan (Pro, Max 5x, Max 20x, …), subscription
  status, organisation, extra usage, and the 5-hour and weekly usage with reset times. The menu bar
  shows the active account's 5-hour usage.
- **Switch** points Claude Code at another account. New `claude` sessions use it; open sessions keep the
  old one until restarted.
- **Add Account…** opens Terminal on `claude auth login`. The account you were on stays saved, and the new
  one appears in the list within 30 seconds.
- When the active account reaches a limit, a notification names the least-used account with room left and
  offers a **Switch** button. You choose; the app does not switch on its own.
- Opens at login (Login Items, via `SMAppService`); turn it off in the menu.

## How it works

Claude Code keeps its login in the keychain item `Claude Code-credentials` (`claudeAiOauth`, next to the
MCP server logins in `mcpOAuth`) and the account details in `oauthAccount` in `~/.claude.json`.

- Every 30 s the app reads that login and saves a copy, with any tokens Claude Code renewed, in its own
  keychain items (`ClaudeAccountBar`, one per account uuid). An unknown login is identified with
  `/api/oauth/profile`; if that fails it is not filed under a guess.
- A switch first saves the outgoing login, then replaces only `claudeAiOauth` (MCP logins untouched) and
  only `oauthAccount` in `~/.claude.json` (temp file + rename, mode 600). An expired saved login is renewed
  first; a dead one marks the account "Signed out" and leaves Claude Code as it was.
- Usage comes from `/api/oauth/usage`, the endpoint behind `/usage`, every 3 minutes and when the menu opens.
- The app never renews the active account's tokens itself: that would rotate the refresh token out from
  under running sessions. Saved, inactive logins are renewed when needed.
- Keychain access goes through `/usr/bin/security`, as Claude Code does it, so neither app gets keychain
  prompts and a rebuilt app keeps working. Account details (no tokens) are in
  `~/Library/Application Support/ClaudeAccountBar/accounts.json`.

Caveat: a session still running on account A after you switch to B renews A's tokens and may write them back
into Claude Code's keychain item, which flips Claude Code back to A. Restart open sessions after a switch.

## Build, test, install

```sh
swift test                  # core logic tests (fake keychain and API)
scripts/build-app.sh        # build, sign ad hoc, install in ~/Applications and start
```

On this shared Mac run builds through `~/project/orbital-webapp/scripts/memguard.sh --run 2 -- …`.
