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
//     Code transcripts (~/.claude/projects/**/*.jsonl — this server runs on
//     the same machine) for a 7-day token/web-search/subagent breakdown. The
//     other four bug-resolution tools above also trigger this automatically
//     as a fire-and-forget side effect (see tryAutoReportTokenUsage) — "every
//     task done in the bug reporter" keeps this fresh with zero extra asks.
// Thin wrapper: all the actual logic (auth, scoping, the DB writes) lives
// server-side; this just forwards the HTTP calls the README documents.
//
// Setup: see README.md in this directory.

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const API_KEY = process.env.BUG_REPORT_API_KEY;
const BASE_URL = (process.env.BUG_REPORT_API_BASE_URL || 'https://api.zopkit.com').replace(/\/$/, '');

if (!API_KEY) {
  console.error('[bug-resolution-mcp] BUG_REPORT_API_KEY is not set — every call will fail. ' +
    'Generate one from the company-admin panel (Bug Reports → API Keys) and set it when registering this server.');
}

const server = new McpServer({ name: 'zopkit-bug-resolution', version: '1.6.0' });

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
      if (!entry.isFile() || !entry.name.endsWith('.jsonl')) continue;
      const filePath = join(dirPath, entry.name);
      try {
        if (statSync(filePath).mtimeMs >= sinceMs) files.push(filePath);
      } catch {
        // file vanished between readdir and stat — skip
      }
    }
  }
  return files;
}

/** One session's token totals + what it used — null if the file had nothing
 *  in range (e.g. mtime was recent but every logged message predates sinceMs). */
function scanTranscript(filePath, sinceMs) {
  let raw;
  try {
    raw = readFileSync(filePath, 'utf8');
  } catch {
    return null;
  }

  const seenMessageIds = new Set();
  let inputTokens = 0, outputTokens = 0, cacheCreationTokens = 0, cacheReadTokens = 0;
  let usedWebSearch = false, usedSubagents = false;
  let startedAt = null, cwd = null;

  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      continue; // truncated/partial last line — skip it, not the whole file
    }
    if (entry.type !== 'assistant' || !entry.message) continue;
    if (entry.timestamp && Date.parse(entry.timestamp) < sinceMs) continue;

    if (cwd === null && entry.cwd) cwd = entry.cwd;
    if (entry.timestamp && (!startedAt || entry.timestamp < startedAt)) startedAt = entry.timestamp;

    // Tool-use detection runs on every line, duplicates included — setting a
    // boolean true twice is harmless, unlike double-counting tokens below.
    if (Array.isArray(entry.message.content)) {
      for (const block of entry.message.content) {
        if (block?.type === 'tool_use' && SUBAGENT_TOOL_NAMES.has(block.name)) usedSubagents = true;
      }
    }

    const messageId = entry.message.id;
    if (messageId) {
      if (seenMessageIds.has(messageId)) continue;
      seenMessageIds.add(messageId);
    }

    const usage = entry.message.usage;
    if (!usage) continue;
    inputTokens += usage.input_tokens || 0;
    outputTokens += usage.output_tokens || 0;
    cacheCreationTokens += usage.cache_creation_input_tokens || 0;
    cacheReadTokens += usage.cache_read_input_tokens || 0;
    const serverTools = usage.server_tool_use;
    if (serverTools && ((serverTools.web_search_requests || 0) > 0 || (serverTools.web_fetch_requests || 0) > 0)) {
      usedWebSearch = true;
    }
  }

  const totalTokens = inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens;
  if (totalTokens === 0) return null;
  return { totalTokens, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, usedWebSearch, usedSubagents, startedAt, cwd };
}

/** Scans every local Claude Code transcript touched in the last `days` days
 *  and aggregates it into the shape reportClaudeTokenUsageSchema expects.
 *  Deliberately NOT scoped to this repo/project — the whole point is "how
 *  much Claude Code usage this week", same scope /usage itself reports. */
function computeWeeklyTokenBreakdown(days = 7) {
  const sinceMs = Date.now() - days * 24 * 60 * 60 * 1000;
  const sessions = listRecentTranscripts(sinceMs)
    .map((f) => scanTranscript(f, sinceMs))
    .filter((s) => s !== null);

  const totals = sessions.reduce(
    (acc, s) => ({
      inputTokens: acc.inputTokens + s.inputTokens,
      outputTokens: acc.outputTokens + s.outputTokens,
      cacheCreationTokens: acc.cacheCreationTokens + s.cacheCreationTokens,
      cacheReadTokens: acc.cacheReadTokens + s.cacheReadTokens,
    }),
    { inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0 }
  );

  const topSessions = [...sessions]
    .sort((a, b) => b.totalTokens - a.totalTokens)
    .slice(0, 5)
    .map((s) => ({
      totalTokens: s.totalTokens,
      startedAt: s.startedAt || new Date(sinceMs).toISOString(),
      cwd: s.cwd,
      usedWebSearch: s.usedWebSearch,
      usedSubagents: s.usedSubagents,
    }));

  return {
    periodStart: new Date(sinceMs).toISOString(),
    periodEnd: new Date().toISOString(),
    ...totals,
    sessionCount: sessions.length,
    sessionsWithWebSearch: sessions.filter((s) => s.usedWebSearch).length,
    sessionsWithSubagents: sessions.filter((s) => s.usedSubagents).length,
    topSessions,
  };
}

/** "585k" / "2.3M" / "1.1B" — raw token counts in a long session routinely
 *  reach the hundreds of millions (every turn re-pays for its whole cached
 *  context, so cache-read alone compounds fast), so a plain toLocaleString()
 *  reads as an alarming wall of digits. Still real numbers — just formatted
 *  for a human skimming a report, not a ledger. */
function formatTokenCount(n) {
  if (n >= 1e9) return `${(n / 1e9).toFixed(1)}B`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(0)}k`;
  return String(n);
}

/** input + output + cache-WRITE tokens — genuinely new content processed
 *  this period. Deliberately excludes cache-READ: that's a heavily-discounted
 *  re-read of context already paid for once, and in a long session it
 *  dwarfs everything else by 10-100x, so folding it into one headline
 *  number would make "new work this week" unreadable. Still reported
 *  separately in full (see the schema) — just not what ranks/headlines. */
function newTokenCount(breakdown) {
  return breakdown.inputTokens + breakdown.outputTokens + breakdown.cacheCreationTokens;
}

/** Fire-and-forget: scan + POST the breakdown, swallowing any failure (a
 *  missing ~/.claude/projects dir, a network blip, whatever) — this must
 *  never fail or slow down the tool call it's piggybacking on. Returns a
 *  short status string for an optional footer, or null if it didn't run. */
async function tryAutoReportTokenUsage() {
  if (!API_KEY) return null;
  try {
    const breakdown = computeWeeklyTokenBreakdown();
    if (breakdown.sessionCount === 0) return null;
    const res = await fetch(`${BASE_URL}/api/admin/claude-usage/token-breakdown`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-API-Key': API_KEY },
      body: JSON.stringify(breakdown),
    });
    if (!res.ok) return null;
    return `${formatTokenCount(newTokenCount(breakdown))} new tokens across ${breakdown.sessionCount} session(s) this week`;
  } catch {
    return null; // never let this break the real tool call
  }
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
    const usageNote = await tryAutoReportTokenUsage();
    return {
      content: [{
        type: 'text',
        text: (report
          ? `Resolution submitted. "${report.title}" is now ${report.status}.`
          : 'Resolution submitted.') + (usageNote ? `\n\n(Also updated your Claude token usage: ${usageNote}.)` : ''),
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

    const usageNote = await tryAutoReportTokenUsage();
    if (usageNote) content.push({ type: 'text', text: `(Also updated your Claude token usage: ${usageNote}.)` });

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

    const usageNote = await tryAutoReportTokenUsage();
    return {
      content: [{
        type: 'text',
        text: `${header}\n${summary}` + (usageNote ? `\n\n(Also updated your Claude token usage: ${usageNote}.)` : ''),
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
    const usageNote = await tryAutoReportTokenUsage();
    return {
      content: [{
        type: 'text',
        text: (report
          ? `Bug report created: "${report.title}" (id: ${report.id}).`
          : 'Bug report created.') + (usageNote ? `\n\n(Also updated your Claude token usage: ${usageNote}.)` : ''),
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
    },
  },
  async ({ usagePercent, note }) => {
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
        body: JSON.stringify({ usagePercent, note }),
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
      '(~/.claude/projects/**/*.jsonl — this MCP server runs on the same machine, so it can read them ' +
      'directly) and reports a real token-usage breakdown for the last 7 days: total tokens, how many ' +
      'sessions, and how many of those sessions used web search or spawned a subagent. Unlike ' +
      "report_claude_usage's percentage, nothing here is self-attested — every number is read off real " +
      'local files, so call this freely with no arguments; it never needs to ask a human for anything. ' +
      "The other bug-resolution tools already call this automatically as a side effect, so you usually " +
      "don't need to call it directly — this exists for an explicit, on-demand check.",
    inputSchema: {},
  },
  async () => {
    if (!API_KEY) {
      return {
        isError: true,
        content: [{ type: 'text', text: 'BUG_REPORT_API_KEY is not set on this MCP server — see README.md.' }],
      };
    }

    const breakdown = computeWeeklyTokenBreakdown();
    if (breakdown.sessionCount === 0) {
      return {
        content: [{ type: 'text', text: 'No Claude Code transcripts found in the last 7 days under ~/.claude/projects — nothing to report.' }],
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

    return {
      content: [{
        type: 'text',
        text: `Reported ${formatTokenCount(newTokenCount(breakdown))} new tokens ` +
          `(plus ${formatTokenCount(breakdown.cacheReadTokens)} discounted cache-read re-reads) ` +
          `across ${breakdown.sessionCount} session(s) this week ` +
          `(${breakdown.sessionsWithWebSearch} used web search, ${breakdown.sessionsWithSubagents} used subagents).`,
      }],
    };
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
