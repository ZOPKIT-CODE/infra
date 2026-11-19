#!/usr/bin/env node
// SessionEnd hook — drop a finished session off the Claude Usage panel at
// once, instead of letting it age out of the live window.
//
// Best-effort by nature: a crashed terminal, a killed tmux pane or a closed
// laptop never fire SessionEnd. That is exactly why the server derives
// "live" from lastSeenAt rather than storing a flag — this hook makes the
// common case immediate, it is not what makes it correct.
//
// Wire-up (settings.json):
//   "SessionEnd": [{ "hooks": [{ "type": "command", "command": "<this script>" }] }]

import { loadConfig, post, readStdinJson } from '../lib/zopkit-config.js';

async function main() {
  const payload = await readStdinJson();
  if (!payload?.session_id) return;
  if (!loadConfig()) return;

  await post(
    '/api/admin/claude-usage/session-end',
    { sessionId: payload.session_id, reason: payload.reason },
    // SessionEnd hooks share a 1.5s budget by default, so this gets a
    // tighter timeout than the rest: better to leave the row to age out
    // than to hold up the editor's shutdown.
    { timeoutMs: 1200 }
  );
}

main().catch(() => {});
