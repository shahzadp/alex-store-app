#!/usr/bin/env node
/**
 * Change the catalog and ship it, in one command.
 *
 * Before this existed, publishing a new catalog meant running four separate
 * commands across two repositories, and missing one of them produced a failure
 * that was hard to read:
 *
 *   node scripts/regen-catalog-json.mjs      # catalog.sql -> catalog.json (with vectors)
 *   node scripts/check-vectors-agree.mjs     # prove the two agree
 *   node scripts/bump-site-version.mjs       # cache-buster + rebuild the HTML
 *   cd ../Store && git commit && git push    # publish
 *
 * Skip the cache-buster and the site serves a stale copy to everyone for as long
 * as their browser caches it — the app is fine, the website looks broken. Skip
 * check-vectors-agree and catalog.json can disagree with catalog.sql, which is
 * the failure MEMORY.md spends most of its length on.
 *
 * # What the app needs, and what it does not
 *
 * The app fetches catalog.json on every launch and falls back to a cached copy,
 * so a published change reaches everyone who already has the app installed —
 * no app update, no re-release. The model weights are compiled into the
 * binary, but the VECTORS are not; they ship inside catalog.json, which is why
 * adding a product needs nothing but this script.
 *
 * There is one thing that DOES need a new build: changing the model. If the
 * catalog is ever reindexed with a different encoder, `loadIndex` refuses to
 * search and says so. That is the one case where the app and the site must
 * move together — see MEMORY.md §3.
 *
 * Usage:
 *   node scripts/publish-catalog.mjs                  # regenerate, verify, push
 *   node scripts/publish-catalog.mjs --dry-run       # show every step, change nothing
 *   node scripts/publish-catalog.mjs --no-push       # stop before committing
 *   node scripts/publish-catalog.mjs --message "Add brass tray"
 */

import { spawnSync } from 'node:child_process';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const APP = path.resolve(HERE, '..');
const STORE = path.resolve(APP, '..', 'Store');

const DRY = process.argv.includes('--dry-run');
const NO_PUSH = process.argv.includes('--no-push');
const message = value('--message');

const LIVE_URL = 'https://shahzadp.github.io/store/catalog.json';

function value(flag) {
  const i = process.argv.indexOf(flag);
  return i === -1 ? null : process.argv[i + 1] ?? null;
}

let step = 0;
function heading(text) {
  step++;
  console.log(`\n[${step}] ${text}`);
}

function run(cmd, args, cwd = APP) {
  const shown = `${cmd} ${args.join(' ')}`;
  console.log(`    $ ${shown}`);
  if (DRY) {
    console.log('    (dry run, not executed)');
    return 0;
  }
  const res = spawnSync(cmd, args, {
    stdio: 'inherit',
    shell: process.platform === 'win32',
    cwd,
  });
  return res.status ?? 1;
}

function fail(why) {
  console.error(`\npublish-catalog: ${why}`);
  console.error('Nothing was pushed. Fix the problem and run this again.');
  process.exit(1);
}

function git(args) {
  const res = spawnSync('git', args, {
    cwd: STORE,
    encoding: 'utf8',
    shell: process.platform === 'win32',
  });
  return { status: res.status, stdout: res.stdout ?? '' };
}

// ── 0. Preflight ────────────────────────────────────────────────────────────

if (!fs.existsSync(path.join(STORE, 'catalog.sql'))) {
  fail(`cannot find ${STORE}\\catalog.sql. This script expects the site one directory up.`);
}
if (!fs.existsSync(path.join(STORE, 'vendor', 'sql-wasm.wasm'))) {
  fail(`${STORE}\\vendor\\sql-wasm.wasm is missing — the site's sql.js is needed to rebuild.`);
}

const before = fs.readFileSync(path.join(STORE, 'catalog.json'), 'utf8');
let beforeJson;
try {
  beforeJson = JSON.parse(before);
} catch {
  fail('catalog.json does not parse. Fix the site repo before publishing.');
}

heading('Current catalog');
console.log(`    ${beforeJson.products.length} products, ${beforeJson.collections.length} collections`);
console.log(`    generated ${beforeJson.generated_at}`);
console.log('    If this is not what you expect, edit catalog.sql first.');

// ── 1. Regenerate ───────────────────────────────────────────────────────────

heading('Rebuilding catalog.json from catalog.sql (and the vectors)');
if (run('node', ['scripts/regen-catalog-json.mjs']) !== 0) {
  fail('regeneration failed.');
}

heading('Checking catalog.json and catalog.sql agree');
if (run('node', ['scripts/check-vectors-agree.mjs']) !== 0) {
  fail('catalog.json and catalog.sql disagree. Nothing is safe to publish.');
}

// ── 2. What actually changed ────────────────────────────────────────────────
//
// Printed before anything is committed, because "one command" must not mean
// "one command that commits on your behalf without telling you".

const after = fs.readFileSync(path.join(STORE, 'catalog.json'), 'utf8');

let afterJson;
try {
  afterJson = JSON.parse(after);
} catch {
  fail('the regenerated catalog.json does not parse.');
}

/// A catalog with its timestamp removed.
///
/// `generated_at` changes on EVERY regeneration, because the site stamps the
/// export. Comparing the raw text therefore always reports "changed" and this
/// script would commit a point-zero content change every time it was run. What
/// matters is whether anything a shopper or the app would SEE changed, so the
/// timestamp is stripped and the rest compared.
function stripTimestamp(json) {
  const { generated_at, ...rest } = json;
  void generated_at;
  return JSON.stringify(rest);
}

const changed = stripTimestamp(afterJson) !== stripTimestamp(beforeJson);

if (!changed) {
  // Put the original back so the repo is not left with a needless diff.
  fs.writeFileSync(path.join(STORE, 'catalog.json'), before);
  console.log('\nNo change to the catalog. Vectors regenerate identically, so');
  console.log('this is the normal case when nothing was edited. Nothing to publish.');
  process.exit(0);
}

// Compare by slug, NOT by index. Products are not in a stable order —
// createProduct inserts by sort_order, so adding one shifts the array and an
// index comparison reports every product after the insertion point as renamed.
// That is exactly what happened: a new pitcher reported "~ Brass Tray", which is
// noise in a diff a human is being asked to trust.
const beforeBySlug = new Map(beforeJson.products.map((p) => [p.slug, p]));
const afterBySlug = new Map(afterJson.products.map((p) => [p.slug, p]));
const added = [...afterBySlug.keys()].filter((s) => !beforeBySlug.has(s));
const removed = [...beforeBySlug.keys()].filter((s) => !afterBySlug.has(s));
const shared = [...afterBySlug.keys()].filter((s) => beforeBySlug.has(s));

const changedByField = (field) =>
  shared.filter((s) => afterBySlug.get(s)[field] !== beforeBySlug.get(s)[field]);

const renamed = changedByField('name').map((s) => afterBySlug.get(s).name);
const repriced = changedByField('price_cents');
const reworded = changedByField('description');
// `details` is not embedded, so a change here is invisible to search: worth
// reporting separately rather than as "a vector changed", which is what the
// refund-policy note appended by db.js's toJson() would otherwise be reported
// as. It changes every product at once, and it changes no vector.
const relonged = changedByField('details');

heading('What changed');
console.log(`    products ${beforeJson.products.length} -> ${afterJson.products.length}`);
for (const s of added) console.log(`      + ${s}`);
for (const s of removed) console.log(`      - ${s}`);
for (const n of renamed) console.log(`      ~ ${n}`);
for (const s of repriced) console.log(`      $ ${s} (price)`);
for (const s of reworded) console.log(`      ~ ${s} (text changed, so its vector changed)`);
for (const s of relonged) console.log(`      ~ ${s} (full description changed, no vector change)`);
if (!added.length && !removed.length && !renamed.length &&
    !repriced.length && !reworded.length && !relonged.length) {
  console.log('      (same products — a vector changed)');
}
// A removed product is worth a second look, because the app ships no product
// list of its own and a link to one would fall back to the site.
if (removed.length > 0) {
  console.log(`\n    Note: ${removed.length} product(s) removed. Links to them now fall`);
  console.log('    back to the site, which reports them as no longer available.');
}

// ── 3. Bump the cache-buster ─────────────────────────────────────────────────

heading('Bumping the site cache-buster and rebuilding its pages');
if (run('node', ['scripts/bump-site-version.mjs']) !== 0) {
  fail('the site did not rebuild cleanly.');
}

// ── 4. Commit and push ──────────────────────────────────────────────────────

heading('Publishing the site');
const status = git(['status', '--porcelain']);
const dirty = status.stdout
  .split(/\r?\n/)
  .map((l) => l.trim())
  .filter(Boolean);

if (dirty.length === 0) {
  console.log('    nothing to commit');
} else {
  console.log('    files:');
  for (const line of dirty) console.log(`      ${line}`);
}

if (NO_PUSH) {
  console.log('\n--no-push: committed nothing, changed files left in place.');
  process.exit(0);
}

const note = message ??
  `Rebuild catalog (${beforeJson.products.length} -> ${afterJson.products.length} products)` +
  `${added.length ? `, +${added.length}` : ''}${removed.length ? `, -${removed.length}` : ''}`;

if (dirty.length > 0) {
  const add = git(['add', '-A']);
  if (add.status !== 0) fail('git add failed.');
  const commit = git(['commit', '-m', note]);
  if (commit.status !== 0) fail('git commit failed.');
  console.log(`    committed: ${note}`);
} else {
  console.log('    already committed');
}

const push = git(['push']);
if (push.status !== 0) fail('git push failed. Push by hand and the rest is done.');
console.log('    pushed');

// ── 5. Confirm it is live ────────────────────────────────────────────────────
//
// The whole point of this script is that the site and the app agree, so the
// last thing it should do is check the site actually has what was just pushed.
// GitHub Pages takes a moment, so this waits rather than guessing once.

heading('Waiting for the live catalog to match');
const expected = JSON.stringify(afterJson);
if (DRY) {
  console.log('    (dry run, skipped)');
  process.exit(0);
}

const deadline = Date.now() + 120000;
let live = null;
for (;;) {
  try {
    const res = await fetch(LIVE_URL, { cache: 'no-store' });
    if (res.ok) {
      live = JSON.stringify(await res.json());
    }
  } catch {
    // Network hiccup or Pages still building — retry until the deadline.
  }
  if (live === expected) {
    console.log('    live catalog matches.');
    break;
  }
  if (Date.now() > deadline) {
    console.error(`\n    The pushed catalog is not live yet at ${LIVE_URL}`);
    console.error('    GitHub Pages is still building. Apps will pick up the new');
    console.error('    catalog on their next launch; nothing here needs rerunning.');
    break;
  }
  await new Promise((r) => setTimeout(r, 3000));
}

console.log('\nPublished. Installed apps see the new catalog on their next');
console.log('launch, or straight away with pull-to-refresh. No app update needed.');
