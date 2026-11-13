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
  (`~/.claude/projects/**/*.jsonl`, same machine the MCP server runs on — no
  `/usage`, no status line, no asking a human) for the last 7 days, dedupes
  streamed duplicates by `message.id`, and reports real input/output/
  cache-creation/cache-read token totals, session count, and whether any
  sessions used web search or spawned subagents, via
  `POST /api/admin/claude-usage/token-breakdown`. Also runs automatically,
  fire-and-forget, as a side effect of the four bug-report tools above
  (`submit_bug_resolution`, `fetch_bug_context`, `fetch_assigned_bugs`,
  `create_bug_report`) on success — so a developer who never touches this
  tool directly still gets a token breakdown reported just by doing normal
  bug-report work. Failures from the auto-report path are swallowed
  entirely; they never surface as a tool error.

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
  plan, resets Monday").
- Ask it to call `report_claude_token_usage` (no input needed) to push a
  real token/session breakdown for the last 7 days up to the same "Claude
  Usage" tab — distinct from and independent of `report_claude_usage`
  above. You usually don't need to call this directly: it already fires
  automatically after every successful `fetch_bug_context`,
  `submit_bug_resolution`, `fetch_assigned_bugs`, or `create_bug_report`
  call, and a short note gets appended to that tool's own response telling
  you it happened (e.g. "Also updated your Claude token usage: 2.1M new
  tokens across 3 session(s) this week.").

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
