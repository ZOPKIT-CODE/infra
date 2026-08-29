#!/usr/bin/env node
// bug-resolution MCP server — four tools wrapping the bug-reports resolution
// API (see backend/src/features/bug-reports/README.md) so a developer's
// Claude Code / Cursor session can work a bug report end to end as native
// tool calls instead of hand-rolling curl commands:
//   - fetch_bug_context: GET /api/admin/bug-reports/context/:id — pulls the
//     full report (title/description/severity/status/comments) plus every
//     inline screenshot as real image content.
//   - submit_bug_resolution: POST /api/admin/bug-reports/resolution/:id —
//     writes back the fix as a Markdown resolution and marks it resolved.
//   - fetch_assigned_bugs: GET /api/admin/bug-reports/assigned — "what's on
//     my plate", always the API key owner's own assigned reports.
//   - create_bug_report: POST /api/admin/bug-reports/report — file a new bug
//     the tool found, optionally self-assigning it.
// Thin wrapper: all the actual logic (auth, scoping, the DB writes) lives
// server-side; this just forwards the HTTP calls the README documents.
//
// Setup: see README.md in this directory.

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';

const API_KEY = process.env.BUG_REPORT_API_KEY;
const BASE_URL = (process.env.BUG_REPORT_API_BASE_URL || 'https://api.zopkit.com').replace(/\/$/, '');

if (!API_KEY) {
  console.error('[bug-resolution-mcp] BUG_REPORT_API_KEY is not set — every call will fail. ' +
    'Generate one from the company-admin panel (Bug Reports → API Keys) and set it when registering this server.');
}

const server = new McpServer({ name: 'zopkit-bug-resolution', version: '1.2.0' });

const BUG_SEVERITIES = ['low', 'medium', 'high', 'critical'];
const BUG_STATUSES = ['open', 'in_progress', 'blocked', 'further_discussion', 'resolved'];
const BUG_PROJECTS = ['wrapper', 'crm', 'fa', 'accounting', 'academy', 'itsm', 'studio'];

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

server.registerTool(
  'submit_bug_resolution',
  {
    title: 'Submit bug resolution',
    description:
      "Report how a Zopkit bug report was fixed. Sets the report's resolution notes to the given " +
      "Markdown writeup and moves its status straight to 'resolved'. Use the bug report's id " +
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
      'opening the admin panel. Screenshots come back as image content alongside the text summary.',
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

    return { content };
  }
);

server.registerTool(
  'fetch_assigned_bugs',
  {
    title: 'Fetch bugs assigned to me',
    description:
      "List Zopkit bug reports currently assigned to this API key's owner — \"what's on my plate\". " +
      'Always the key owner\'s own assigned reports, never anyone else\'s, regardless of what the key ' +
      'can otherwise see. Optionally filter by status.',
    inputSchema: {
      status: z.enum(BUG_STATUSES).optional().describe('Only return reports in this status.'),
    },
  },
  async ({ status }) => {
    if (!API_KEY) {
      return {
        isError: true,
        content: [{ type: 'text', text: 'BUG_REPORT_API_KEY is not set on this MCP server — see README.md.' }],
      };
    }

    const url = new URL(`${BASE_URL}/api/admin/bug-reports/assigned`);
    if (status) url.searchParams.set('status', status);

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
    if (reports.length === 0) {
      return { content: [{ type: 'text', text: 'No bug reports currently assigned to you.' }] };
    }

    const summary = reports
      .map((r) => `- [${r.severity}/${r.status}] ${r.title} (id: ${r.id})${r.project ? ` — project: ${r.project}` : ''}`)
      .join('\n');

    return { content: [{ type: 'text', text: `${reports.length} assigned report(s):\n${summary}` }] };
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

const transport = new StdioServerTransport();
await server.connect(transport);
