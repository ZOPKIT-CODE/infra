#!/usr/bin/env node
// Per-task token attribution — the PostToolUse hook.
//
// The two bug-resolution MCP tools already bracket a task precisely:
//
//   fetch_bug_context      "calling this IS starting work on it"
//                          (open / failed_testing -> in_progress)
//   submit_bug_resolution  ends it (-> needs_testing)
//
// So a PostToolUse hook matched on those two names knows exactly when a
// task starts and stops, with the session id, the bug id (in tool_input)
// and the transcript path all handed to it on stdin. It reads the session's
// cumulative token totals at each boundary and posts them; the SERVER
// subtracts. The delta is what the bug actually cost, per model.
//
// Why the server does the subtraction rather than this hook: a locally
// cached baseline is lost on reboot (the end marker would then have nothing
// to diff against), and keeping it server-side makes an in-flight window
// reportable — "being worked right now, 120k tokens in" — which a local
// diff cannot express until the task closes.
//
// Install:  npx zopkit-bug-resolution-mcp --init-usage-reporting
//
// Wire-up (settings.json):
//   "PostToolUse": [{
//     "matcher": "mcp__bug-resolution__(fetch_bug_context|submit_bug_resolution)",
//     "hooks": [{ "type": "command", "command": "<this script>" }]
//   }]

import { loadConfig, post, readStdinJson } from '../lib/zopkit-config.js';
import { scanSessionCumulative, EMPTY_CUMULATIVE } from '../lib/session-scan.js';

const START_TOOL = 'fetch_bug_context';
const END_TOOL = 'submit_bug_resolution';

/** Which end of a window this tool call represents, or null if the hook
 *  fired for something else (a broader matcher than the documented one). */
function phaseFor(toolName) {
  if (!toolName) return null;
  if (toolName.endsWith(START_TOOL)) return 'start';
  if (toolName.endsWith(END_TOOL)) return 'end';
  return null;
}

async function main() {
  const payload = await readStdinJson();
  if (!payload) return;

  const cfg = loadConfig();
  if (!cfg) return;

  const phase = phaseFor(payload.tool_name);
  if (!phase) return;

  const bugReportId = payload.tool_input?.bugReportId;
  // fetch_assigned_bugs and create_bug_report carry no bugReportId; if a
  // broader matcher routed one here there is simply no task to bracket.
  if (!bugReportId || !payload.session_id) return;

  // PostToolUse fires AFTER the tool succeeded, so by now the transcript
  // already contains this turn — the reading includes the work up to and
  // including the marker itself, consistently at both ends, which is what
  // makes the subtraction clean.
  const cumulative = payload.transcript_path
    ? await scanSessionCumulative(payload.transcript_path).catch(() => EMPTY_CUMULATIVE)
    : EMPTY_CUMULATIVE;

  await post('/api/admin/bug-reports/task-marker', {
    bugReportId,
    sessionId: payload.session_id,
    phase,
    // The client's clock, not the server's: a hook can be retried or
    // queued, and a window's boundaries must match the transcript they
    // were read from.
    observedAt: new Date().toISOString(),
    byModel: cumulative.byModel,
    turns: cumulative.turns,
    subagentTurns: cumulative.subagentTurns,
    activeMs: cumulative.activeMs,
  });
}

// A hook that throws surfaces an error to the developer about telemetry
// they did not ask to think about. Never that.
main().catch(() => {});
