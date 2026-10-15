#!/usr/bin/env node
/**
 * Rebuild rust/src/assets/model.bin from the @ternlight/base WASM.
 *
 * # WHY THIS EXISTS
 *
 * The engine ships `include_bytes!` of a model that upstream builds from
 * `training/pack/out/d384/model-int4.bin` (see the `build` script in
 * @ternlight/base's package.json). That file is a build artefact and is not
 * published, so `model.bin` here is recovered out of the published WASM.
 *
 * The naive recovery — take the bytes from the `TERN` magic to wherever the
 * floats stop looking plausible — produces a file that LOADS but computes
 * nonsense. Specifically:
 *
 *   1. The blob inside the WASM is 192 bytes SHORTER than `compute_layout`
 *      expects. Applied as-is, the engine reads every section 192 bytes late.
 *   2. The last 192 bytes of the projection bias then fall off the end of the
 *      data and land on the WASM's own panic strings ("W_out has bias", ...).
 *   3. Worse, each LayerNorm bias picks up 48 words of packed-int4 data from
 *      the following weight block. Decoded as fp32 those are ~1e+13..1e+25.
 *   4. A 1e+25 LayerNorm bias makes BitLinear's internal LayerNorm overflow
 *      (`var` -> Inf -> `inv_std` -> 0), so every Q/K/V collapses to zero and
 *      `embed()` returns the SAME vector for every input. The engine still
 *      returns a unit-length vector, so nothing errors; search just silently
 *      returns the same ranking for everything.
 *
 * # HOW THE 192 BYTES WERE FOUND
 *
 * `training/pack/encoders.py::encode_embedding_int4` forces `scales[0] = 0.0`
 * for the padding row and zeroes row 0's packed bytes. An exact fp32 `0.0`
 * followed by tens of thousands of plausible positive floats is not a
 * coincidence, so it pins the start of the scale array exactly. It is at
 * 5860064, not the 5860256 that `compute_layout` computes — hence the packed
 * embedding is 30521 rows (30521 * 192 = 5860032), not 30522 * 192.
 *
 * With that correction every section lands where the engine expects, all
 * twelve BitLinear scales become plausible POSITIVE values (before, several
 * were negative, which is impossible for a weight scale), and `embed()` again
 * depends on its input.
 *
 * The engine itself is never modified: `scripts/check-vendor-clean.mjs` pins
 * rust/src/engine/*.rs byte-for-byte against upstream. This script only
 * changes the DATA.
 *
 * Usage:
 *   node scripts/rebuild-model-from-wasm.mjs            # rebuild model.bin
 *   node scripts/rebuild-model-from-wasm.mjs --check     # verify only
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, '..');
const OUT = join(REPO, 'rust', 'src', 'assets', 'model.bin');

const CHECK_ONLY = process.argv.includes('--check');
const HEADER = 32;
const SHA = 32;

// Geometry from the blob's own header: vocab=30522 d_model=384 n_layers=2
// n_heads=6 ffn=1536 out=384, embedding_format=int4, weights=ternary.
const H = { d: 384, ffn: 1536, out: 384, layers: 2, vocab: 30522 };
const EMB_ROWS = 30521;          // 30521 * 192 = 5860032, not 30522 * 192
const EMB_PACKED = EMB_ROWS * (H.d / 2);

// Where the real bytes live, measured from the TERN magic.
function realLayout() {
  let off = HEADER + EMB_PACKED;
  const embS = off; off += H.vocab * 4;
  const layers = [];
  for (let l = 0; l < H.layers; l++) {
    const L = { ln1: off };
    off += H.d * 8;                      // LayerNorm: 384 fp32 weight + bias
    const mats = [];
    const take = (inF, outF, biasWords) => {
      const packed = outF * (inF / 4);
      const m = { w: off, packed, s: off + packed };
      off += packed + 4;
      if (biasWords) { m.b = off; m.biasWords = biasWords; off += biasWords * 4; }
      mats.push(m);
    };
    take(H.d, H.d, 0); take(H.d, H.d, 0); take(H.d, H.d, 0); take(H.d, H.d, H.d);
    L.ln2 = off; off += H.d * 8;
    take(H.d, H.ffn, H.ffn); take(H.ffn, H.d, H.d);
    L.mats = mats;
    layers.push(L);
  }
  const lnF = off; off += H.d * 8;
  const projW = off; off += H.d * H.out * 4;
  const projB = off; off += H.out * 4;
  return { embS, layers, lnF, projW, projB, total: off };
}

// Where compute_layout expects them (unchanged upstream arithmetic).
function engineLayout() {
  let off = HEADER;
  const emb = { w: off };
  off += H.vocab * (H.d / 2);
  emb.s = off; off += H.vocab * 4;
  const layers = [];
  for (let l = 0; l < H.layers; l++) {
    const L = { ln1: off };
    off += H.d * 8;
    const mats = [];
    const take = (inF, outF, hasB) => {
      const m = { w: off, s: off + outF * (inF / 4) };
      off += outF * (inF / 4) + 4;
      if (hasB) { m.b = off; off += outF * 4; }
      mats.push(m);
    };
    take(H.d, H.d, 0); take(H.d, H.d, 0); take(H.d, H.d, 0); take(H.d, H.d, true);
    L.ln2 = off; off += H.d * 8;
    take(H.d, H.ffn, true); take(H.ffn, H.d, true);
    L.mats = mats;
    layers.push(L);
  }
  const lnF = off; off += H.d * 8;
  const projW = off; off += H.d * H.out * 4;
  const projB = off; off += H.out * 4;
  return { emb, layers, lnF, projW, projB, total: off };
}

function loadWasm() {
  const require = createRequire(import.meta.url);
  let pkg;
  try { pkg = require.resolve('@ternlight/base/web'); }
  catch {
    console.error('@ternlight/base is not installed.  npm install --no-save @ternlight/base@0.1.1');
    process.exit(1);
  }
  return readFileSync(join(dirname(pkg), 'tern_engine_bg.wasm'));
}

const wasm = loadWasm();
const start = wasm.indexOf(Buffer.from('TERN'));
if (start < 0) { console.error('no TERN magic in the wasm'); process.exit(1); }

const E = engineLayout();
const R = realLayout();

console.log('engine  (compute_layout) total:', E.total);
console.log('real    (measured)       total:', R.total);
console.log('difference                   :', E.total - R.total, 'bytes');
if (E.total - R.total !== 192) {
  console.error('expected the 192-byte gap; the blob layout has changed — stop and re-derive.');
  process.exit(1);
}

const srcBody = wasm.subarray(start, start + R.total);
if (srcBody.length !== R.total) { console.error('blob truncated'); process.exit(1); }

// ── build the engine-shaped file ────────────────────────────────────────────
const out = Buffer.alloc(E.total + SHA);
srcBody.copy(out, 0, 0, HEADER);
srcBody.copy(out, HEADER, HEADER, HEADER + EMB_PACKED);
// out[HEADER+EMB_PACKED .. E.emb.s) stays zero: the 192 bytes the engine
// expects but the blob does not have.
srcBody.copy(out, E.emb.s, R.embS, R.embS + H.vocab * 4);

const cp = (from, to, bytes) => srcBody.copy(out, to, from, from + bytes);

for (let l = 0; l < H.layers; l++) {
  const rl = R.layers[l], el = E.layers[l];
  cp(rl.ln1, el.ln1, H.d * 4);              // LayerNorm weight
  cp(rl.ln1 + H.d * 4, el.ln1 + H.d * 4, H.d * 4);   // LayerNorm bias
  for (let i = 0; i < 6; i++) {
    const rm = rl.mats[i], em = el.mats[i];
    cp(rm.w, em.w, rm.packed);
    cp(rm.s, em.s, 4);
    if (rm.b !== undefined && em.b !== undefined) cp(rm.b, em.b, rm.biasWords * 4);
  }
  cp(rl.ln2, el.ln2, H.d * 4);
  cp(rl.ln2 + H.d * 4, el.ln2 + H.d * 4, H.d * 4);
}
cp(R.lnF, E.lnF, H.d * 4);
cp(R.lnF + H.d * 4, E.lnF + H.d * 4, H.d * 4);
cp(R.projW, E.projW, H.d * H.out * 4);
cp(R.projB, E.projB, H.out * 4);

createHash('sha256').update(out.subarray(0, E.total)).digest().copy(out, E.total);

// ── self-check: every scale must be plausible, biases must be small ─────────
const rd = (o) => out.readFloatLE(o);
let bad = 0;
for (let l = 0; l < H.layers; l++) {
  for (const m of E.layers[l].mats) {
    const v = rd(m.s);
    if (!(Number.isFinite(v) && v > 0 && v < 1e3)) {
      console.error(`  bad scale @${m.s} = ${v}`); bad++;
    }
  }
}
const biasBad = (o, n) => {
  let c = 0;
  for (let i = 0; i < n; i++) { const v = rd(o + 4 * i); if (!Number.isFinite(v) || Math.abs(v) > 10) c++; }
  return c;
};
const biasTotal =
  biasBad(E.layers[0].ln1 + H.d * 4, H.d) + biasBad(E.layers[0].ln2 + H.d * 4, H.d) +
  biasBad(E.layers[1].ln1 + H.d * 4, H.d) + biasBad(E.layers[1].ln2 + H.d * 4, H.d) +
  biasBad(E.lnF + H.d * 4, H.d) + biasBad(E.projB, H.out);

console.log(`scales: ${12 - bad}/12 plausible    bias entries out of range: ${biasTotal}`);
console.log(`scales[0] (padding row, must be 0): ${rd(E.emb.s)}`);

if (bad || biasTotal) {
  console.error('\nrebuilt file failed its own sanity check — not writing.');
  process.exit(1);
}

if (CHECK_ONLY) {
  const cur = readFileSync(OUT);
  console.log(`\n--check: ${cur.equals(out) ? 'model.bin matches' : 'model.bin DIFFERS'}`);
} else {
  writeFileSync(OUT, out);
  console.log(`\nwrote ${OUT} (${out.length} bytes)`);
  console.log('next: cd rust && cargo test --test parity');
}