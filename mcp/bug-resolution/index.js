#!/usr/bin/env node
// bug-resolution MCP server — six tools wrapping the bug-reports resolution
// API (see backend/src/features/bug-reports/README.md) so a developer's
// Claude Code / Cursor session can work a bug report end to end as native
// tool calls instead of hand-rolling curl commands:
//   - fetch_bug_context: GET /api/admin/bug-reports/context/:id — pulls the
//     full report (title/description/severity/status/comments) plus every
//     inline screenshot as real image content. Also IS "starting work on
//     it": open/failed_testing auto-moves to in_progress as a side effect.
//   - submit_bug_resolution: POST /api/admin/bug-reports/resolution/:id —
//     writes back the fix as a Markdown resolution and moves it to
//     needs_testing (not resolved — a human verifies it first).
//   - fetch_assigned_bugs: GET /api/admin/bug-reports/assigned — "what's on
//     my plate", always the API key owner's own assigned reports.
//   - create_bug_report: POST /api/admin/bug-reports/report — file a new bug
//     the tool found, optionally self-assigning it.
//   - report_claude_usage: POST /api/admin/claude-usage — SELF-ATTESTED:
//     self-reports this developer's current Claude Code usage percentage
//     (see backend/src/features/claude-usage/README.md for why this is
//     self-reported rather than fetched from an Anthropic API), shown on
//     the company-admin panel's "Claude Usage" tab.
//   - report_claude_token_usage: POST /api/admin/claude-usage/token-breakdown
//     — REAL, not self-attested: scans this developer's own local Claude
//     Code transcripts (~/.claude/projects/**/*.jsonl AND their nested
//     .../subagents/*.jsonl — this server runs on the same machine) for a
//     token/model/context breakdown over a configurable window (default 7
//     days): per-model token split, how full the most recently active
//     session's context window is right now, and web-search/subagent usage
//     — subagent token spend is folded into the totals, not just detected.
//     The other four bug-resolution tools above also trigger this
//     automatically as a genuinely non-blocking side effect
//     (tryAutoReportTokenUsage never awaited) — "every task done in the bug
//     reporter" keeps this fresh with zero extra asks and zero added latency.
// Thin wrapper: all the actual logic (auth, scoping, the DB writes) lives
// server-side; this just forwards the HTTP calls the README documents.
//
// Setup: see README.md in this directory.

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { createReadStream, readdirSync, statSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { join, basename } from 'node:path';
import { homedir } from 'node:os';

// ── CLI subcommands ───────────────────────────────────────────────────────
// Handled BEFORE the server is constructed (and before the API-key guard
// below), since --init-usage-reporting exists precisely to configure a
// machine that has no key yet. Without a subcommand this falls straight
// through to the stdio MCP server, which is the normal path.
const argv = process.argv.slice(2);
function flag(name) {
  const i = argv.indexOf(`--${name}`);
  return i === -1 ? undefined : (argv[i + 1]?.startsWith('--') ? true : argv[i + 1] ?? true);
}

if (argv.includes('--init-usage-reporting')) {
  const { initUsageReporting } = await import('./lib/init-usage-reporting.js');
  process.exit(
    initUsageReporting({
      apiKey: typeof flag('api-key') === 'string' ? flag('api-key') : undefined,
      baseUrl: typeof flag('base-url') === 'string' ? flag('base-url') : undefined,
      shareSessionName: argv.includes('--share-session-name'),
    })
  );
}

if (argv.includes('--check-statusline')) {
  const { checkStatusline } = await import('./lib/init-usage-reporting.js');
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  process.exit(await checkStatusline(Buffer.concat(chunks).toString('utf8')));
}

if (argv.includes('--backfill-tasks')) {
  const { runBackfill } = await import('./bin/zopkit-backfill-tasks.js');
  const days = Number(flag('days'));
  await runBackfill({
    days: Number.isFinite(days) && days > 0 ? days : 90,
    dryRun: argv.includes('--dry-run'),
  });
  process.exit(process.exitCode ?? 0);
}

const API_KEY = process.env.BUG_REPORT_API_KEY;
const BASE_URL = (process.env.BUG_REPORT_API_BASE_URL || 'https://api.zopkit.com').replace(/\/$/, '');

if (!API_KEY) {
  console.error('[bug-resolution-mcp] BUG_REPORT_API_KEY is not set — every call will fail. ' +
    'Generate one from the company-admin panel (Bug Reports → API Keys) and set it when registering this server.');
}

const server = new McpServer({ name: 'zopkit-bug-resolution', version: '1.8.0' });

const BUG_SEVERITIES = ['low', 'medium', 'high', 'critical'];
// Keep in sync with BUG_STATUSES in backend/src/db/schema/platform/bug-reports.ts.
// This list was missing needs_testing/failed_testing for a while, which meant
// fetch_assigned_bugs couldn't even be asked to filter to exactly the two
// statuses a developer cares about most (a fresh fix bounced back by QA, or
// one still waiting on QA) — the backend has allowed both for a while.
const BUG_STATUSES = ['open', 'in_progress', 'needs_testing', 'failed_testing', 'blocked', 'further_discussion', 'resolved'];
const BUG_PROJECTS = ['wrapper', 'crm', 'fa', 'accounting', 'academy', 'itsm', 'studio', 'retail_erp', 'entertainment_erp'];

const IMG_SRC = /<img\b[^>]*\bsrc="([^"]+)"[^>]*>/gi;

function extractImageUrls(html) {
  const urls = [];
  for (const match of html.matchAll(IMG_SRC)) {
    const src = match[1];
    urls.push(src.startsWith('http') ? src : `${BASE_URL}${src}`);
  }
  return urls;
}

async function fetchImageContentBlock(url) {
  const res = await fetch(url);
  if (!res.ok) return null;
  const contentType = res.headers.get('content-type') || 'image/png';
  const buffer = Buffer.from(await res.arrayBuffer());
  return { type: 'image', data: buffer.toString('base64'), mimeType: contentType };
}

// ── Token usage breakdown (report_claude_token_usage) ──────────────────────
// Unlike usagePercent (self-attested, see submit_bug_resolution's comment on
// why), this is read straight off Claude Code's own local transcript files —
// this MCP server is a local process on the SAME machine as the Claude Code
// session using it, so it can read ~/.claude/projects/**/*.jsonl directly.
// No statusLine setup, no asking a human, no per-seat API that doesn't exist.
//
// Each API response gets logged 2-3x in these files (streaming writes the
// same final usage numbers once per content-block flush) — every count below
// dedupes by message.id, or totals would be inflated 2-3x.
const PROJECTS_DIR = join(homedir(), '.claude', 'projects');
const SUBAGENT_TOOL_NAMES = new Set(['Agent', 'Task']);
// Client-side web tools (not Anthropic's server-executed web_search/
// web_fetch — see usage.server_tool_use below, a DIFFERENT mechanism) show up
// as ordinary tool_use blocks instead. Both count as "used web search" for
// weeklySessionsWithWebSearch; missing this half undercounted it before.
const WEB_TOOL_NAMES = new Set(['WebSearch', 'WebFetch']);

// Context-window ceiling per model family — used only to turn
// currentContextTokens into a percentage the panel can render as a bar.
// Heuristic, not queried from Anthropic (there's no local API for "is this
// account's extended-context beta on"): Sonnet ships with a 1M-token beta
// context window in Claude Code; Opus/Haiku are the standard 200k. Falls
// back to 200k for anything unrecognized — an undercount of the true limit
// is the safe failure direction (a 1M-context Opus session would just show
// as "over 100%", visibly wrong and prompting a fix, not silently hidden).
function contextLimitForModel(model) {
  if (!model) return 200_000;
  if (model.includes('sonnet')) return 1_000_000;
  return 200_000;
}

/**
 * Every transcript file to scan in the window: each main session file
 * PLUS its subagent transcripts (…/<sessionId>/subagents/*.jsonl) — a
 * separate, nested location a flat directory listing never finds, which is
 * exactly why subagent token usage was invisible before (an Agent/Task tool
 * call was detected on the main thread, but what THAT subagent itself spent
 * was never read at all). Each entry is tagged so the caller can attribute
 * subagent tokens separately while still rolling them into the session total.
 */
function listRecentTranscripts(sinceMs) {
  const files = [];
  let projectDirs;
  try {
    projectDirs = readdirSync(PROJECTS_DIR, { withFileTypes: true });
  } catch {
    return files; // no ~/.claude/projects at all — nothing to scan
  }
  for (const projectDir of projectDirs) {
    if (!projectDir.isDirectory()) continue;
    const dirPath = join(PROJECTS_DIR, projectDir.name);
    let entries;
    try {
      entries = readdirSync(dirPath, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (entry.isFile() && entry.name.endsWith('.jsonl')) {
        const filePath = join(dirPath, entry.name);
        try {
          if (statSync(filePath).mtimeMs >= sinceMs) {
            files.push({ filePath, isSubagent: false, sessionDir: join(dirPath, entry.name.replace(/\.jsonl$/, '')) });
          }
        } catch {
          // file vanished between readdir and stat — skip
        }
      }
    }
  }
  // Second pass for subagent files — needs the session dirs discovered above.
  for (const main of files.slice()) {
    let subFiles;
    try {
      subFiles = readdirSync(join(main.sessionDir, 'subagents'), { withFileTypes: true });
    } catch {
      continue; // no subagents dir for this session — the common case
    }
    for (const sub of subFiles) {
      if (!sub.isFile() || !sub.name.endsWith('.jsonl')) continue;
      const filePath = join(main.sessionDir, 'subagents', sub.name);
      try {
        if (statSync(filePath).mtimeMs >= sinceMs) {
          files.push({ filePath, isSubagent: true, parentSessionId: basename(main.filePath, '.jsonl') });
        }
      } catch {
        // skip
      }
    }
  }
  return files;
}

// Per-process cache keyed by (path, mtime, size) — a transcript already
// scanned this run, unchanged on disk, is never re-read. Only helps within
// one long-lived MCP server process (one Claude Code session calling this
// repeatedly), not across separate sessions — still the common case, since
// the auto-report path fires on every bug-report tool call.
const scanCache = new Map();

/** One transcript's token totals + what it used — null if nothing in range
 *  (e.g. mtime was recent but every logged message predates sinceMs).
 *  Streams line-by-line (readline over a read stream) instead of loading the
 *  whole file into memory — a long session's transcript can run into the
 *  hundreds of MB, and the previous readFileSync+split approach held the
 *  entire thing (plus the split array) in memory at once. */
async function scanTranscript(filePath, sinceMs) {
  let stat;
  try {
    stat = statSync(filePath);
  } catch {
    return null;
  }
  const cacheKey = `${filePath}:${stat.mtimeMs}:${stat.size}`;
  const cached = scanCache.get(cacheKey);
  if (cached) return cached.sinceMs <= sinceMs ? cached.result : null; // a wider window than what's cached still needs a rescan — conservative

  const seenMessageIds = new Set();
  let inputTokens = 0, outputTokens = 0, cacheCreationTokens = 0, cacheReadTokens = 0;
  let usedWebSearch = false, usedSubagents = false;
  let startedAt = null, cwd = null, gitBranch = null, sessionId = null, version = null;
  /** @type {Record<string, {inputTokens:number, outputTokens:number, cacheCreationTokens:number, cacheReadTokens:number}>} */
  const byModel = {};
  let lastModel = null, lastContextTokens = 0, lastTimestamp = null;

  const rl = createInterface({ input: createReadStream(filePath, 'utf8'), crlfDelay: Infinity });
  for await (const line of rl) {
    if (!line.trim()) continue;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      continue; // truncated/partial last line — skip it, not the whole file
    }
    if (entry.type !== 'assistant' || !entry.message) continue;
    // A missing timestamp means "can't verify this is in-window" — exclude
    // it rather than risk a pre-window message slipping into the totals (the
    // opposite bug from before: entry.timestamp && ... let a falsy timestamp
    // skip the check entirely, i.e. silently PASS it through unfiltered).
    if (!entry.timestamp || Date.parse(entry.timestamp) < sinceMs) continue;

    if (cwd === null && entry.cwd) cwd = basename(entry.cwd); // basename only — see upsertTokenBreakdown's privacy comment
    if (sessionId === null && entry.sessionId) sessionId = entry.sessionId;
    if (gitBranch === null && entry.gitBranch) gitBranch = entry.gitBranch;
    if (version === null && entry.version) version = entry.version;
    if (!startedAt || entry.timestamp < startedAt) startedAt = entry.timestamp;

    // Tool-use detection runs on every line, duplicates included — setting a
    // boolean true twice is harmless, unlike double-counting tokens below.
    if (Array.isArray(entry.message.content)) {
      for (const block of entry.message.content) {
        if (block?.type !== 'tool_use') continue;
        if (SUBAGENT_TOOL_NAMES.has(block.name)) usedSubagents = true;
        if (WEB_TOOL_NAMES.has(block.name)) usedWebSearch = true;
      }
    }

    const messageId = entry.message.id;
    if (messageId) {
      if (seenMessageIds.has(messageId)) continue;
      seenMessageIds.add(messageId);
    }

    const usage = entry.message.usage;
    if (!usage) continue;
    const model = entry.message.model || 'unknown';
    const mi = usage.input_tokens || 0, mo = usage.output_tokens || 0;
    const mc = usage.cache_creation_input_tokens || 0, mr = usage.cache_read_input_tokens || 0;
    inputTokens += mi; outputTokens += mo; cacheCreationTokens += mc; cacheReadTokens += mr;
    // Claude Code emits internally-synthesized assistant entries tagged
    // model: "<synthetic>" (and similar) with zero real usage — real API
    // calls always cost SOMETHING, so skip attributing a model entry when
    // every field is zero, rather than littering byModel with noise rows.
    if (mi + mo + mc + mr > 0) {
      const m = (byModel[model] ??= { inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0 });
      m.inputTokens += mi; m.outputTokens += mo; m.cacheCreationTokens += mc; m.cacheReadTokens += mr;
    }

    const serverTools = usage.server_tool_use;
    if (serverTools && ((serverTools.web_search_requests || 0) > 0 || (serverTools.web_fetch_requests || 0) > 0)) {
      usedWebSearch = true;
    }

    // "Current context occupancy" — what the model was actually carrying at
    // THIS turn: the uncached input plus everything served from/written to
    // cache. Tracked off the chronologically LAST REAL message in the file
    // (not the biggest, and not a trailing zero-usage synthetic entry,
    // which would otherwise report "0 tokens / <synthetic>" for a session
    // that actually ended on a real turn).
    if (mi + mo + mc + mr > 0 && (!lastTimestamp || entry.timestamp >= lastTimestamp)) {
      lastTimestamp = entry.timestamp;
      lastModel = model;
      lastContextTokens = mi + mc + mr;
    }
  }

  const totalTokens = inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens;
  const result = totalTokens === 0 ? null : {
    totalTokens, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens,
    usedWebSearch, usedSubagents, startedAt, lastTimestamp, cwd, gitBranch, sessionId, version, byModel,
    currentContextTokens: lastContextTokens,
    currentContextModel: lastModel,
  };
  scanCache.set(cacheKey, { sinceMs, result });
  return result;
}

function mergeByModel(target, source) {
  for (const [model, v] of Object.entries(source)) {
    const m = (target[model] ??= { inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0 });
    m.inputTokens += v.inputTokens; m.outputTokens += v.outputTokens;
    m.cacheCreationTokens += v.cacheCreationTokens; m.cacheReadTokens += v.cacheReadTokens;
  }
}

/**
 * Scans every local Claude Code transcript touched in the last `days` days
 * (main sessions AND their subagent transcripts — see listRecentTranscripts)
 * and aggregates it into the shape reportClaudeTokenUsageSchema expects.
 * Deliberately NOT scoped to this repo/project — the whole point is "how
 * much Claude Code usage this week", same scope /usage itself reports.
 */
async function computeWeeklyTokenBreakdown(days = 7) {
  const sinceMs = Date.now() - days * 24 * 60 * 60 * 1000;
  const fileRefs = listRecentTranscripts(sinceMs);
  const scanned = await Promise.all(fileRefs.map((f) => scanTranscript(f.filePath, sinceMs)));

  const mainSessions = [];
  const subagentResults = [];
  fileRefs.forEach((ref, i) => {
    const s = scanned[i];
    if (!s) return;
    if (ref.isSubagent) subagentResults.push(s);
    else mainSessions.push(s);
  });

  const totals = mainSessions.reduce(
    (acc, s) => ({
      inputTokens: acc.inputTokens + s.inputTokens,
      outputTokens: acc.outputTokens + s.outputTokens,
      cacheCreationTokens: acc.cacheCreationTokens + s.cacheCreationTokens,
      cacheReadTokens: acc.cacheReadTokens + s.cacheReadTokens,
    }),
    { inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0 }
  );

  // Subagent "new work" (input+output+cache-creation, same exclusion as
  // newTokenCount below) folded into the SAME four columns so the headline
  // total is actually complete — a session that spawned subagents no longer
  // silently undercounts what those subagents spent. Also kept as its own
  // figure (subagentTokens) so the breakdown stays honest about the split.
  const subagentTokens = subagentResults.reduce((sum, s) => sum + s.inputTokens + s.outputTokens + s.cacheCreationTokens, 0);
  totals.inputTokens += subagentResults.reduce((sum, s) => sum + s.inputTokens, 0);
  totals.outputTokens += subagentResults.reduce((sum, s) => sum + s.outputTokens, 0);
  totals.cacheCreationTokens += subagentResults.reduce((sum, s) => sum + s.cacheCreationTokens, 0);
  totals.cacheReadTokens += subagentResults.reduce((sum, s) => sum + s.cacheReadTokens, 0);

  const byModel = {};
  for (const s of mainSessions) mergeByModel(byModel, s.byModel);
  for (const s of subagentResults) mergeByModel(byModel, s.byModel);

  // "Right now" context occupancy — pick the MAIN session whose own last
  // message is chronologically most recent (not whichever started most
  // recently — a session can run for hours), and use its last-message
  // context snapshot. null when nothing was scanned at all.
  const mostRecentSession = mainSessions.reduce(
    (latest, s) => (!latest || (s.lastTimestamp ?? '') > (latest.lastTimestamp ?? '') ? s : latest),
    null
  );
  const currentContext = mostRecentSession && {
    tokens: mostRecentSession.currentContextTokens,
    model: mostRecentSession.currentContextModel,
    limit: contextLimitForModel(mostRecentSession.currentContextModel),
  };

  const topSessions = [...mainSessions]
    .sort((a, b) => b.totalTokens - a.totalTokens)
    .slice(0, 8)
    .map((s) => ({
      totalTokens: s.totalTokens,
      startedAt: s.startedAt || new Date(sinceMs).toISOString(),
      cwd: s.cwd,
      gitBranch: s.gitBranch,
      sessionId: s.sessionId,
      version: s.version,
      model: s.currentContextModel,
      contextTokens: s.currentContextTokens,
      usedWebSearch: s.usedWebSearch,
      usedSubagents: s.usedSubagents,
    }));

  return {
    periodStart: new Date(sinceMs).toISOString(),
    periodEnd: new Date().toISOString(),
    ...totals,
    subagentTokens,
    byModel,
    currentContextTokens: currentContext?.tokens ?? null,
    currentContextModel: currentContext?.model ?? null,
    currentContextLimit: currentContext?.limit ?? null,
    sessionCount: mainSessions.length,
    sessionsWithWebSearch: mainSessions.filter((s) => s.usedWebSearch).length,
    // A session counts as "used subagents" either because the main thread
    // itself spawned one (tool_use detection) OR because subagent transcript
    // files were found for it at all — the two signals can disagree if a
    // subagent was spawned but its own file hasn't flushed yet.
    sessionsWithSubagents: mainSessions.filter(
      (s) => s.usedSubagents || subagentResults.some((sub) => fileRefs.some((r) => r.isSubagent && r.parentSessionId === s.sessionId))
    ).length,
    topSessions,
  };
}

/** "585k" / "2.3M" / "1.1B" — raw token counts in a long session routinely
 *  reach the hundreds of millions (every turn re-pays for its whole cached
 *  context, so cache-read alone compounds fast), so a plain toLocaleString()
 *  reads as an alarming wall of digits. Still real numbers — just formatted
 *  for a human skimming a report, not a ledger. One decimal place
 *  everywhere, including k — the panel (frontend's api.ts) uses the same
 *  convention, so a number never reads differently in the two places it
 *  can show up. */
function formatTokenCount(n) {
  if (n >= 1e9) return `${(n / 1e9).toFixed(1)}B`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)}k`;
  return String(n);
}

/** input + output + cache-WRITE tokens — genuinely new content processed
 *  this period (subagent spend already folded in — see computeWeeklyTokenBreakdown).
 *  Deliberately excludes cache-READ: that's a heavily-discounted re-read of
 *  context already paid for once, and in a long session it dwarfs
 *  everything else by 10-100x, so folding it into one headline number would
 *  make "new work this week" unreadable. Still reported separately in full
 *  (see the schema) — just not what ranks/headlines. */
function newTokenCount(breakdown) {
  return breakdown.inputTokens + breakdown.outputTokens + breakdown.cacheCreationTokens;
}

/**
 * Fire-and-forget: scan + POST the breakdown, swallowing any failure (a
 * missing ~/.claude/projects dir, a network blip, whatever) — this must
 * never fail or slow down the tool call it's piggybacking on. Genuinely
 * non-blocking now (not awaited by its four callers below) — the scan can
 * run into the hundreds of MB and take the better part of a second even
 * streamed, which used to add that same delay to every single bug-report
 * tool call despite the "fire-and-forget" name. Returns nothing: with no
 * await, there's no result left by the time the real tool response goes
 * out, so the old "(Also updated your Claude token usage: ...)" footer is
 * gone too — the next report_claude_token_usage call (or the next bug tool,
 * since this still runs after every one) is what actually surfaces it.
 */
function tryAutoReportTokenUsage() {
  if (!API_KEY) return;
  computeWeeklyTokenBreakdown()
    .then((breakdown) => {
      if (breakdown.sessionCount === 0) return;
      return fetch(`${BASE_URL}/api/admin/claude-usage/token-breakdown`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-API-Key': API_KEY },
        body: JSON.stringify(breakdown),
      });
    })
    .catch(() => {}); // never let this break (or even be waited on by) the real tool call
}

server.registerTool(
  'submit_bug_resolution',
  {
    title: 'Submit bug resolution',
    description:
      "Report how a Zopkit bug report was fixed. Sets the report's resolution notes to the given " +
      "Markdown writeup and moves its status to 'needs_testing' — NOT 'resolved' directly; a human " +
      "still needs to verify the fix before it's truly done. Use the bug report's id " +
      '(a UUID, given to you by whoever asked you to fix it, or visible in its admin-panel URL).',
    inputSchema: {
      bugReportId: z.string().min(1).describe("The bug report's id (UUID)."),
      markdown: z
        .string()
        .min(1)
        .describe(
          'The resolution writeup, as Markdown — root cause, the fix, files touched, ' +
          'verification steps, links to the commit/PR. No length limit; be as thorough as warranted.'
        ),
    },
  },
  async ({ bugReportId, markdown }) => {
    if (!API_KEY) {
      return {
        isError: true,
        content: [{ type: 'text', text: 'BUG_REPORT_API_KEY is not set on this MCP server — see README.md.' }],
      };
    }

    let res;
    try {
      res = await fetch(`${BASE_URL}/api/admin/bug-reports/resolution/${encodeURIComponent(bugReportId)}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-API-Key': API_KEY },
        body: JSON.stringify({ markdown }),
      });
    } catch (err) {
      return {
        isError: true,
        content: [{ type: 'text', text: `Could not reach ${BASE_URL}: ${err instanceof Error ? err.message : String(err)}` }],
      };
    }

    const body = await res.json().catch(() => null);

    if (!res.ok) {
      const message = body?.message || body?.error || `HTTP ${res.status}`;
      return { isError: true, content: [{ type: 'text', text: `Failed to submit resolution: ${message}` }] };
    }

    const report = body?.data;
    tryAutoReportTokenUsage();
    return {
      content: [{
        type: 'text',
        text: report
          ? `Resolution submitted. "${report.title}" is now ${report.status}.`
          : 'Resolution submitted.',
      }],
    };
  }
);

server.registerTool(
  'fetch_bug_context',
  {
    title: 'Fetch bug report context',
    description:
      'Pull the full context for a Zopkit bug report — title, description, severity, status, ' +
      'page URL, browser info, discussion comments, and every inline screenshot as actual images — ' +
      'so an AI coding tool has everything it needs to diagnose and fix the bug without ' +
      "opening the admin panel. Screenshots come back as image content alongside the text summary. " +
      "Calling this IS starting work on it: a report sitting at 'open' or 'failed_testing' moves " +
      "straight to 'in_progress' as a side effect (anything further along — in_progress itself, " +
      "needs_testing, blocked, further_discussion, resolved — is left untouched).",
    inputSchema: {
      bugReportId: z.string().min(1).describe("The bug report's id (UUID)."),
    },
  },
  async ({ bugReportId }) => {
    if (!API_KEY) {
      return {
        isError: true,
        content: [{ type: 'text', text: 'BUG_REPORT_API_KEY is not set on this MCP server — see README.md.' }],
      };
    }

    let res;
    try {
      res = await fetch(`${BASE_URL}/api/admin/bug-reports/context/${encodeURIComponent(bugReportId)}`, {
        headers: { 'X-API-Key': API_KEY },
      });
    } catch (err) {
      return {
        isError: true,
        content: [{ type: 'text', text: `Could not reach ${BASE_URL}: ${err instanceof Error ? err.message : String(err)}` }],
      };
    }

    const body = await res.json().catch(() => null);

    if (!res.ok) {
      const message = body?.message || body?.error || `HTTP ${res.status}`;
      return { isError: true, content: [{ type: 'text', text: `Failed to fetch bug context: ${message}` }] };
    }

    const report = body?.data;
    if (!report) {
      return { isError: true, content: [{ type: 'text', text: 'Bug context response had no data.' }] };
    }

    const comments = report.comments || [];
    const commentsText = comments.length
      ? comments.map((c) => `- ${c.authorName || c.authorEmail} (${c.createdAt}): ${c.body}`).join('\n')
      : '(no comments)';

    const summary = [
      `# ${report.title}`,
      `id: ${report.id}`,
      `severity: ${report.severity} | status: ${report.status}`,
      report.pageUrl ? `page: ${report.pageUrl}` : null,
      report.browserInfo ? `browser: ${report.browserInfo}` : null,
      '',
      '## Description',
      report.description,
      '',
      '## Discussion',
      commentsText,
    ].filter((line) => line !== null).join('\n');

    const content = [{ type: 'text', text: summary }];

    // Inline screenshots live as <img> tags inside the description HTML —
    // fetch each (now-public) media URL and hand it back as real image
    // content so the AI tool actually sees the bug, not just a URL to it.
    const imageUrls = extractImageUrls(report.description || '');
    for (const url of imageUrls) {
      try {
        const block = await fetchImageContentBlock(url);
        if (block) content.push(block);
      } catch {
        content.push({ type: 'text', text: `(failed to load screenshot: ${url})` });
      }
    }

    tryAutoReportTokenUsage();

    return { content };
  }
);

server.registerTool(
  'fetch_assigned_bugs',
  {
    title: 'Fetch bugs assigned to me',
    description:
      "List Zopkit bug reports currently assigned to this API key's owner — \"what's on my plate\". " +
      "Always the key owner's own assigned reports, never anyone else's, regardless of what the key " +
      "can otherwise see. Defaults to every status EXCEPT 'resolved' (pass status: ['all'] to include " +
      "resolved history too), sorted with whatever needs attention soonest first (a fix QA bounced back " +
      "via 'failed_testing', then active work, then fixes merely awaiting QA). Paginated — use limit/offset " +
      'if the result says there are more than fit on one page.',
    inputSchema: {
      status: z
        .array(z.enum([...BUG_STATUSES, 'all']))
        .optional()
        .describe(
          "One or more statuses to filter to. Omit for the default (everything but 'resolved'); " +
          "pass ['all'] to include resolved history too."
        ),
      limit: z.number().int().min(1).max(100).optional().describe('Max reports to return (default 50, max 100).'),
      offset: z.number().int().min(0).optional().describe('Skip this many reports, for paging past the first batch.'),
    },
  },
  async ({ status, limit, offset }) => {
    if (!API_KEY) {
      return {
        isError: true,
        content: [{ type: 'text', text: 'BUG_REPORT_API_KEY is not set on this MCP server — see README.md.' }],
      };
    }

    const url = new URL(`${BASE_URL}/api/admin/bug-reports/assigned`);
    if (status?.length) url.searchParams.set('status', status.join(','));
    if (limit != null) url.searchParams.set('limit', String(limit));
    if (offset != null) url.searchParams.set('offset', String(offset));

    let res;
    try {
      res = await fetch(url, { headers: { 'X-API-Key': API_KEY } });
    } catch (err) {
      return {
        isError: true,
        content: [{ type: 'text', text: `Could not reach ${BASE_URL}: ${err instanceof Error ? err.message : String(err)}` }],
      };
    }

    const body = await res.json().catch(() => null);

    if (!res.ok) {
      const message = body?.message || body?.error || `HTTP ${res.status}`;
      return { isError: true, content: [{ type: 'text', text: `Failed to fetch assigned bugs: ${message}` }] };
    }

    const reports = body?.data || [];
    const meta = body?.meta;
    if (reports.length === 0) {
      return { content: [{ type: 'text', text: 'No bug reports currently assigned to you (in the requested status(es)).' }] };
    }

    const summary = reports
      .map((r) => `- [${r.severity}/${r.status}] ${r.title} (id: ${r.id})${r.project ? ` — project: ${r.project}` : ''}`)
      .join('\n');

    // meta.total counts everything matching the filter, not just this page —
    // say so explicitly instead of letting a truncated page read as "that's all of it".
    const header = meta && meta.total > reports.length
      ? `${reports.length} of ${meta.total} assigned report(s) (showing offset ${meta.offset}–${meta.offset + reports.length - 1}; pass a higher offset for more):`
      : `${reports.length} assigned report(s):`;

    tryAutoReportTokenUsage();
    return {
      content: [{
        type: 'text',
        text: `${header}\n${summary}`,
      }],
    };
  }
);

server.registerTool(
  'create_bug_report',
  {
    title: 'Create a bug report',
    description:
      'File a new Zopkit bug report — e.g. something this tool noticed while working on something else. ' +
      'Description is plain text (paragraphs separated by a blank line), not rich-text HTML.',
    inputSchema: {
      title: z.string().min(1).max(255).describe('A short, specific summary of the bug.'),
      description: z.string().min(1).describe('The bug, in plain text — what happened, expected vs actual, repro steps.'),
      severity: z.enum(BUG_SEVERITIES).optional().describe('Defaults to "medium".'),
      project: z.enum(BUG_PROJECTS).optional().describe('Which product this bug is in, if known.'),
      pageUrl: z.string().max(2048).optional().describe('The URL where the bug was observed, if applicable.'),
      assignToSelf: z.boolean().optional().describe('Self-assign this report to the API key owner. Defaults to false (unassigned).'),
    },
  },
  async ({ title, description, severity, project, pageUrl, assignToSelf }) => {
    if (!API_KEY) {
      return {
        isError: true,
        content: [{ type: 'text', text: 'BUG_REPORT_API_KEY is not set on this MCP server — see README.md.' }],
      };
    }

    let res;
    try {
      res = await fetch(`${BASE_URL}/api/admin/bug-reports/report`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-API-Key': API_KEY },
        body: JSON.stringify({ title, description, severity, project, pageUrl, assignToSelf }),
      });
    } catch (err) {
      return {
        isError: true,
        content: [{ type: 'text', text: `Could not reach ${BASE_URL}: ${err instanceof Error ? err.message : String(err)}` }],
      };
    }

    const body = await res.json().catch(() => null);

    if (!res.ok) {
      const message = body?.message || body?.error || `HTTP ${res.status}`;
      return { isError: true, content: [{ type: 'text', text: `Failed to create bug report: ${message}` }] };
    }

    const report = body?.data;
    tryAutoReportTokenUsage();
    return {
      content: [{
        type: 'text',
        text: report
          ? `Bug report created: "${report.title}" (id: ${report.id}).`
          : 'Bug report created.',
      }],
    };
  }
);

server.registerTool(
  'report_claude_usage',
  {
    title: 'Report Claude usage status',
    description:
      "Report this developer's current Claude Code account/session usage percentage, shown on the " +
      'company-admin panel\'s "Claude Usage" tab. Self-reported — there is no API to fetch this on your ' +
      'behalf (Anthropic has no per-seat "current usage %" endpoint, and the percentage Claude Code\'s own ' +
      '/usage shows is computed client-side from this session\'s own rate-limit headers, not retrievable by ' +
      'a third party). Pass whatever percentage you or the user currently see — e.g. from the /usage ' +
      "command, the status line, or the account's billing page. Identity (who this is) is resolved from " +
      'your API key, not from anything passed here.',
    inputSchema: {
      usagePercent: z.number().min(0).max(100).describe('Current usage, 0-100 (fractional values like 72.5 are fine).'),
      note: z.string().max(500).optional().describe('Optional context, e.g. "Team plan, resets Monday".'),
      // Structured, not buried in `note` — lets the panel show a real
      // countdown/staleness indicator instead of free text it has to
      // truncate. Pass it whenever you can see a concrete reset time (e.g.
      // the statusLine's rate-limit JSON) — omit it if you can't; a
      // percentage without a known reset time is still worth reporting.
      resetsAt: z.string().datetime({ offset: true }).optional()
        .describe('ISO 8601 timestamp this percentage resets at, if known (e.g. from the status line).'),
    },
  },
  async ({ usagePercent, note, resetsAt }) => {
    if (!API_KEY) {
      return {
        isError: true,
        content: [{ type: 'text', text: 'BUG_REPORT_API_KEY is not set on this MCP server — see README.md.' }],
      };
    }

    let res;
    try {
      res = await fetch(`${BASE_URL}/api/admin/claude-usage`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-API-Key': API_KEY },
        body: JSON.stringify({ usagePercent, note, resetsAt }),
      });
    } catch (err) {
      return {
        isError: true,
        content: [{ type: 'text', text: `Could not reach ${BASE_URL}: ${err instanceof Error ? err.message : String(err)}` }],
      };
    }

    const body = await res.json().catch(() => null);

    if (!res.ok) {
      const message = body?.message || body?.error || `HTTP ${res.status}`;
      return { isError: true, content: [{ type: 'text', text: `Failed to report Claude usage: ${message}` }] };
    }

    const status = body?.data;
    return {
      content: [{
        type: 'text',
        text: status
          ? `Reported ${status.usagePercent}% usage for ${status.email}.`
          : 'Usage reported.',
      }],
    };
  }
);

server.registerTool(
  'report_claude_token_usage',
  {
    title: 'Report Claude token usage breakdown',
    description:
      "Scans this developer's own local Claude Code transcripts " +
      '(~/.claude/projects/**/*.jsonl AND their nested .../subagents/*.jsonl — this MCP server runs on ' +
      'the same machine, so it can read them directly) and reports a real token/model/context breakdown: ' +
      'total tokens (including subagent spend, not just the main thread), a per-model split (so it can ' +
      "actually be priced), how full the most recently active session's context window currently is, and " +
      'how many sessions used web search or spawned a subagent. Unlike ' +
      "report_claude_usage's percentage, nothing here is self-attested — every number is read off real " +
      'local files, so call this freely; it never needs to ask a human for anything. ' +
      "The other bug-resolution tools already call this automatically (fire-and-forget) as a side effect, " +
      "so you usually don't need to call it directly — this exists for an explicit, on-demand check, and " +
      'lets you ask for a window other than the default 7 days.',
    inputSchema: {
      days: z.number().int().min(1).max(90).optional()
        .describe('How many days back to scan (default 7). The reported periodStart/periodEnd always say exactly what was scanned.'),
    },
  },
  async ({ days }) => {
    if (!API_KEY) {
      return {
        isError: true,
        content: [{ type: 'text', text: 'BUG_REPORT_API_KEY is not set on this MCP server — see README.md.' }],
      };
    }

    const breakdown = await computeWeeklyTokenBreakdown(days ?? 7);
    if (breakdown.sessionCount === 0) {
      return {
        content: [{ type: 'text', text: `No Claude Code transcripts found in the last ${days ?? 7} day(s) under ~/.claude/projects — nothing to report.` }],
      };
    }

    let res;
    try {
      res = await fetch(`${BASE_URL}/api/admin/claude-usage/token-breakdown`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-API-Key': API_KEY },
        body: JSON.stringify(breakdown),
      });
    } catch (err) {
      return {
        isError: true,
        content: [{ type: 'text', text: `Could not reach ${BASE_URL}: ${err instanceof Error ? err.message : String(err)}` }],
      };
    }

    const body = await res.json().catch(() => null);

    if (!res.ok) {
      const message = body?.message || body?.error || `HTTP ${res.status}`;
      return { isError: true, content: [{ type: 'text', text: `Failed to report Claude token usage: ${message}` }] };
    }

    const modelLines = Object.entries(breakdown.byModel)
      .map(([model, t]) => `  - ${model}: ${formatTokenCount(t.inputTokens + t.outputTokens + t.cacheCreationTokens)} new (+${formatTokenCount(t.cacheReadTokens)} cache-read)`)
      .join('\n');
    const contextLine = breakdown.currentContextTokens != null
      ? `Current context (most recently active session, ${breakdown.currentContextModel}): ` +
        `${formatTokenCount(breakdown.currentContextTokens)} / ${formatTokenCount(breakdown.currentContextLimit)} ` +
        `(${Math.round((breakdown.currentContextTokens / breakdown.currentContextLimit) * 100)}%)`
      : 'Current context: unknown (no in-window session found)';

    return {
      content: [{
        type: 'text',
        text: `Reported ${formatTokenCount(newTokenCount(breakdown))} new tokens ` +
          `(plus ${formatTokenCount(breakdown.cacheReadTokens)} discounted cache-read re-reads) ` +
          `across ${breakdown.sessionCount} session(s) over the last ${days ?? 7} day(s) ` +
          `(${breakdown.sessionsWithWebSearch} used web search, ${breakdown.sessionsWithSubagents} used subagents, ` +
          `${formatTokenCount(breakdown.subagentTokens)} of the new-token total came from subagents).\n` +
          `By model:\n${modelLines}\n${contextLine}`,
      }],
    };
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
