# Performance

Notes on what the native engine costs, and the one optimisation it is missing.

Nothing here has been measured on a device yet. Every number marked *expected*
is arithmetic from the model's shape, not an observation. Measure before
trusting any of it.

## Where the time goes

Per query the app does exactly one embedding and then a dot product against
eight vectors.

| Step | Work | Note |
| --- | --- | --- |
| Tokenize | 128 tokens, WordPiece | `tokenizers` crate, vocab built once |
| Embedding lookup | one gather per token | int4, unpacked on demand |
| BitLinear matmul | 2 layers × 6 matrices | **the hot loop** |
| Attention | 2 layers, 4 heads | softmax over 128 |
| Output projection | 384 × 384 fp32 | ~590 K FLOP |
| Rank | 8 × 384 multiply-add | ~3 K FLOP, negligible |

The model is d384, 2 layers, ffn 1536. ternlight quotes ~2 ms per embedding on
an M-series CPU **with WASM SIMD enabled**. That number does not transfer.

## The SIMD gap

`rust/src/engine/kernels.rs` has:

```rust
#[cfg(target_arch = "wasm32")]
fn bitlinear_inner_simd(...) { /* 16-lane i32 SIMD accumulate */ }

#[cfg(not(target_arch = "wasm32"))]
fn bitlinear_inner_simd(...) { /* scalar loop */ }
```

Native ARM takes the scalar branch. The WASM path processes 16 `i8` lanes per
iteration using `i16x8_extmul_low_i8x16` + `i32x4_extadd_pairwise_i16x8`; the
scalar path does one `i32` multiply-accumulate at a time. That is roughly a
**10–20× difference** in the hot loop, and the hot loop dominates.

Accumulator overflow is not a concern either way — ternlight's comment bounds
worst case at `128 × 1024 = 131072`, comfortably inside `i32` and inside the
24-bit fp32 mantissa, so the widening accumulate is exact either way.

### What adding NEON looks like

`core::arch::aarch64` gives `vld1_s8` / `vmull_s8` / `vpadalq_s16`, which is the
direct analogue of the WASM sequence. The `#[cfg]` guard already exists; it
needs a third arm, not a rewrite.

Expected effect: brings native in line with the site's latency, which matters
less than it sounds — 4.6 MB of weights are resident in `.rodata` the whole time
and there is no per-query I/O, so the absolute number is already small enough
that nobody will notice. Do it for the cold-start `warm_up()`, not for typing
latency.

## Cold start

`warm_up()` forces, in order: SHA-256 over the 4.6 MB `model.bin`, header
parse, layout walk, unpack of ~1.5 MB of ternary weights from 2-bit packed to
`i8`, and construction of the `tokenizers::Tokenizer` from a 694 KB JSON.

That is the expensive part, and it is why `CatalogService` is expected to call
it during launch rather than letting it land on the first search. It is a one
time cost — `OnceLock` inside `model.rs` and `tokenizer.rs` guarantees it.

**Expected**: low hundreds of milliseconds on a mid-range device. Unmeasured.

## Memory

| Item | Size |
| --- | --- |
| `model.bin` (`.rodata`) | 4.6 MB |
| `tokenizer.json` (`.rodata`) | 0.7 MB |
| Unpacked ternary weights | ~1.5 MB |
| Embedding table (kept as bytes, read on demand) | ~1.2 MB |
| Product vectors (8 × 384 × f32) | 12 KB |

Upstream deliberately does *not* pre-decode the embedding table — ternlight's
`model.rs` says keeping it duplicated alongside the `include_bytes!` copy would
cost more than the gather saves. Same reasoning applies on native.

## Why the index lives in Rust

`api.rs` takes the product vectors once, at load, and returns only
`{slug, score}` per query.

The obvious alternative — bridge `embed(query) -> List<double>` and rank in
Dart — marshals the whole index across the FFI boundary on every keystroke, and
Flutter's FFI copies `List<double>` rather than sharing it. With eight products
that is 3 K floats per keystroke, which is not a disaster, but it grows linearly
with the catalog and there is no reason to pay it.

## Optimisation order, if it is ever needed

1. Measure. Nothing below is justified without a number.
2. NEON in `bitlinear_inner_simd`. Contained, mechanical, low risk.
3. Move `warm_up()` off the main thread if it is visible at launch.
4. Batch embedding, if the UI ever needs to pre-rank several queries at once.
   Currently it embeds one string per call and nothing else calls it.