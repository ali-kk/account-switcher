# Claude Accounts

A menu bar app for this Mac that keeps several Claude Code logins and switches between them.

- Lists every Claude account you have signed in to, with plan (Pro, Max 5x, Max 20x, …), subscription
  status, organisation, extra usage, and the 5-hour and weekly usage with reset times. The menu bar
  shows the active account's 5-hour usage.
- **Switch** points Claude Code at another account. New sessions use it at once; running sessions pick it
  up within about 30 seconds (they re-read the login from the keychain).
- **Add Account…** opens Terminal on `claude auth login`. The account you were on stays saved, and the new
  one appears in the list within 30 seconds.
- **Main account** (star): Claude Code uses it whenever it has usage left. When the active account hits
  a limit the app switches to the least-used account with room, and goes back to the main account as
  soon as its limit resets. (Settings → Switch automatically; 3-minute cooldown between switches.)
- **Keep sessions going** sets `autoContinueAtUsageLimit` and
  `CLAUDE_CODE_RETRY_WATCHDOG_USAGE_LIMIT_RECHECK_MS=60000` in `~/.claude/settings.json`. A session that
  hits a limit then waits instead of stopping and probes every minute; sessions re-read the login from
  the keychain every 30 s, so after a switch the next probe goes out on the new account and the turn
  carries on by itself. (Taken from Claude Code 2.1.317's code; Claude Code may change it.)
- **Resume at reset** (Settings, on by default; works with a single account): while the active account is
  limited the app remembers the running sessions (`~/.claude/sessions`). When the limit resets, sessions that
  exited meanwhile are reopened in Terminal with `claude --resume <id> "continue"`; sessions still running
  carry on by themselves via "Keep sessions going" (turned on with this setting).
- Notifications when the app switches, or when nothing has room left.
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


## Build, test, install

```sh
swift test                  # core logic tests (fake keychain and API)
"$HOME/Applications/Claude Accounts.app/Contents/MacOS/ClaudeAccountBar" --snapshot <dir>   # light.png/dark.png of the menu
scripts/build-app.sh        # build, sign ad hoc, install in ~/Applications and start
```

On this shared Mac run builds through `~/project/orbital-webapp/scripts/memguard.sh --run 2 -- …`.
