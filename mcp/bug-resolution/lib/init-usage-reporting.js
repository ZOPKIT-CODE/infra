// `--init-usage-reporting` — wire the status line and the two hooks into
// Claude Code, and write the credentials they need.
//
// Done as an explicit opt-in command rather than silently on install: this
// edits the developer's own ~/.claude/settings.json and turns on reporting
// to a shared team panel. Both deserve a deliberate action.
//
// It is conservative about what it touches:
//  - never overwrites an existing statusLine (prints what to do instead),
//  - appends its hooks rather than replacing the arrays,
//  - is idempotent: running it twice changes nothing the second time,
//  - backs the file up before writing.

import { readFileSync, writeFileSync, copyFileSync, existsSync, mkdirSync, chmodSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { CONFIG_PATH } from './zopkit-config.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const BIN = join(HERE, '..', 'bin');

const SETTINGS_PATH = join(homedir(), '.claude', 'settings.json');

const STATUSLINE_CMD = `node ${join(BIN, 'zopkit-statusline.js')}`;
const MARKER_CMD = `node ${join(BIN, 'zopkit-task-marker.js')}`;
const SESSION_END_CMD = `node ${join(BIN, 'zopkit-session-end.js')}`;

// The matcher the task marker relies on. Narrow on purpose — a broader one
// would spawn a node process on every tool call in the session.
const MARKER_MATCHER = 'mcp__bug-resolution__(fetch_bug_context|submit_bug_resolution)';

function readJson(path, fallback) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return fallback;
  }
}

/** Already present? Compare on the command string, so re-running after an
 *  upgrade (same path) is a no-op rather than a duplicate. */
function hasHook(entries, command) {
  return (entries ?? []).some((e) => (e.hooks ?? []).some((h) => h.command === command));
}

export function initUsageReporting({ apiKey, baseUrl, shareSessionName = false } = {}) {
  const log = (...a) => console.error(...a);

  // ── 1. credentials ──────────────────────────────────────────────────
  const key = apiKey || process.env.BUG_REPORT_API_KEY;
  if (!key) {
    log('No API key.');
    log('  Generate one in the company-admin panel (Bug Reports → API Keys), then:');
    log('    npx zopkit-bug-resolution-mcp --init-usage-reporting --api-key bugres_…');
    log('  …or export BUG_REPORT_API_KEY and re-run.');
    return 1;
  }

  mkdirSync(dirname(CONFIG_PATH), { recursive: true });
  const existingCfg = readJson(CONFIG_PATH, {});
  writeFileSync(
    CONFIG_PATH,
    JSON.stringify(
      {
        ...existingCfg,
        apiKey: key,
        baseUrl: baseUrl || existingCfg.baseUrl || 'https://api.zopkit.com',
        // Opt-in: the session title describes what you are working on, and
        // it lands on a panel the whole staff can read.
        shareSessionName: shareSessionName || existingCfg.shareSessionName || false,
      },
      null,
      2
    ) + '\n',
    // The key is a credential; keep it off other accounts on the machine.
    { mode: 0o600 }
  );
  log(`✓ credentials → ${CONFIG_PATH}`);

  for (const f of ['zopkit-statusline.js', 'zopkit-task-marker.js', 'zopkit-session-end.js']) {
    try {
      chmodSync(join(BIN, f), 0o755);
    } catch {
      // bundled read-only (npx cache) — `node <path>` still works, and that
      // is the form written into settings.json anyway.
    }
  }

  // ── 2. settings.json ────────────────────────────────────────────────
  const settings = readJson(SETTINGS_PATH, {});
  if (existsSync(SETTINGS_PATH)) {
    copyFileSync(SETTINGS_PATH, `${SETTINGS_PATH}.zopkit-backup`);
    log(`✓ backed up → ${SETTINGS_PATH}.zopkit-backup`);
  }

  let changed = false;

  if (!settings.statusLine) {
    settings.statusLine = { type: 'command', command: STATUSLINE_CMD };
    changed = true;
    log('✓ statusLine configured');
  } else if (settings.statusLine.command === STATUSLINE_CMD) {
    log('· statusLine already configured');
  } else {
    // Never clobber: a custom status line is work the developer did, and
    // theirs is probably nicer than ours.
    log('! statusLine already set to something else — left alone.');
    log('  To keep yours AND report usage, call ours from inside it (it reads stdin and');
    log('  writes one line), or pipe the payload through:');
    log(`    ${STATUSLINE_CMD}`);
  }

  settings.hooks ??= {};

  settings.hooks.PostToolUse ??= [];
  if (!hasHook(settings.hooks.PostToolUse, MARKER_CMD)) {
    settings.hooks.PostToolUse.push({
      matcher: MARKER_MATCHER,
      hooks: [{ type: 'command', command: MARKER_CMD }],
    });
    changed = true;
    log('✓ PostToolUse task-marker hook added');
  } else {
    log('· task-marker hook already present');
  }

  settings.hooks.SessionEnd ??= [];
  if (!hasHook(settings.hooks.SessionEnd, SESSION_END_CMD)) {
    settings.hooks.SessionEnd.push({ hooks: [{ type: 'command', command: SESSION_END_CMD }] });
    changed = true;
    log('✓ SessionEnd hook added');
  } else {
    log('· SessionEnd hook already present');
  }

  if (changed) {
    writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2) + '\n');
    log(`✓ wrote ${SETTINGS_PATH}`);
  }

  log('');
  log('Restart Claude Code for the status line and hooks to take effect.');
  log('');
  log('Then, to attribute bugs you already fixed on this machine:');
  log('  npx zopkit-bug-resolution-mcp --backfill-tasks --dry-run');
  log('');
  log('Note: the account-level percentages come from rate_limits in the status-line');
  log('payload. If your Claude Code predates that field the panel still shows context');
  log('and per-session cost; it just leaves the 5h/7d bars empty. Check with:');
  log('  npx zopkit-bug-resolution-mcp --check-statusline');
  return 0;
}

/**
 * `--check-statusline` — print exactly which of the fields this feature
 * depends on the local Claude Code actually emits.
 *
 * Worth having as a command rather than a docs note: the fields arrived in
 * different releases, so "is my client new enough" has a different answer
 * per field, and guessing wrong looks identical to a broken install.
 */
export async function checkStatusline(payloadText) {
  let p;
  try {
    p = JSON.parse(payloadText);
  } catch {
    console.error('Pipe a status-line payload in. Easiest way to capture one:');
    console.error('');
    console.error('  cd /tmp && claude --settings \'{"statusLine":{"type":"command",' +
      '"command":"tee /tmp/zopkit-sl.json"}}\'');
    console.error('  # let it render once, exit, then:');
    console.error('  npx zopkit-bug-resolution-mcp --check-statusline < /tmp/zopkit-sl.json');
    return 1;
  }

  const checks = [
    ['session_id', p.session_id, 'required — identifies the session'],
    ['context_window.used_percentage', p.context_window?.used_percentage, 'the per-session context bar'],
    ['context_window.context_window_size', p.context_window?.context_window_size, 'the bar\'s denominator'],
    ['cost.total_cost_usd', p.cost?.total_cost_usd, 'per-session cost'],
    ['rate_limits.five_hour.used_percentage', p.rate_limits?.five_hour?.used_percentage, 'the 5-hour bar'],
    ['rate_limits.seven_day.used_percentage', p.rate_limits?.seven_day?.used_percentage, 'the weekly % — replaces self-reporting'],
    ['rate_limits.spend_limit.used_usd', p.rate_limits?.spend_limit?.used_usd, 'gateway spend (needs CC >= 2.1.284)'],
  ];

  console.error(`Claude Code ${p.version ?? '(version not reported)'}\n`);
  let missing = 0;
  for (const [field, value, why] of checks) {
    const present = value !== undefined && value !== null;
    if (!present) missing += 1;
    console.error(`  ${present ? '✓' : '✗'} ${field.padEnd(40)} ${present ? '' : `— absent; ${why} will be empty`}`);
  }
  console.error('');
  console.error(missing === 0 ? 'Everything this feature uses is available.' : `${missing} field(s) absent — upgrade Claude Code to fill them in.`);
  return 0;
}
