# bug-resolution MCP server

A single-tool MCP server so Claude Code (or Cursor, or any other MCP client)
can report back how it fixed a Zopkit bug report as a native tool call,
instead of hand-rolling a curl command. It's a thin wrapper around
`POST /api/admin/bug-reports/resolution/:id` — see
`backend/src/features/bug-reports/README.md` for what that endpoint
actually does server-side.

Published to npm as
[`zopkit-bug-resolution-mcp`](https://www.npmjs.com/package/zopkit-bug-resolution-mcp)
— employees don't need this repo at all, just `npx` and a key.

## Setup

1. **Get a key.** In the company-admin panel → Bug Reports → **API Keys**
   (full `bug-reports` staff access only), generate one and copy it — it's
   shown exactly once.

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

Once registered, ask Claude Code (or whichever tool you fixed the bug with)
to call `submit_bug_resolution` with the bug report's id (a UUID — from
whoever asked you to fix it, or the report's admin-panel URL) and a Markdown
writeup. It sets the report's resolution notes to that writeup and moves its
status straight to `resolved`.

## Notes

- Not part of the pnpm workspace (`pnpm-workspace.yaml`) or the deployed
  backend image, and published separately from this repo's release process
  (`npm publish` from this directory, manually, when `index.js` changes).
- No secrets in the package itself — the API key is supplied per-installation
  via the `BUG_REPORT_API_KEY` env var, never embedded.
- The key is per-developer and individually revocable from the same API Keys
  panel — revoking one never affects any other person's key.
- This server only exposes the one write it needs. It can't list, search, or
  read bug reports — the person/tool using it needs the report's id already.
