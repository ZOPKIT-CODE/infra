# bug-resolution MCP server

A six-tool MCP server so Claude Code (or Cursor, or any other MCP client)
can work a Zopkit bug report end to end as native tool calls — plus report
usage status — instead of hand-rolling curl commands:

- **`fetch_bug_context`** — pulls the full report (title, description,
  severity, status, page URL, browser info, discussion comments) plus every
  inline screenshot as real image content, via
  `GET /api/admin/bug-reports/context/:id`. Calling it IS starting work on
  the ticket: `open`/`failed_testing` auto-moves to `in_progress` as a side
  effect (anything further along is left untouched).
- **`submit_bug_resolution`** — writes back how it was fixed as a Markdown
  writeup and moves the report to `needs_testing` (not `resolved` — a human
  still verifies the fix first), via
  `POST /api/admin/bug-reports/resolution/:id`.
- **`fetch_assigned_bugs`** — lists reports currently assigned to the API
  key's owner ("what's on my plate"), defaulting to everything but
  `resolved` and sorted by what needs attention soonest, optionally filtered
  to specific statuses and paginated, via
  `GET /api/admin/bug-reports/assigned`.
- **`create_bug_report`** — files a new bug report (plain-text description),
  optionally self-assigning it, via `POST /api/admin/bug-reports/report`.
- **`report_claude_usage`** — self-reports this developer's current Claude
  Code usage percentage (there's no API to fetch it on your behalf — see
  `backend/src/features/claude-usage/README.md`), shown on the
  company-admin panel's "Claude Usage" tab, via `POST /api/admin/claude-usage`.
- **`report_claude_token_usage`** — unlike the one above, this one is NOT
  self-attested: it scans this developer's own local Claude Code transcripts
  (`~/.claude/projects/**/*.jsonl` AND their nested `.../subagents/*.jsonl` —
  same machine the MCP server runs on, no `/usage`, no status line, no
  asking a human) for a configurable window (`days`, default 7), streamed
  line-by-line and cached per-file so repeat calls in one session are
  near-instant. Dedupes streamed duplicates by `message.id` and reports real
  input/output/cache-creation/cache-read token totals (subagent spend folded
  in, not just detected), a per-model split, how full the most recently
  active session's context window currently is, session count, and whether
  any sessions used web search or spawned subagents — via
  `POST /api/admin/claude-usage/token-breakdown`. Also runs automatically,
  genuinely non-blocking (never awaited), as a side effect of the four
  bug-report tools above (`submit_bug_resolution`, `fetch_bug_context`,
  `fetch_assigned_bugs`, `create_bug_report`) on success — so a developer
  who never touches this tool directly still gets a token breakdown
  reported just by doing normal bug-report work, with zero added latency on
  those calls. Failures from the auto-report path are swallowed entirely;
  they never surface as a tool error, and (since it isn't awaited) never
  delay the real response either.

All six are thin wrappers — see `backend/src/features/bug-reports/README.md`
and `backend/src/features/claude-usage/README.md` for what each endpoint
actually does server-side.

Published to npm as
[`zopkit-bug-resolution-mcp`](https://www.npmjs.com/package/zopkit-bug-resolution-mcp)
— employees don't need this repo at all, just `npx` and a key.

## Setup

1. **Get a key.** In the company-admin panel → Bug Reports → **API Keys**
   (any platform staff with `bug-reports` or `bug-reports-own` access can
   generate their own), generate one and copy it — it's shown exactly once.
   The key's reach (every report, or only reports you created/are assigned
   to) always tracks your *current* staff role — it's resolved live on every
   call, not fixed at generation time.

2. **Register the server** — either via the CLI:

   ```bash
   claude mcp add bug-resolution \
     --env BUG_REPORT_API_KEY=<the key you copied> \
     -- npx -y zopkit-bug-resolution-mcp
   ```

   or by adding this to your MCP config JSON (Claude Desktop's
   `claude_desktop_config.json`, or Claude Code's own MCP settings):

   ```json
   {
     "mcpServers": {
       "bug-resolution": {
         "command": "npx",
         "args": ["-y", "zopkit-bug-resolution-mcp"],
         "env": {
           "BUG_REPORT_API_KEY": "<the key you copied>"
         }
       }
     }
   }
   ```

   By default it talks to production (`https://api.zopkit.com`). Point it
   elsewhere (e.g. a local dev backend) with an extra env var,
   `BUG_REPORT_API_BASE_URL=http://localhost:3000`.

   **On Windows**, a bare `npx` command as shown above commonly fails or
   hangs (MCP client "connection timed out after 30000ms") — Windows needs
   `npx.cmd` resolved through `cmd.exe`, not the bare `npx` name spawn()
   looks for on macOS/Linux. Route it through `cmd /c` instead:

   ```bash
   claude mcp add bug-resolution \
     --env BUG_REPORT_API_KEY=<the key you copied> \
     -- cmd /c npx -y zopkit-bug-resolution-mcp
   ```

   or in the JSON config, `"command": "cmd", "args": ["/c", "npx", "-y", "zopkit-bug-resolution-mcp"]`.

3. Restart Claude Code (or Claude Desktop) and approve `bug-resolution` when
   prompted.

<details>
<summary>Running from a local checkout instead (this repo, not npm)</summary>

```bash
cd deploy/mcp/bug-resolution
npm install
claude mcp add bug-resolution \
  --env BUG_REPORT_API_KEY=<the key you copied> \
  -- node "$(pwd)/index.js"
```

Useful if you're changing `index.js` itself — the npm package is what
everyone else should use.
</details>

## Usage

Once registered, give Claude Code (or whichever tool) the bug report's id (a
UUID — copy it from the ID chip in the report's detail panel, or from
whoever asked you to fix it).

1. Ask it to call `fetch_bug_context` with that id first — you'll get the
   title, description, severity/status, discussion, and every screenshot
   actually rendered as images, so the tool can see the bug instead of just
   reading a URL to it. This call also moves the board card to `In
   Progress` if it was sitting at `Open`/`Failed Testing` — the board
   reflects that work has started without anyone dragging the card by hand.
2. After fixing it, ask it to call `submit_bug_resolution` with the same id
   and a Markdown writeup. It sets the report's resolution notes to that
   writeup and moves its status to `needs_testing` — a human still needs to
   verify it before it's `resolved`.

Four more, independent of the fetch/resolve flow above:

- Ask it to call `fetch_assigned_bugs` to see what's currently assigned to
  you — no id needed. By default it shows everything except `resolved`,
  ranked by what needs your attention soonest (a fix QA bounced back first,
  then active work, then fixes just waiting on QA). Pass
  `status: ['failed_testing']` etc. to narrow it down, or `status: ['all']`
  to include resolved history; `limit`/`offset` page past the first batch
  if it says there's more.
- Ask it to call `create_bug_report` with a `title` and plain-text
  `description` to file something it noticed — pass `assignToSelf: true` to
  claim it immediately.
- Ask it to call `report_claude_usage` with your current usage `%` (from
  `/usage`, the status line, or the account's billing page — there's no way
  for the tool to look this up itself) to update the "Claude Usage" tab in
  the company-admin panel. Pass an optional `note` for context (e.g. "Team
  plan, resets Monday"), and an optional `resetsAt` (ISO timestamp) whenever
  you can see a concrete reset time (e.g. in the status line's rate-limit
  JSON) — this is what lets the panel show real staleness instead of a
  human having to parse a reset time out of free-text `note`.
- Ask it to call `report_claude_token_usage` (optionally with `days: N` to
  scan a window other than the default 7) to push a real token/model/context
  breakdown up to the same "Claude Usage" tab — distinct from and
  independent of `report_claude_usage` above. You usually don't need to call
  this directly: it already fires automatically after every successful
  `fetch_bug_context`, `submit_bug_resolution`, `fetch_assigned_bugs`, or
  `create_bug_report` call, genuinely in the background (it's never awaited,
  so it adds no latency and its own response text never shows up in that
  tool's reply) — this standalone call is for an explicit, on-demand check
  with a full summary (tokens by model, current context occupancy, subagent
  share) in the response.

## Notes

- Not part of the pnpm workspace (`pnpm-workspace.yaml`) or the deployed
  backend image, and published separately from this repo's release process
  (`npm publish` from this directory, manually, when `index.js` changes).
- No secrets in the package itself — the API key is supplied per-installation
  via the `BUG_REPORT_API_KEY` env var, never embedded.
- The key is per-developer and individually revocable from the same API Keys
  panel — revoking one never affects any other person's key.
- `fetch_bug_context` and `submit_bug_resolution` still need a report id —
  this server doesn't search or browse. `fetch_assigned_bugs` is the one tool
  that doesn't require knowing an id up front.
- `report_claude_token_usage`'s breakdown only ever sends the BASENAME of a
  session's working directory (e.g. `isocode`, not `/Users/you/Downloads/
  isocode`) to the company-admin panel — real project names, no full
  filesystem paths or usernames, even though the local scan reads the full
  path off the transcript.

---

## Usage reporting (v1.8.0)

Three reporters ship alongside the MCP server. They are plain commands
Claude Code spawns — a status line and two hooks — not MCP tools, because
what they report has to be captured at moments no tool call happens at.

```bash
npx zopkit-bug-resolution-mcp --init-usage-reporting --api-key bugres_…
# then restart Claude Code
```

That writes `~/.claude/.zopkit-usage.json` (mode 0600 — it holds your API
key) and adds a `statusLine` plus two hooks to `~/.claude/settings.json`.
It backs the file up first, never overwrites an existing `statusLine`, and
is idempotent.

### What each one does

| | fires | reports |
|---|---|---|
| `bin/zopkit-statusline.js` | every assistant message (300ms debounce), `/compact`, session start/resume, rate-limit reset | per-session context occupancy, the account's 5h/7d limit percentages, session cost |
| `bin/zopkit-task-marker.js` | `PostToolUse` on `fetch_bug_context` / `submit_bug_resolution` | the session's cumulative tokens at each end of a task window |
| `bin/zopkit-session-end.js` | `SessionEnd` | that the session is over |

The status line is the interesting one. Claude Code hands it a JSON payload
containing `rate_limits.seven_day.used_percentage` — the number `/usage`
shows, which nothing server-side can fetch on your behalf. A status-line
script isn't a third party; it runs inside your own session. So that figure
no longer has to be typed in by a human (`report_claude_usage`, now legacy).

Two rules the status-line script follows, both load-bearing:

1. **It renders before it touches the network.** Claude Code cancels an
   in-flight status-line script when the next update arrives, so a slow
   fetch ahead of the first write would blank the bar.
2. **It whitelists fields, never forwards the payload.** The payload
   carries more than this feature needs. `session_name` — your session's
   AI-generated title, i.e. a description of what you're working on — is
   sent **only** with `--share-session-name`, because it lands on a panel
   every staff member with the `claude-usage` section can read.

### Checking your Claude Code is new enough

These fields arrived across several releases, so "is my client new enough"
has a different answer per field:

```bash
# capture one payload
cd /tmp && claude --settings '{"statusLine":{"type":"command","command":"tee /tmp/sl.json"}}'
# …let it render once, exit, then:
npx zopkit-bug-resolution-mcp --check-statusline < /tmp/sl.json
```

It prints which fields are present and what goes empty without each.

### Backfilling past bugs

The task markers are already in every transcript you've ever written, so
bugs you fixed before installing the hook can be attributed retroactively:

```bash
npx zopkit-bug-resolution-mcp --backfill-tasks --dry-run
npx zopkit-bug-resolution-mcp --backfill-tasks
```

Reconstruction is weaker than live markers and tags every window it writes
`backfill`, which the panel renders differently. Known imprecisions: a
window includes anything else you did inside it; an un-submitted window is
closed at the first 30-minute gap (without that, one ran 738 minutes and
swallowed its whole session); and only transcripts on this machine exist.

### Turning it off

Delete `~/.claude/.zopkit-usage.json` — every reporter no-ops without it —
or remove the `statusLine` / `hooks` entries from `~/.claude/settings.json`.
