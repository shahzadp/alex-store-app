#!/usr/bin/env node
/**
 * Verify the vendored engine still matches ternlight upstream, byte for byte.
 *
 * README.md and MEMORY.md both claim `rust/src/engine/` is "vendored
 * byte-for-byte unmodified". That claim is load-bearing: it is what makes
 * `git diff` against ternlight meaningful when upgrading, and it is why
 * `lib.rs` uses `#[path]` instead of rewriting `crate::` references.
 *
 * If someone "fixes" a compile error in there instead of fixing the wiring,
 * this is what catches it. Run it before any engine upgrade.
 */

import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const HERE = dirname(fileURLToPath(import.meta.url));
const ENGINE = resolve(HERE, '..', 'rust', 'src', 'engine');

/** Pin the commit. Bumping this IS the upgrade. */
const REF = 'main';
const BASE = `https://raw.githubusercontent.com/soycaporal/ternlight/${REF}/engine/src`;

const FILES = ['format.rs', 'inference.rs', 'kernels.rs', 'model.rs', 'tokenizer.rs'];

const sha = (buf) => createHash('sha256').update(buf).digest('hex');

let drift = 0;

console.log(`Comparing against ternlight @ ${REF}\n`);

for (const name of FILES) {
  const local = readFileSync(resolve(ENGINE, name));
  const upstream = execFileSync('curl', ['-sL', '--fail', `${BASE}/${name}`], {
    maxBuffer: 10 * 1024 * 1024,
  });

  const a = sha(local);
  const b = sha(upstream);
  const same = a === b;

  console.log(`  ${same ? 'OK  ' : 'DRIFT'}  ${name.padEnd(16)} ${a.slice(0, 16)}`);

  if (!same) {
    drift++;
    console.log(`         upstream is ${b.slice(0, 16)}`);
    console.log('         If this is an intended change, it is no longer vendored');
    console.log('         unmodified — update README.md and MEMORY.md, or revert.');
  }
}

console.log('');
if (drift) {
  console.error(`${drift} file(s) differ from upstream.`);
  process.exit(1);
}
console.log('Engine matches upstream exactly.');
console.log('');
console.log('Reminder: upstream moves. Pin REF to a commit sha rather than "main"');
console.log('if you rely on this check in CI.');