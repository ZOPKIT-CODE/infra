#!/usr/bin/env node
// bug-resolution MCP server — a single tool wrapping
// POST /api/admin/bug-reports/resolution/:id (see backend/src/features/
// bug-reports/README.md) so a developer's Claude Code / Cursor session can
// report back how it fixed a bug as a native tool call instead of hand-
// rolling a curl command. Thin wrapper: all the actual logic (auth, the
// resolutionNotes/status write) lives server-side: this just forwards
// {bugReportId, markdown} as the HTTP call the README already documents.
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

const server = new McpServer({ name: 'zopkit-bug-resolution', version: '1.0.0' });

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

const transport = new StdioServerTransport();
await server.connect(transport);
