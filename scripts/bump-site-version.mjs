#!/usr/bin/env node
/**
 * Bump the site cache-buster in `build.config.json` and rebuild the pages.
 *
 * WHY THIS IS A SCRIPT AND NOT A `sed`/PowerShell one-liner
 * MEMORY.md §4: `build.mjs` strips a UTF-8 BOM, because PowerShell's
 * `Set-Content -Encoding utf8` writes one that makes JSON.parse fail on an
 * invisible character. Anything that rewrites this file has to write it the
 * same way build.mjs reads it, or it breaks the build in a way that looks
 * like corruption rather than an encoding change.
 *
 * WHY IT MATTS
 * MEMORY.md §3 and CATALOG-GUIDE.md §10: every local <script> and <link>
 * carries `?v=NN`, injected by `node build.mjs`. Bump this number after
 * changing ANY .js or .css file, or returning visitors keep the old file and
 * you will spend an hour debugging a fix that is already deployed.
 *
 * Leaves `apkUrl` and every other key untouched.
 *
 * Usage:
 *   node scripts/bump-site-version.mjs            # bump, rebuild, verify
 *   node scripts/bump-site-version.mjs --check    # verify only, do not write
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const HERE = dirname(fileURLToPath(import.meta.url));
const STORE = resolve(HERE, '..', '..', 'Store');
const CONFIG = resolve(STORE, 'build.config.json');

const CHECK = process.argv.includes('--check');

function readConfig() {
  const raw = readFileSync(CONFIG, 'utf8');
  try {
    return JSON.parse(raw.replace(/^\uFEFF/, ''));
  } catch (e) {
    console.error(`build.config.json is not valid JSON: ${e.message}`);
    console.error('A UTF-8 BOM here breaks build.mjs. Re-save it as UTF-8 without BOM.');
    process.exit(1);
  }
}

function run(args) {
  execFileSync('node', args, { cwd: STORE, stdio: 'inherit' });
}

const config = readConfig();
const current = String(config.version);

console.log(`site cache-buster: ${current}`);

if (CHECK) {
  // Confirm the committed HTML matches what the current version would produce.
  run(['build.mjs', '--check']);
  console.log('Pages are current.');
  process.exit(0);
}

const next = String(Number(current) + 1);
if (!Number.isFinite(Number(current))) {
  console.error(`version "${current}" is not a number; refusing to guess`);
  process.exit(1);
}

// Replace only the version value. Everything else in the file, including
// apkUrl and its explanatory note, is left exactly as it was.
const raw = readFileSync(CONFIG, 'utf8');
const patched = raw.replace(/("version"\s*:\s*")(\d+)(")/, `$1${next}$3`);
if (patched === raw) {
  console.error('could not find a "version": "<n>" pair in build.config.json');
  process.exit(1);
}

// LF endings, UTF-8, no BOM — matching how build.mjs writes its output.
writeFileSync(CONFIG, patched.replace(/\r\n/g, '\n'), 'utf8');

const after = readConfig();
console.log(`  ${current} -> ${after.version}`);
console.log(`  apkUrl: ${JSON.stringify(after.apkUrl ?? '')} (untouched)`);

// build.mjs injects the version into every tag on every page, so the commit
// must include both build.config.json and the regenerated root HTML.
run(['build.mjs']);

// Must exit 0 before pushing. MEMORY.md §5.
run(['build.mjs', '--check']);
console.log('\nRebuilt and verified.');