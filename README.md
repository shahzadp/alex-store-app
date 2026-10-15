# Alex Store — Android app

The Flutter app for [shahzadp.github.io/store](https://shahzadp.github.io/store).

Reads the same `catalog.json` the website serves, and does semantic search
**on device** using ternlight compiled to native Rust instead of WebAssembly.

---

## Why the Rust part exists

The website runs [ternlight](https://github.com/soycaporal/ternlight) — a
1.58-bit BitNet-style sentence encoder — compiled to WASM, and ships the
resulting product embeddings inside `catalog.sql`. Visitors embed only their own
query.

Dart cannot host a WebAssembly runtime, so the app cannot do that. Three ways
out, and why this one:

| Option | Verdict |
| --- | --- |
| Lexical search over `catalog.json` | Cheapest. MEMORY.md §6 calls it "the better trade" for eight products, and for eight products it may well be. But it cannot answer "something to drink out of". |
| A different, ONNX-runnable model | Works in Dart, but forces a **full reindex of the site** and gives up the model the vectors were built with. |
| **The same ternlight engine, compiled natively** | Chosen. Same weights, same tokenizer, same forward pass — so the app ranks with exactly the vectors the site publishes, offline, with no model download at query time. |

ternlight is MIT and the engine is plain Rust; only its `#[wasm_bindgen]` surface
is WebAssembly-specific. `rust/src/engine/` is vendored **byte-for-byte
unmodified** from upstream.

## Layout

```
lib/
  main.dart                     app entry, CatalogScope
  src/
    models/
      catalog.dart              Catalog, Store, Product, Collection
      price.dart                integer paisa -> "Rs 7,800"
    services/
      catalog_service.dart      fetch, cache, validate, map hits -> products
      search_engine.dart        the SearchEngine interface
      rust_search_engine.dart   the flutter_rust_bridge implementation
      whatsapp.dart             wa.me link construction
      launcher.dart             external URL opening
    screens/                    home, shop, product, search, about
    widgets/                    product card/grid, product image
    theme.dart                  colours, type scale, card height constants

rust/
  Cargo.toml
  src/
    lib.rs                      module wiring + compile-time guards  (ours)
    index.rs                    product vector index and ranking     (ours)
    ffi.rs                       the C ABI Dart calls               (ours)
    engine/                     vendored from ternlight, unmodified
    assets/                     tokenizer.json (committed); model.bin (fetched)

scripts/
  extract-model-from-wasm.mjs    recover + SHA-256 verify the weights
  extract-site-vectors.mjs      pull vectors out of catalog.sql -> test fixture
  check-vectors-agree.mjs       catalog.json and catalog.sql must agree
  regen-catalog-json.mjs        run the site's own db.js in Node to re-export
  patch-store-catalog-json.mjs  one-shot patch of the site's db.js
  bump-site-version.mjs         cache-buster bump + rebuild the site
  build-apk.mjs                 cargo -> jniLibs -> flutter build apk

test/                           Dart unit tests (pure Dart, no Flutter needed)
```

## Building

```bash
npm install                            # dev-only, for the scripts below
node scripts/extract-model-from-wasm.mjs   # once; recovers + verifies SHA-256
node scripts/build-apk.mjs
```

Prerequisites: Flutter, Rust **with the `stable-x86_64-pc-windows-gnu` host
toolchain** and the `aarch64-linux-android` target *installed for that
toolchain*, plus the Android SDK and NDK. `rustup` keeps targets per toolchain,
so a target present under `msvc` does not help the GNU one.

No codegen step and no `cargo install`. The Dart boundary is hand-written:
`rust/src/ffi.rs` and `lib/src/services/native_engine.dart` are a matched pair.
`flutter_rust_bridge` was tried first and abandoned; MEMORY.md section 6 records why.

Outputs land in `build/app/outputs/flutter-apk/`.

### `model.bin` is not in this repository

A fresh clone has no weights, and `cargo build` fails on `include_bytes!` until
you fetch them:

```bash
node scripts/extract-model-from-wasm.mjs
```

It downloads `model-int4.bin` from HuggingFace and verifies it against the
SHA-256 in `rust/src/assets/model-int4.bin.json`, which **is** committed. That
manifest is the reason this is safe — a checksum catches a corrupted download,
which a committed blob could not.

4.6 MB of binary in permanent git history for an artifact that is obtainable
and verifiable is a poor trade, and the Store repo's MEMORY.md §3 makes the
same argument about the APK. `tokenizer.json` (694 KB) *is* committed, because
it is upstream source rather than a build artifact.

### The parity test

`rust/tests/parity.rs` is the reason the native port is trustworthy. It reads
the vectors the **site** publishes, re-derives them from the same product text
using the native engine, and asserts:

- per-dimension agreement within `1e-3`;
- cosine ≥ `0.9999` per product;
- identical **ranking order** for ten natural-language queries the index was
  never built from.

The tolerance is not zero and cannot be: the WASM build accumulates the BitLinear
matmul in 16-lane `i32` SIMD, the native build walks ternlight's scalar
fallback, so the summation order differs. The bound is far tighter than any
semantic difference — two different models score cosine < 0.9 — so it catches a
model swap or tokenizer change, and ignores rounding.

Regenerate the fixture after any catalog or model change:

```bash
node scripts/extract-site-vectors.mjs
```

## The site side

`catalog.json` did not used to carry vectors — they lived only in `catalog.sql`,
and MEMORY.md §6 left "decide app search" open partly because of it. They are
now included, as base64 on each product, via
`scripts/patch-store-catalog-json.mjs`.

Base64 rather than a JSON array of floats: a `Float32Array` stringified to JSON
is ~19 characters per element, so 384 dims is ~7 KB per product against 2 KB for
base64. It is also lossless, and it is already the storage format in
`product_vectors`, so there is one representation rather than two that can
drift.

Cost: `catalog.json` went from 6.9 KB to 22.9 KB.

`scripts/regen-catalog-json.mjs` regenerates it by **running the site's real
`db.js`** under Node with `fetch` and `localStorage` stubbed, so the file is
byte-identical to what the admin panel's *Download catalog.json* produces.
Reimplementing the export here would break the guarantee in CATALOG-GUIDE.md §8
that the two catalog files cannot disagree.

## Rules this app inherits from the store

These are not preferences; breaking them breaks the shop.

- **WhatsApp is the only purchase path.** No cart, no account, no checkout.
  Every "order" control is a `wa.me` link with the product, price and
  description already written into the message.
- **PKR only, integer paisa.** `price_cents: 780000` is Rs 7,800. No
  currency selector, no USD, no `double` anywhere near a price.
- **Grid uniformity is enforced by layout, not discipline.** Card name and
  description get fixed-height boxes (2 lines / 3 lines) so a row can never go
  ragged, whatever the catalog says.
- **Only verifiable claims.** The About page describes mechanics a shopper can
  check from the app. It does not say who runs the shop or where the goods come
  from, because those are not known.
- **Sold out means `in_stock == false`** and a disabled control, not a
  pretend-purchasable button.

## Search failure is never silent

This is the failure MEMORY.md §4 spends most of its length on: an incomplete
index makes *every* search return nothing, site-wide, with nothing logged.
`SearchProblem` gives each cause its own message:

| Problem | Meaning | What the user sees |
| --- | --- | --- |
| `incompleteIndex` | a product has no vector | "Search is unavailable: the store catalog is being reindexed." |
| `modelMismatch` | catalog indexed by a different encoder | "Search is unavailable: the app and the store use different search models." |
| `noIndex` | `set_index` has not run | "Search is still starting up." |
| `engineUnavailable` | the native library failed to load | "Search is unavailable on this device." |

A model mismatch is the dangerous one: a dot product between two unrelated
models still returns a confident, entirely wrong ranking. `loadIndex` refuses
rather than proceeding, and checks `search_model` from the catalog against
`SEARCH_MODEL` compiled into the binary.

## Known gaps

- **No NEON path.** ternlight's `kernels.rs` has a WASM SIMD matmul and a
  scalar fallback; native ARM takes the scalar path. Correct, but slower than
  the site. A `core::arch::aarch64` implementation is the obvious next
  optimisation. See `docs/PERF.md`.
- **`android/` is not generated yet.** It comes from `flutter create`.
- **No release, no `apkUrl`.** MEMORY.md §6 keeps `apkUrl` empty until a
  `v1.0` release exists, which is correct — it renders an inert control rather
  than a link to nothing.
- **Nothing has run on a device.** Every claim above is from unit tests and
  from code review.

## Third party

- [ternlight](https://github.com/soycaporal/ternlight) — MIT. Engine in
  `rust/src/engine/`, weights from
  [`wenshutang/ternlight`](https://huggingface.co/wenshutang/ternlight) (MIT).
  See `THIRD_PARTY_TERNLIGHT_LICENSE`.
- `flutter_rust_bridge` — MIT.
- `url_launcher`, `path_provider` — BSD-3.