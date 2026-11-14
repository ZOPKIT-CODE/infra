// Shared config for the hook/status-line binaries (bin/*.js).
//
// The MCP server itself gets BUG_REPORT_API_KEY from the `env` block of the
// mcpServers entry in ~/.claude.json. Hooks and the status line do NOT —
// they are plain commands Claude Code spawns, inheriting only the ordinary
// shell environment, which does not have that key.
//
// So they read a small config file instead, and fall back to the env var for
// anyone who does export it globally. The file lives outside the repo on
// purpose: an API key in settings.json is one `git add` away from being
// committed.
//
//   ~/.claude/.zopkit-usage.json
//   { "apiKey": "bugres_…", "baseUrl": "https://api.zopkit.com" }
//
// Create it with:  npx zopkit-bug-resolution-mcp --init-usage-reporting

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

export const CONFIG_PATH = join(homedir(), '.claude', '.zopkit-usage.json');

let cached;

export function loadConfig() {
  if (cached !== undefined) return cached;
  let file = {};
  try {
    file = JSON.parse(readFileSync(CONFIG_PATH, 'utf8'));
  } catch {
    // Missing or unreadable is the normal case before setup — not an error
    // worth printing, since these binaries run on every status-line render
    // and must never write noise into a developer's terminal.
  }
  const apiKey = file.apiKey || process.env.BUG_REPORT_API_KEY || null;
  const baseUrl = (file.baseUrl || process.env.BUG_REPORT_API_BASE_URL || 'https://api.zopkit.com').replace(/\/$/, '');
  // Opt-in, default off. The session title describes what a developer is
  // working on, which is a step beyond the cwd this feature already
  // collects, and it lands on a panel every staff member with the
  // 'claude-usage' section can read.
  const shareSessionName = file.shareSessionName === true;
  cached = apiKey ? { apiKey, baseUrl, shareSessionName } : null;
  return cached;
}

/**
 * POST, with a hard timeout and every failure swallowed.
 *
 * Nothing these binaries report is worth degrading the editor over: a status
 * line that hangs on a network call blanks the bar, and a hook that throws
 * surfaces an error to the developer about telemetry they did not ask to
 * think about. The next heartbeat is seconds away, so there is nothing to
 * retry either.
 */
export async function post(path, body, { timeoutMs = 5000 } = {}) {
  const cfg = loadConfig();
  if (!cfg) return null;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`${cfg.baseUrl}${path}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-API-Key': cfg.apiKey },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
    if (!res.ok) return null;
    return await res.json().catch(() => null);
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** Read all of stdin as text. Claude Code hands hooks and the status line
 *  their JSON payload this way. */
export async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

/** Parse the stdin payload, returning null rather than throwing — a
 *  malformed payload must not take the status line down with it. */
export async function readStdinJson() {
  try {
    return JSON.parse(await readStdin());
  } catch {
    return null;
  }
}
