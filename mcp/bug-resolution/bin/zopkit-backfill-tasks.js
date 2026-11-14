#!/usr/bin/env node
// One-shot historical backfill of per-task token attribution.
//
// The PostToolUse marker hook only knows about tasks worked AFTER it is
// installed. But the markers it relies on — fetch_bug_context and
// submit_bug_resolution tool calls — are already sitting in every
// transcript ever written, so the same windows can be reconstructed
// retroactively.
//
// Reconstruction is strictly weaker than live markers, and says so: every
// window it writes is tagged attributionSource 'backfill', which the panel
// renders differently from a measured one. Three known imprecisions:
//
//  - A window includes everything the developer did inside it. If they
//    wandered off to an unrelated file, it is still charged to the bug.
//  - An un-submitted window has no natural end, so it is closed at the
//    first gap longer than IDLE_GAP_MS. Without that, one historical
//    window ran 738 minutes and swallowed the rest of the session.
//  - Only transcripts on THIS machine are visible. Work done elsewhere, or
//    through the panel rather than the MCP tool, is simply absent — which
//    is why coverage is reported at the end rather than left to assume.
//
// Usage:
//   npx zopkit-bug-resolution-mcp --backfill-tasks [--days 90] [--dry-run]

import { createReadStream, readdirSync, statSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { join, basename } from 'node:path';
import { homedir } from 'node:os';
import { loadConfig, post } from '../lib/zopkit-config.js';

const PROJECTS_DIR = join(homedir(), '.claude', 'projects');
const START_TOOL = 'mcp__bug-resolution__fetch_bug_context';
const END_TOOL = 'mcp__bug-resolution__submit_bug_resolution';
const SYNTHETIC_MODEL = '<synthetic>';

// An un-submitted window ends at the first gap longer than this. Picked to
// sit above a long single turn (a big refactor, a slow test run) and below
// a meal.
const IDLE_GAP_MS = 30 * 60 * 1000;

function emptyTotals() {
  return { inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0 };
}

function addUsage(byModel, model, usage) {
  const t = (byModel[model] ??= emptyTotals());
  t.inputTokens += usage.input_tokens || 0;
  t.outputTokens += usage.output_tokens || 0;
  t.cacheCreationTokens += usage.cache_creation_input_tokens || 0;
  t.cacheReadTokens += usage.cache_read_input_tokens || 0;
}

async function readEntries(filePath) {
  const out = [];
  let stream;
  try {
    stream = createReadStream(filePath, { encoding: 'utf8' });
  } catch {
    return out;
  }
  const rl = createInterface({ input: stream, crlfDelay: Infinity });
  try {
    for await (const line of rl) {
      if (!line.trim()) continue;
      try {
        out.push(JSON.parse(line));
      } catch {
        // partial final line
      }
    }
  } finally {
    rl.close();
    stream.destroy();
  }
  return out;
}

function toolUses(entry) {
  const c = entry?.message?.content;
  return Array.isArray(c) ? c.filter((b) => b?.type === 'tool_use') : [];
}

/** Reconstruct every task window in one session transcript. */
async function windowsForSession(filePath, sinceMs) {
  const entries = await readEntries(filePath);
  if (entries.length === 0) return [];

  const sessionId = basename(filePath, '.jsonl');
  const windows = [];
  let current = null;
  let seen = new Set();
  let lastTs = null;

  const close = () => {
    if (current && current.turns > 0) windows.push(current);
    current = null;
    seen = new Set();
  };

  const sorted = entries
    .filter((e) => e.timestamp)
    .sort((a, b) => (a.timestamp < b.timestamp ? -1 : a.timestamp > b.timestamp ? 1 : 0));

  for (const entry of sorted) {
    const ts = entry.timestamp;

    if (entry.type === 'system' && entry.subtype === 'turn_duration' && current) {
      current.activeMs = (current.activeMs ?? 0) + (entry.durationMs || 0);
      continue;
    }
    if (entry.type !== 'assistant' || !entry.message) continue;

    // An un-submitted window stops at the first long gap, rather than
    // running to the end of the session.
    if (current && !current.closed && lastTs && Date.parse(ts) - Date.parse(lastTs) > IDLE_GAP_MS) {
      close();
    }
    lastTs = ts;

    // Marker detection runs on every line, duplicates included — setting a
    // boundary twice is harmless, unlike double-counting tokens.
    for (const block of toolUses(entry)) {
      if (block.name === START_TOOL && block.input?.bugReportId) {
        close();
        current = {
          bugReportId: block.input.bugReportId,
          sessionId,
          startedAt: ts,
          endedAt: ts,
          byModel: {},
          turns: 0,
          subagentTurns: 0,
          activeMs: null,
          closed: false,
        };
      } else if (block.name === END_TOOL && current && block.input?.bugReportId === current.bugReportId) {
        current.closed = true;
      }
    }

    if (!current) continue;

    const messageId = entry.message.id;
    if (messageId) {
      if (seen.has(messageId)) continue;
      seen.add(messageId);
    }
    const usage = entry.message.usage;
    if (!usage) continue;
    const model = entry.message.model || 'unknown';
    if (model === SYNTHETIC_MODEL) continue;

    addUsage(current.byModel, model, usage);
    current.turns += 1;
    current.endedAt = ts;

    if (current.closed) close();
  }
  close();

  // Fold in subagent spend that falls inside a window. Subagent transcripts
  // carry the parent sessionId, so a timestamp range is enough to attribute
  // them — and omitting them undercounts a window that fanned out.
  const subDir = join(filePath.replace(/\.jsonl$/, ''), 'subagents');
  let subFiles = [];
  try {
    subFiles = readdirSync(subDir, { withFileTypes: true })
      .filter((e) => e.isFile() && e.name.endsWith('.jsonl'))
      .map((e) => join(subDir, e.name));
  } catch {
    // none
  }
  for (const sub of subFiles) {
    const subEntries = await readEntries(sub);
    for (const w of windows) {
      const subSeen = new Set();
      for (const entry of subEntries) {
        if (entry.type !== 'assistant' || !entry.message || !entry.timestamp) continue;
        if (entry.timestamp < w.startedAt || entry.timestamp > w.endedAt) continue;
        const id = entry.message.id;
        if (id) {
          if (subSeen.has(id)) continue;
          subSeen.add(id);
        }
        const usage = entry.message.usage;
        if (!usage) continue;
        const model = entry.message.model || 'unknown';
        if (model === SYNTHETIC_MODEL) continue;
        addUsage(w.byModel, model, usage);
        w.subagentTurns += 1;
      }
    }
  }

  return windows.filter((w) => Date.parse(w.endedAt) >= sinceMs);
}

function listSessionTranscripts() {
  const files = [];
  let dirs;
  try {
    dirs = readdirSync(PROJECTS_DIR, { withFileTypes: true });
  } catch {
    return files;
  }
  for (const d of dirs) {
    if (!d.isDirectory()) continue;
    const dirPath = join(PROJECTS_DIR, d.name);
    let entries;
    try {
      entries = readdirSync(dirPath, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of entries) {
      if (e.isFile() && e.name.endsWith('.jsonl')) files.push(join(dirPath, e.name));
    }
  }
  return files;
}

function fmt(n) {
  if (n >= 1e9) return `${(n / 1e9).toFixed(1)}B`;
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)}k`;
  return String(n);
}

export async function runBackfill({ days = 90, dryRun = false } = {}) {
  const cfg = loadConfig();
  if (!cfg && !dryRun) {
    console.error('No API key — run `npx zopkit-bug-resolution-mcp --init-usage-reporting` first.');
    process.exitCode = 1;
    return;
  }

  const sinceMs = Date.now() - days * 24 * 60 * 60 * 1000;
  const transcripts = listSessionTranscripts();
  console.error(`Scanning ${transcripts.length} transcripts for task markers (last ${days} days)…`);

  const all = [];
  for (const file of transcripts) {
    try {
      // Cheap pre-filter: most transcripts never touched a bug tool.
      if (statSync(file).size === 0) continue;
      const found = await windowsForSession(file, sinceMs);
      all.push(...found);
    } catch {
      // unreadable transcript — skip, don't abort the run
    }
  }

  if (all.length === 0) {
    console.error('No task windows found. Nothing to backfill.');
    return;
  }

  const bugs = new Set(all.map((w) => w.bugReportId));
  console.error(`\n${all.length} windows across ${bugs.size} bugs:\n`);
  for (const w of all.sort((a, b) => (a.startedAt < b.startedAt ? 1 : -1)).slice(0, 20)) {
    const newTokens = Object.values(w.byModel).reduce(
      (s, t) => s + t.inputTokens + t.outputTokens + t.cacheCreationTokens,
      0
    );
    const cacheRead = Object.values(w.byModel).reduce((s, t) => s + t.cacheReadTokens, 0);
    console.error(
      `  ${w.bugReportId.slice(0, 8)}  ${fmt(newTokens).padStart(8)} new  ${fmt(cacheRead).padStart(8)} cr  ` +
        `${String(w.turns).padStart(3)} turns  ${w.closed ? 'closed' : 'open  '}  ` +
        `${w.activeMs === null ? ' —' : `${Math.round(w.activeMs / 60000)}m`}`
    );
  }
  if (all.length > 20) console.error(`  … and ${all.length - 20} more`);

  if (dryRun) {
    console.error('\n--dry-run: nothing posted.');
    return;
  }

  let ok = 0;
  let failed = 0;
  for (const w of all) {
    const res = await post('/api/admin/bug-reports/task-window', {
      bugReportId: w.bugReportId,
      sessionId: w.sessionId,
      startedAt: w.startedAt,
      // An un-submitted window has no real end; recording the last turn as
      // one would claim the task finished there. It did not.
      endedAt: w.closed ? w.endedAt : null,
      activeMs: w.activeMs,
      turns: w.turns,
      subagentTurns: w.subagentTurns,
      byModel: w.byModel,
      attributionSource: 'backfill',
    });
    if (res?.success) ok += 1;
    else failed += 1;
  }

  console.error(`\nPosted ${ok} windows${failed ? `, ${failed} failed` : ''}.`);
  // Coverage, stated rather than assumed: a roll-up that silently omits
  // most bugs reads as "those fixes were cheap".
  console.error(
    `Coverage: ${bugs.size} bugs have attribution from this machine. Bugs worked through the ` +
      'panel, on another machine, or without fetch_bug_context remain unattributed by design.'
  );
}
