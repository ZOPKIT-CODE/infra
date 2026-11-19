#!/usr/bin/env node
// Status line + real-time usage heartbeat.
//
// Claude Code hands a statusLine command a JSON payload on stdin that
// already contains everything the Claude Usage panel was guessing at:
//
//   context_window.{total_input_tokens,context_window_size,used_percentage}
//   rate_limits.five_hour.used_percentage     <- the /usage number
//   rate_limits.seven_day.used_percentage     <- ditto, the weekly one
//   rate_limits.spend_limit.{used_usd,limit_usd}
//   cost.total_cost_usd, model, session_id, workspace.repo, version, …
//
// That is the figure report_claude_usage was asking a human to read off
// `/usage` and type in. It is not retrievable by a third party — but a
// status-line script runs INSIDE the developer's own session, so it is not
// a third party. Nothing reported here is self-attested.
//
// It re-runs on every new assistant message, on /compact, on session
// start/resume, when a rate-limit window reaches its resets_at, and on an
// optional refreshInterval timer, debounced at 300ms. One clock per
// session, ticking independently — which is what makes concurrent sessions
// work, where the old single-row-per-developer design could not.
//
// Install:  npx zopkit-bug-resolution-mcp --init-usage-reporting
//
// TWO RULES govern everything below:
//
//  1. RENDER BEFORE THE NETWORK. Claude Code cancels an in-flight status
//     line script when the next update arrives. A slow fetch before the
//     first write would blank the bar.
//  2. WHITELIST, NEVER FORWARD. The payload carries more than this feature
//     needs (session titles, prompt-cache miss causes). Only the named
//     fields below are sent, and the session title only on explicit opt-in.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir, tmpdir } from 'node:os';
import { loadConfig, post, readStdinJson } from '../lib/zopkit-config.js';

// Per-session throttle. The status line fires on every assistant message; a
// 40-turn session would otherwise be 40 POSTs. 15s keeps the panel's 10s
// poll meaningfully fresh without that.
const THROTTLE_MS = 15_000;

const STATE_DIR = join(tmpdir(), 'zopkit-usage');

function statePath(sessionId) {
  return join(STATE_DIR, `${String(sessionId).replace(/[^\w.-]/g, '_')}.json`);
}

function readState(sessionId) {
  try {
    return JSON.parse(readFileSync(statePath(sessionId), 'utf8'));
  } catch {
    return { lastSentAt: 0, lastContextTokens: null };
  }
}

function writeState(sessionId, state) {
  try {
    mkdirSync(STATE_DIR, { recursive: true });
    writeFileSync(statePath(sessionId), JSON.stringify(state));
  } catch {
    // A read-only tmpdir just means no throttling — still correct, only
    // chattier. Never a reason to fail the status line.
  }
}

function pct(n) {
  return typeof n === 'number' && Number.isFinite(n) ? Math.floor(n) : null;
}

/** The line the developer actually sees. Kept deliberately plain — anyone
 *  who wants branch/git decoration can wrap this script. */
function render(p) {
  const parts = [];
  if (p.model?.display_name) parts.push(p.model.display_name);
  const ctx = pct(p.context_window?.used_percentage);
  if (ctx !== null) parts.push(`${ctx}% ctx`);
  const week = pct(p.rate_limits?.seven_day?.used_percentage);
  if (week !== null) parts.push(`${week}% wk`);
  const fiveHour = pct(p.rate_limits?.five_hour?.used_percentage);
  // Only worth the space once it is the binding constraint — the 5-hour
  // window is what actually blocks you mid-afternoon.
  if (fiveHour !== null && fiveHour >= 50) parts.push(`${fiveHour}% 5h`);
  if (p.workspace?.git_worktree) parts.push(p.workspace.git_worktree);
  return parts.join(' · ');
}

/** Only the named fields, never the raw payload. */
function buildHeartbeat(p, cfg, fresh) {
  return {
    sessionId: p.session_id,
    sessionName: cfg.shareSessionName ? (p.session_name ?? null) : null,
    model: p.model?.id ?? null,
    version: p.version ?? null,

    contextTokens: p.context_window?.total_input_tokens ?? null,
    contextLimit: p.context_window?.context_window_size ?? null,
    contextPercent: p.context_window?.used_percentage ?? null,
    exceeds200k: p.exceeds_200k_tokens ?? null,

    cwd: p.workspace?.current_dir ?? p.cwd ?? null,
    repo: p.workspace?.repo?.name ?? null,
    gitBranch: p.workspace?.git_worktree ?? null,

    costUsd: p.cost?.total_cost_usd ?? null,
    linesAdded: p.cost?.total_lines_added ?? null,
    linesRemoved: p.cost?.total_lines_removed ?? null,
    effort: p.effort?.level ?? null,
    fastMode: p.fast_mode ?? null,

    rateLimits: p.rate_limits ?? null,

    // Whether a NEW API response landed since the last heartbeat for this
    // session, detected by the context token count moving. Only a fresh
    // reading may advance the account-level percentages: an idle session's
    // status line still re-renders on a timer carrying `rate_limits` from
    // its last API response, possibly an hour stale, and would otherwise
    // walk a live session's number backwards.
    fresh,
  };
}

async function main() {
  const payload = await readStdinJson();
  if (!payload) return;

  // RULE 1: the bar is written before anything can block.
  process.stdout.write(render(payload));

  const cfg = loadConfig();
  if (!cfg || !payload.session_id) return;

  const state = readState(payload.session_id);
  const now = Date.now();
  const contextTokens = payload.context_window?.total_input_tokens ?? null;
  const fresh = contextTokens !== null && contextTokens !== state.lastContextTokens;

  // Throttle, but never let a fresh reading wait: a developer watching
  // their weekly percentage climb should see it move on the panel, not 15
  // seconds later.
  if (!fresh && now - (state.lastSentAt || 0) < THROTTLE_MS) return;

  writeState(payload.session_id, { lastSentAt: now, lastContextTokens: contextTokens });
  await post('/api/admin/claude-usage/heartbeat', buildHeartbeat(payload, cfg, fresh));
}

// Any unexpected throw must still leave the bar rendered and the editor
// unbothered.
main().catch(() => {});
