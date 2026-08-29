#!/usr/bin/env node
// bug-resolution MCP server — two tools wrapping the bug-reports resolution
// API (see backend/src/features/bug-reports/README.md) so a developer's
// Claude Code / Cursor session can work a bug report end to end as native
// tool calls instead of hand-rolling curl commands:
//   - fetch_bug_context: GET /api/admin/bug-reports/context/:id — pulls the
//     full report (title/description/severity/status/comments) plus every
//     inline screenshot as real image content.
//   - submit_bug_resolution: POST /api/admin/bug-reports/resolution/:id —
//     writes back the fix as a Markdown resolution and marks it resolved.
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

const server = new McpServer({ name: 'zopkit-bug-resolution', version: '1.1.0' });

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

const transport = new StdioServerTransport();
await server.connect(transport);
