// Cumulative token accounting for ONE Claude Code session.
//
// index.js's computeWeeklyTokenBreakdown answers "how much did this
// developer spend this week", scanning every transcript in a time window.
// This answers a different question — "how much has THIS session spent so
// far, in total" — which is what task attribution is built on: the marker
// hook reads this at each boundary and the server subtracts, so the delta
// between fetch_bug_context and submit_bug_resolution is the bug's real cost.
//
// Deliberately NOT time-windowed. A window boundary inside a session would
// make the two readings incomparable, and the subtraction is what makes the
// time filter unnecessary anyway.

import { createReadStream, readdirSync, statSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { join, dirname, basename } from 'node:path';

/** Models Claude Code logs for its own synthetic messages (rate-limit
 *  notices, interrupts). They carry a zero usage block and no real spend. */
const SYNTHETIC_MODEL = '<synthetic>';

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

/**
 * Subagent transcripts for a session live in a nested directory a flat
 * listing never finds: …/<projectDir>/<sessionId>/subagents/*.jsonl. Their
 * spend is real and belongs to whatever task was running at the time, so a
 * task window that ignored them would undercount — sometimes by a third.
 */
function subagentFiles(transcriptPath) {
  const dir = join(dirname(transcriptPath), basename(transcriptPath, '.jsonl'), 'subagents');
  try {
    return readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isFile() && e.name.endsWith('.jsonl'))
      .map((e) => join(dir, e.name));
  } catch {
    return []; // no subagents for this session — the common case
  }
}

/**
 * Stream one transcript, folding its assistant turns into `acc`.
 *
 * Streams line-by-line rather than readFileSync+split: a long session's
 * transcript runs to hundreds of MB, and this is called from a hook on the
 * critical path of a tool call.
 */
async function foldTranscript(filePath, acc, { isSubagent }) {
  let stream;
  try {
    stream = createReadStream(filePath, { encoding: 'utf8' });
  } catch {
    return;
  }
  const rl = createInterface({ input: stream, crlfDelay: Infinity });
  try {
    for await (const line of rl) {
      if (!line.trim()) continue;
      let entry;
      try {
        entry = JSON.parse(line);
      } catch {
        continue; // a partially-flushed last line, not a reason to abandon the file
      }

      // Claude Code's own measure of time actually spent on a turn. Summed
      // instead of using wall-clock, which measures when the developer went
      // to lunch: one historical window read as 738 minutes of "work" that
      // was really 36. Main thread only — a subagent's duration overlaps
      // its parent's and would double-count.
      if (!isSubagent && entry.type === 'system' && entry.subtype === 'turn_duration') {
        acc.activeMs = (acc.activeMs ?? 0) + (entry.durationMs || 0);
        continue;
      }

      if (entry.type !== 'assistant' || !entry.message) continue;

      // Streaming writes the same final usage numbers 2-3x per real
      // response (once per content-block flush), so totals would be
      // inflated 2-3x without this.
      const messageId = entry.message.id;
      if (messageId) {
        if (acc._seen.has(messageId)) continue;
        acc._seen.add(messageId);
      }

      const usage = entry.message.usage;
      if (!usage) continue;
      const model = entry.message.model || 'unknown';
      if (model === SYNTHETIC_MODEL) continue;

      addUsage(acc.byModel, model, usage);
      if (isSubagent) acc.subagentTurns += 1;
      else acc.turns += 1;
    }
  } finally {
    rl.close();
    stream.destroy();
  }
}

/**
 * Everything this session has spent so far.
 *
 * Subagent spend is folded INTO byModel (so the totals are complete) and
 * also counted separately as subagentTurns, matching the convention the
 * weekly breakdown already uses.
 *
 * activeMs stays null when the transcript has no turn_duration records at
 * all — older Claude Code versions don't write them, and "unknown" must not
 * collapse into "zero minutes of work".
 */
export async function scanSessionCumulative(transcriptPath) {
  const acc = {
    byModel: {},
    turns: 0,
    subagentTurns: 0,
    activeMs: null,
    _seen: new Set(),
  };
  try {
    statSync(transcriptPath);
  } catch {
    return { byModel: {}, turns: 0, subagentTurns: 0, activeMs: null };
  }
  await foldTranscript(transcriptPath, acc, { isSubagent: false });
  for (const sub of subagentFiles(transcriptPath)) {
    await foldTranscript(sub, acc, { isSubagent: true });
  }
  return {
    byModel: acc.byModel,
    turns: acc.turns,
    subagentTurns: acc.subagentTurns,
    activeMs: acc.activeMs,
  };
}

/** Round-trip-safe empty reading, for a session whose transcript cannot be
 *  read at all (the marker still records a window; it just measures zero). */
export const EMPTY_CUMULATIVE = { byModel: {}, turns: 0, subagentTurns: 0, activeMs: null };
