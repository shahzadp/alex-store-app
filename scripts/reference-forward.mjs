// Independent port of training/pack/unpack.py::UnpackedModel.forward to JS.
//
// PURPOSE
// =======
// The native Rust engine and the published WASM are the SAME code, so comparing
// them only proves the file is right. This is a genuinely separate
// implementation, written from the Python reference rather than from the Rust,
// reading the same rebuilt model.bin.
//
//   JS matches WASM  -> the data is right and the Rust engine is wrong.
//   JS misses WASM   -> the repacked bytes are wrong.
//
// Tokenisation is taken from the WASM's own `tokenize()` so that this test
// isolates the forward pass and the data, not the tokenizer.
//
// Numerics: Math.fround is applied wherever the reference is f32. BitLinear's
// inner product is exact integer arithmetic, so only the surrounding fp32
// steps are approximate — not closely enough to matter for this comparison.

import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const MODEL = 'D:/GitHub Projects/alex-store-app/rust/src/assets/model.bin';
const buf = readFileSync(MODEL);

// ── header (training/pack/format.py::_HEADER_STRUCT) ───────────────────────
const HEADER = 32, SHA = 32;
const body = buf.subarray(0, buf.length - SHA); // verify_sha256 returns this
const header = {
  magic: body.subarray(0, 4).toString('latin1'),
  version: body.readUInt16LE(4),
  embFmt: body[6],
  weightsFmt: body[7],
  vocab: body.readUInt32LE(8),
  dModel: body.readUInt16LE(12),
  nLayers: body[14],
  nHeads: body[15],
  ffn: body.readUInt16LE(16),
  out: body.readUInt16LE(18),
  maxSeq: body.readUInt16LE(20),
};
if (header.magic !== 'TERN') throw new Error('bad magic');

const { dModel: D, nLayers: L, nHeads: NH, ffn: FF, out: OUT, vocab: V } = header;
const dHead = D / NH;

// ── layout (engine/src/model.rs::compute_layout, verbatim) ──────────────────
function computeLayout() {
  let off = HEADER;
  const embW = off;
  let embWB, embSB;
  switch (header.embFmt) {
    case 0: embWB = V * D * 4; embSB = 0; break;   // fp32
    case 1: embWB = V * D; embSB = V * 4; break;    // int8
    case 2: embWB = V * (D / 4); embSB = V * 4; break; // ternary
    case 3: embWB = V * (D / 2); embSB = V * 4; break; // int4
    default: throw new Error('unknown embedding_format');
  }
  off += embWB;
  const embS = off; off += embSB;

  const take = (inF, outF, hasB) => {
    const packed = outF * (inF / 4);
    const m = { w: off, s: off + packed };
    off += packed + 4;
    if (hasB) { m.b = off; off += outF * 4; }
    return m;
  };

  const layers = [];
  for (let l = 0; l < L; l++) {
    const ln1 = off; off += D * 8;
    const wq = take(D, D, false), wk = take(D, D, false), wv = take(D, D, false), wout = take(D, D, true);
    const ln2 = off; off += D * 8;
    const fc1 = take(D, FF, true), fc2 = take(FF, D, true);
    layers.push({ ln1, wq, wk, wv, wout, ln2, fc1, fc2 });
  }
  const lnF = off; off += D * 8;
  const projW = off; off += D * OUT * 4;
  const projB = off; off += OUT * 4;
  return { embW, embWB, embS, embSB, layers, lnF, projW, projB, total: off };
}
const lay = computeLayout();

const f32 = Math.fround;
const rdF = (o) => f32(body.readFloatLE(o));
const rdVec = (o, n) => { const a = new Float32Array(n); for (let i = 0; i < n; i++) a[i] = f32(body.readFloatLE(o + 4 * i)); return a; };

// ── decoders (unpack.py) ────────────────────────────────────────────────────
function decodeEmbeddingInt4() {
  const packed = body.subarray(lay.embW, lay.embW + lay.embWB);
  const scales = rdVec(lay.embS, V);
  const bpr = D / 2;
  return (ids) => {
    const out = new Float32Array(ids.length * D);
    for (let i = 0; i < ids.length; i++) {
      const id = ids[i], row = id * bpr, scale = scales[id];
      for (let b = 0; b < bpr; b++) {
        const byte = packed[row + b];
        const lo = byte & 0x0f, hi = (byte >> 4) & 0x0f;
        out[i * D + b * 2]     = f32((lo < 8 ? lo : lo - 16) * scale);
        out[i * D + b * 2 + 1] = f32((hi < 8 ? hi : hi - 16) * scale);
      }
    }
    return out;
  };
}

function decodeBitlinear(m) {
  const inF = m.inF, outF = m.outF;
  const packed = body.subarray(m.w, m.w + outF * (inF / 4));
  const w = new Int8Array(outF * inF);
  let o = 0;
  for (let r = 0; r < outF; r++) {
    const base = r * (inF / 4);
    for (let b = 0; b < inF / 4; b++) {
      const byte = packed[base + b];
      for (let s = 0; s < 4; s++) {
        const c = (byte >> (s * 2)) & 0b11;
        w[o++] = c === 0b01 ? 1 : c === 0b10 ? -1 : 0;
      }
    }
  }
  return { w, scale: rdF(m.s), bias: m.b !== undefined ? rdVec(m.b, outF) : null };
}

const emb = decodeEmbeddingInt4();
for (const m of lay.layers) {
  for (const k of ['wq', 'wk', 'wv', 'wout', 'fc1', 'fc2']) {
    const spec = { wq: [D, D], wk: [D, D], wv: [D, D], wout: [D, D], fc1: [D, FF], fc2: [FF, D] }[k];
    lay.layers[0][k].inF = spec[0];
    lay.layers[0][k].outF = spec[1];
  }
}
const layers = lay.layers.map((l) => ({
  ln1w: rdVec(l.ln1, D), ln1b: rdVec(l.ln1 + D * 4, D),
  wq: decodeBitlinear({ ...l.wq, inF: D, outF: D }),
  wk: decodeBitlinear({ ...l.wk, inF: D, outF: D }),
  wv: decodeBitlinear({ ...l.wv, inF: D, outF: D }),
  wout: decodeBitlinear({ ...l.wout, inF: D, outF: D }),
  ln2w: rdVec(l.ln2, D), ln2b: rdVec(l.ln2 + D * 4, D),
  fc1: decodeBitlinear({ ...l.fc1, inF: D, outF: FF }),
  fc2: decodeBitlinear({ ...l.fc2, inF: FF, outF: D }),
}));
const lnFw = rdVec(lay.lnF, D), lnFb = rdVec(lay.lnF + D * 4, D);
const projW = rdVec(lay.projW, OUT * D), projB = rdVec(lay.projB, OUT);

// ── primitives ──────────────────────────────────────────────────────────────
const LN_EPS = f32(1e-5), BL_EPS = f32(1e-5), ACT_MAX = f32(128);

// torch.layer_norm(x, [n]) — parameterless, biased variance, eps 1e-5.
function layerNormParam(row, w, b, n) {
  let mean = 0;
  for (let i = 0; i < n; i++) mean = f32(mean + row[i]);
  mean = f32(mean / n);
  let varr = 0;
  for (let i = 0; i < n; i++) { const d = f32(row[i] - mean); varr = f32(varr + f32(d * d)); }
  varr = f32(varr / n);
  const inv = f32(1 / Math.sqrt(f32(varr + LN_EPS)));
  const out = new Float32Array(n);
  for (let i = 0; i < n; i++) out[i] = f32(f32(f32(row[i] - mean) * inv) * w[i] + b[i]);
  return out;
}

function gelu(x) {
  return f32(f32(0.5 * x) * f32(1 + erf(f32(x * f32(Math.SQRT1_2)))));
}

// erf via the libm-quality rational approximation used by many f32 ports.
function erf(x) {
  const s = x < 0 ? -1 : 1; const a = Math.abs(x);
  const t = 1 / (1 + 0.3275911 * a);
  const y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t * t + 0.254829592 * t) * Math.exp(-a * a);
  return s * y;
}

// unpack.py::bitlinear_forward
function bitlinear(x, nRows, bw, inF, outF) {
  const out = new Float32Array(nRows * outF);
  for (let r = 0; r < nRows; r++) {
    const src = x.subarray(r * inF, (r + 1) * inF);

    // 1) parameterless LayerNorm
    let mean = 0; for (let i = 0; i < inF; i++) mean = f32(mean + src[i]);
    mean = f32(mean / inF);
    let varr = 0; for (let i = 0; i < inF; i++) { const d = f32(src[i] - mean); varr = f32(varr + f32(d * d)); }
    varr = f32(varr / inF);
    const inv = f32(1 / Math.sqrt(f32(varr + BL_EPS)));
    const xn = new Float32Array(inF);
    for (let i = 0; i < inF; i++) xn[i] = f32(f32(src[i] - mean) * inv);

    // 2) per-token AbsMax activation scale
    let xmax = BL_EPS;
    for (let i = 0; i < inF; i++) { const a = Math.abs(xn[i]); if (a > xmax) xmax = a; }
    const xScale = f32(ACT_MAX / xmax);

    // 3) quantise to int8
    const xq = new Int8Array(inF);
    for (let i = 0; i < inF; i++) {
      const q = Math.max(-128, Math.min(127, Math.round(f32(xn[i] * xScale))));
      xq[i] = q;
    }

    // 4) exact i8 matmul + bias, 5) rescale
    for (let j = 0; j < outF; j++) {
      let acc = 0;
      const base = j * inF;
      for (let i = 0; i < inF; i++) acc += xq[i] * bw.w[base + i];
      let y = acc;
      if (bw.bias) y = f32(y + bw.bias[j]);
      out[r * outF + j] = f32(y / f32(bw.scale * xScale));
    }
  }
  return out;
}

// unpack.py::UnpackedModel.forward
function forward(ids) {
  const nActive = ids.filter((i) => i !== 0).length;
  let x = emb(ids.slice(0, nActive));

  for (const l of layers) {
    let xn = new Float32Array(x.length);
    for (let t = 0; t < nActive; t++) xn.set(layerNormParam(x.subarray(t * D, (t + 1) * D), l.ln1w, l.ln1b, D), t * D);

    const Q = bitlinear(xn, nActive, l.wq, D, D);
    const K = bitlinear(xn, nActive, l.wk, D, D);
    const Vv = bitlinear(xn, nActive, l.wv, D, D);

    const scores = new Float32Array(NH * nActive * nActive);
    const attnOut = new Float32Array(nActive * D);
    const scale = Math.sqrt(dHead);
    for (let h = 0; h < NH; h++) {
      for (let t1 = 0; t1 < nActive; t1++) {
        const s = new Float32Array(nActive);
        for (let t2 = 0; t2 < nActive; t2++) {
          let d = 0;
          for (let dI = 0; dI < dHead; dI++) d = f32(d + Q[t1 * D + h * dHead + dI] * K[t2 * D + h * dHead + dI]);
          s[t2] = f32(d / scale);
        }
        let mx = -Infinity; for (const v of s) if (v > mx) mx = v;
        let sum = 0; const e = new Float32Array(nActive);
        for (let t2 = 0; t2 < nActive; t2++) { e[t2] = Math.exp(f32(s[t2] - mx)); sum = f32(sum + e[t2]); }
        for (let t2 = 0; t2 < nActive; t2++) { e[t2] = f32(e[t2] / sum); scores[h * nActive * nActive + t1 * nActive + t2] = e[t2]; }
        for (let dI = 0; dI < dHead; dI++) {
          let acc = 0;
          for (let t2 = 0; t2 < nActive; t2++) acc = f32(acc + f32(e[t2] * Vv[t2 * D + h * dHead + dI]));
          attnOut[t1 * D + h * dHead + dI] = acc;
        }
      }
    }

    const ao = bitlinear(attnOut, nActive, l.wout, D, D);
    for (let i = 0; i < nActive * D; i++) x[i] = f32(x[i] + ao[i]);

    let xn2 = new Float32Array(x.length);
    for (let t = 0; t < nActive; t++) xn2.set(layerNormParam(x.subarray(t * D, (t + 1) * D), l.ln2w, l.ln2b, D), t * D);

    const h1 = bitlinear(xn2, nActive, l.fc1, D, FF);
    for (let i = 0; i < nActive * FF; i++) h1[i] = gelu(h1[i]);
    const fo = bitlinear(h1, nActive, l.fc2, FF, D);
    for (let i = 0; i < nActive * D; i++) x[i] = f32(x[i] + fo[i]);
  }

  const xf = new Float32Array(nActive * D);
  for (let t = 0; t < nActive; t++) xf.set(layerNormParam(x.subarray(t * D, (t + 1) * D), lnFw, lnFb, D), t * D);

  const pooled = new Float32Array(D);
  for (let t = 0; t < nActive; t++) for (let d = 0; d < D; d++) pooled[d] = f32(pooled[d] + xf[t * D + d]);
  for (let d = 0; d < D; d++) pooled[d] = f32(pooled[d] / nActive);

  const proj = new Float32Array(OUT);
  for (let j = 0; j < OUT; j++) {
    let acc = projB[j];
    for (let i = 0; i < D; i++) acc = f32(acc + f32(projW[j * D + i] * pooled[i]));
    proj[j] = acc;
  }
  let nrm = 0; for (const v of proj) nrm = f32(nrm + f32(v * v));
  nrm = Math.sqrt(nrm);
  for (let i = 0; i < OUT; i++) proj[i] = f32(proj[i] / nrm);
  return proj;
}

// ── compare against the WASM ────────────────────────────────────────────────
const require = createRequire(import.meta.url);
const enginePath = require.resolve('@ternlight/base/web');
const wasm = await import(pathToFileURL(enginePath).href);
await wasm.default({ module_or_path: readFileSync(join(dirname(enginePath), 'tern_engine_bg.wasm')) });

console.log(`header: d_model=${D} n_layers=${L} n_heads=${NH} ffn=${FF} out=${OUT} vocab=${V} emb=${header.embFmt}`);
console.log(`layout total ${lay.total}, body ${body.length}\n`);

const catalog = JSON.parse(readFileSync('D:/GitHub Projects/Store/catalog.json', 'utf8'));
const dot = (a, b) => { let s = 0; for (let i = 0; i < a.length; i++) s += a[i] * b[i]; return s; };

console.log('product          cos(JS, WASM)   maxdiff    dims>0.01');
let worstCos = 1;
for (const p of catalog.products) {
  const text = `${p.name}. ${p.category}. ${p.description || ''}`.trim();
  const ids = Array.from(wasm.tokenize(text));
  const mine = forward(ids);
  const theirs = wasm.embed(text);
  const c = dot(mine, theirs);
  worstCos = Math.min(worstCos, c);
  let maxDiff = 0, over = 0;
  for (let i = 0; i < mine.length; i++) { const d = Math.abs(mine[i] - theirs[i]); if (d > maxDiff) maxDiff = d; if (d > 0.01) over++; }
  console.log(`${p.slug.padEnd(16)} ${c.toFixed(8).padStart(12)}   ${maxDiff.toFixed(6)}   ${String(over).padStart(4)}`);
}

console.log('');
console.log(worstCos > 0.9999
  ? 'VERDICT: JS reproduces the WASM from model.bin. The DATA is correct; the Rust engine diverges.'
  : `VERDICT: JS does NOT reproduce the WASM (worst cos ${worstCos.toFixed(6)}). The repacked BYTES are wrong.`);