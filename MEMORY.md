# MEMORY — Alex Store app

Working notes for whoever picks this up next, including an agent with no prior
context. Architecture is in `README.md`.

**Companion repo:** the storefront lives in `../Store` (a sibling directory, not
a subdirectory). Several scripts here edit it. Nothing in this repo is
self-contained.

---

## 1. Current state

- Flutter app, Android target, five screens: home, shop, product, search, about.
- Reads the site's `catalog.json` on every launch; caches a copy for offline.
- Search: ternlight `base@0.1.1`, **compiled to native Rust** via
  flutter_rust_bridge, ranking the site's published vectors.
- The site's `catalog.json` now carries those vectors. It did not until
  `scripts/patch-store-catalog-json.mjs` ran.
- **The Rust crate builds and its tests run** (19 green, including parity).
  The Dart side is still design-only: no Flutter SDK build, no device, no
  emulator.
- **Search now matches the site.** The native engine reproduces the WASM's
  vectors bit-exactly (worst per-dimension difference `0.000e+0`), so the app's
  rankings are the site's rankings. See §3.

---

## 2. The one decision that shapes everything

The website runs ternlight as WebAssembly. Dart cannot host a WASM runtime.
Rather than switching models — which would force a full reindex of the site —
the app compiles **the same engine to native code** and runs the same weights
on the phone.

The engine is plain Rust; only its `#[wasm_bindgen]` surface is
WebAssembly-specific, so `rust/src/engine/` is vendored byte-for-byte and
compiled as-is.

The consequence is the thing to protect: **the app's rankings and the site's
rankings must be the same rankings.** Everything below exists to keep that
true.

---

## 3. Things that have actually bitten, or will

### Parity: SOLVED. The bug was in how the model was extracted, not in the engine.

`cargo test --test parity` is **9/9 green**, and the native engine reproduces
the WASM's vectors **bit-exactly** — worst per-dimension difference across all
eight products is `0.000e+0`, not merely inside the 0.001 tolerance.

#### The actual bug: a WASM file is not a WASM memory

The obvious way to recover the model is to find the `TERN` magic in the `.wasm`
and slice from there. That is wrong, and it fails silently: the file loads,
`verify_sha256` passes (the scripts recompute the hash), and `embed()` returns
unit-length vectors, so nothing complains.

A WASM data segment is stored in the FILE as

```
[flags][offset expression][size][payload]
```

so **consecutive segments are separated by their own headers**. The engine never
sees those separators — it reads LINEAR MEMORY, where payloads sit at their
declared addresses. The `TERN` magic sits in one 21-byte segment and the weights
in the next; slicing the file across that boundary splices in eleven bytes of
scaffolding (`41 98 ef c1 00 0b b5 c3 c9 03`).

`scripts/extract-model-from-wasm.mjs` now parses the section table, replays every
data segment into a memory image, and extracts from that.

#### How the address was found — not guessed

`format.rs::verify_sha256` panics unless the last 32 bytes are the SHA-256 of
everything before them, so the model has a cryptographically-checkable length.
Scanning memory for the address whose 7,492,280-byte body hashes to the 32 bytes
that follow lands on **1,078,968**, and nothing else does. The header there
parses perfectly: `max_seq_len=128`, and all ten `reserved` bytes zero, as
`format.py` demands.

#### Two wrong answers this produced, both now undone

Worth recording, because both were confident and both were wrong:

1. **The naive file slice.** The 11 inter-segment bytes land mid-model. They were
   even mistaken for the header's `reserved` field — but `reserved` is zero in
   memory, and the bytes that looked like it were scaffolding.

2. **"Correcting" for it with a 192-byte realignment.** I inferred the embedding
   held 30,521 rows rather than 30,522, rebuilt the file to match, and got 12/12
   plausible weight scales and a unit-length, input-dependent — but still
   uncorrelated — embedding. **Those 192 bytes are row 0 of the embedding table,
   which `encode_embedding_int4` emits as zeros via `q[0].zero_()`.** They are
   part of the packed table. `compute_layout`'s arithmetic was right all along,
   and the repack is deleted.

The lesson: a plausible, self-consistent story about a binary format is worth
almost nothing until something independent checks it. Here that was the engine's
own SHA-256, and it had been available the whole time.

#### Traps worth remembering

- **A binary artefact's own checksum is the cheapest oracle available.** Reach
  for it before reasoning about offsets. It settled the file length, the start
  address, and the layout in one step.
- **"The extracted weights are byte-identical to the wasm" was circular.** The
  comparison was `model.bin` against the very slice it was cut from — a file
  always equals itself that way.
- **`ranking_scores_match_the_site` is not a parity test.** It scores the app's
  own query vector against the site's stored vectors, so it passes for *any*
  embedding. `native_reproduces_every_site_vector` is the only real check.
- **Scalar-vs-SIMD was "ruled out" by a vacuous test.** It was measured on the
  host, where `#[cfg(not(target_arch = "wasm32"))]` compiles the scalar fallback
  and the SIMD path does not exist — so it compared scalar to scalar. Both are
  exact integer arithmetic and cannot differ anyway.
- **Three separate probes gave wrong answers from one repeated mistake:**
  `subarray(32)` (stripping the header) combined with offsets that were already
  header-inclusive, shifting every reading by 32 bytes. Pick one coordinate
  system and never mix.
- **`scripts/reference-forward.mjs`** is an independent port of
  `unpack.py`'s forward pass to JS. It exists to answer "is it the data or the
  engine?" and answered that the data was wrong. Keep it.

#### Everything else is ruled out, empirically

| Suspect | Verdict | Evidence |
| --- | --- | --- |
| `catalog.json` / base64 encoding | **ruled out** | The site's own WASM reproduces every `catalog.json` vector at cosine **1.0000002**, zero dimensions differing by more than 0.01. `scripts/generate-wasm-fixture.mjs` builds the fixture from the engine directly, so the JSON is not even in the loop. |
| Wrong model (d256 vs d384) | **was a bug, fixed** | Every HF `wenshutang/ternlight` checkpoint is d_model=256/n_heads=4/ffn=1024; the site uses 384/6/1536. Same 384-dim *output* width, which is why nothing failed loudly. |
| Tokenizer | **ruled out** | Byte-identical to the wasm's embedded copy (sha256 `d241a60d…`), and both emit the same id sequence (`active=23`, identical prefix) for the product texts. |
| Forward-pass math | **ruled out** | `inference.rs` + `kernels.rs` follow `training/pack/unpack.py` step for step: parameterless LN → per-token AbsMax → round/clamp to int8 → i8 matmul → `+bias` in pre-rescale space → divide by `(w_scale * x_scale)`; GELU is the exact erf form; attention is `[T, n_heads, d_head]` with `1/√d_head`. Ternary codes unpack low-bits-first with `0b01→+1`, `0b10→−1`, exactly as the packer wrote them. |
| Engine drift from upstream | **ruled out** | `scripts/check-vendor-clean.mjs` pins all five files byte-for-byte; same hashes at commit `c6d2c0a` (the published 0.1.1 build) and on `main`. |
| Model extraction | **was the bug, fixed** | See above. |

**`include_bytes!` is a compile-time failure, not a runtime one.** A missing
`rust/src/assets/model.bin` produces an error pointing at the `include`, which
does not say "run `node scripts/fetch-model.mjs`". `scripts/build-apk.mjs`
checks for the file first and prints that line.

**The vendored engine uses `crate::format::`, `crate::model::` and friends.**
A normal `src/engine/mod.rs` breaks those and forces edits. `lib.rs` uses
`#[path = "engine/format.rs"] pub mod format;` to lift each module to the crate
root instead, so the vendored files stay byte-identical to upstream and
`git diff` against ternlight means something. **Do not "tidy" this into a
`mod.rs`.**

`src/assets/` is one level up from `src/engine/` on purpose:
`model.rs` does `include_bytes!("../assets/model.bin")`, which resolves
relative to the source file. Moving the assets breaks it.

**Exactly one `emb_*` Cargo feature must be enabled.** The vendored `format.rs`
picks `BUILD_EMBEDDING_FORMAT` with `#[cfg(feature = ...)]` and the kernels
dispatch on the same flags. Zero features means `BUILD_EMBEDDING_FORMAT` does
not exist and the crate does not compile; two means you are packing a format
you did not intend. `lib.rs` reproduces ternlight's own `compile_error!` guard
for both cases. `emb_int4` matches the checkpoint the site's vectors came from.

**A `.bin` packed for one embedding format cannot be read by an engine built
for another.** `model-int4.bin`, `model-embedding-int8.bin` and
`model-ternary.bin` are not interchangeable. `scripts/fetch-model.mjs` checks
the manifest's `embedding_format` and refuses a non-int4 one.

**There is no NEON path.** ternlight's `kernels.rs` has a WASM SIMD BitLinear
matmul under `#[cfg(target_arch = "wasm32")]` and a scalar loop for everything
else. Native ARM takes the scalar path. Correct, just slower than the site.
An `aarch64` implementation is the obvious next optimisation; see
`docs/PERF.md`.

**The parity tolerance cannot be zero — but the difference turned out not to be
rounding.** WASM accumulates the matmul in 16 lanes of `i32` SIMD while the
native build uses a scalar loop, so the two *could* differ in the last bits. In
practice they do not: `bitlinear_inner_simd` and its scalar twin are both exact
integer arithmetic (`i8 × i8 → i32`, no floating point), and the measured
difference is **exactly `0.000e+0` per dimension across all eight products**.
The `1e-3` tolerance and cosine ≥ `0.9999` floor in `tests/parity.rs` are
therefore slack, not a fudge — they are far tighter than any semantic difference
(two different models score below 0.9), so they would still catch a model swap.

**`db.js` has mixed line endings** (`\n`, `\r\n` and `\r\r\n` in the same
file — 154/44/471 at time of writing). Plain text replaces silently fail to
find their anchor. Patch it with `scripts/patch-store-catalog-json.mjs`, which
uses single-line anchors, exactly as CATALOG-GUIDE.md §10 says.

**PowerShell `Set-Content -Encoding utf8` writes a BOM** that makes `JSON.parse`
fail on an invisible character. `scripts/bump-site-version.mjs` writes UTF-8
without one.

**A model mismatch is the dangerous failure.** A dot product between two
unrelated models still returns a confident, entirely wrong ranking — no error,
no warning. So `RustSearchEngine.loadIndex` compares the catalog's
`search_model` against `SEARCH_MODEL` compiled into the binary and **refuses**
rather than proceeding. `SEARCH_MODEL` appears in four places that must move
together:

| Where | What |
| --- | --- |
| `../Store/db.js` | `SEARCH_MODEL` |
| `../Store/catalog.json` | `search_model` |
| `rust/src/api.rs` | `SEARCH_MODEL` |
| `lib/src/services/rust_search_engine.dart` | `kSearchModel` |

Changing any one of them without the others makes search silently wrong.

**An empty index and an empty result look identical on screen.** A shopper who
searches "brass tray" and sees nothing concludes the store does not stock it,
not that the app is broken. `SearchProblem` gives each cause its own message.
Never collapse them into one "no results" state.

**`Catalog.isSearchable` is the app's `indexIsComplete()`.** It requires a
vector on *every* product. Partial indexes rank only what they have and look
like a weak result set rather than a broken one, so the app refuses to search
at all and says why.

---

## 4. Ordering rules inherited from the store

Not preferences — breaking them breaks the shop. See `README.md` for the
rationale.

- **WhatsApp is the only purchase path.** No cart, no account, no checkout.
- **PKR only, integer paisa.** No `double` anywhere near a price, no USD, no
  currency selector.
- **Grid uniformity is enforced by layout.** Fixed-height text boxes (2 lines
  name, 3 lines description). Never swap these for `maxLines` alone — that is
  what lets a row go ragged.
- **Only verifiable claims.** The About page says nothing about who runs the
  shop or where goods come from, because that is not known.
- **Sold out means `in_stock == false`** and a disabled control.

---

## 5. Working on it

```bash
node scripts/fetch-model.mjs                 # once; verifies SHA-256
node scripts/fetch-model.mjs --check         # verify, do not download

cd rust && cargo test                        # parity against the site's vectors
node scripts/extract-site-vectors.mjs        # refresh the fixture first
cd .. && node scripts/check-vectors-agree.mjs # catalog.json == catalog.sql

node scripts/build-apk.mjs
```

### Touching the site

```bash
node scripts/regen-catalog-json.mjs          # re-export catalog.json
node scripts/check-vectors-agree.mjs         # must pass
node scripts/bump-site-version.mjs           # bump ?v=NN, rebuild, verify
```

`bump-site-version.mjs` runs `node build.mjs --check` and must exit 0 before
anything is pushed.

---

## 6. Open work

**Blocking**

- [ ] **Find the forward-pass divergence.** See §3. Nothing ships until
      `cargo test --test parity` passes. This is the top item.
- [ ] **Run `flutter_rust_bridge_codegen`.** `lib/src/api/` does not exist, so
      `rust_search_engine.dart` does not compile yet.
- [ ] **Build the Android `.so`.** `cargo build --release --target
      aarch64-linux-android` has never succeeded here; the GNU host toolchain is
      required for build scripts (see `.cargo/config.toml`).

**Done**

- [x] ~~Generate `android/`~~ — done via `flutter create`.
- [x] ~~Compile the Rust crate~~ — it builds and runs.
- [x] ~~Find the right model~~ — it was not the published checkpoint; see §3.
- [x] ~~Run the parity test~~ — it runs, and passes: 9/9, bit-exact against
      the WASM. The bug was in extracting the model from the WASM, not in the
      engine; see §3.
- [x] ~~Fix the 192-byte section misalignment~~ — that diagnosis was wrong and
      has been reverted. Those 192 bytes are embedding row 0.

**Should do**

- [ ] **NEON matmul** for `bitlinear_inner_simd`. See `docs/PERF.md`.
- [ ] **Measure on a device.** Every latency claim is currently a guess.
- [ ] **Wire up `path_provider`.** `CatalogService` takes `readCache`/
      `writeCache` callbacks for exactly this and nothing passes them yet, so
      offline mode does not work.
- [ ] **Decide `armv7`.** The engine targets 64-bit clean; 32-bit Android is
      a vanishing share. `build-apk.mjs` can build it but nothing says it
      should ship.
- [ ] **Release, then set `apkUrl`.** `../Store/build.config.json` keeps
      `apkUrl` empty until a `v1.0` release exists, which is correct — it
      renders an inert control rather than a link to nothing.

**Housekeeping**

- [ ] No CI. `cargo test` plus the Node scripts would catch a stale fixture or
      a catalog that stopped being searchable.
- [ ] The site repo is a sibling checkout, not a submodule. The scripts assume
      `../Store`. Worth pinning or vendoring at some point.

---

## 7. Where things are

| Concern | File |
| --- | --- |
| Module wiring, compile-time guards | `rust/src/lib.rs` |
| Product vector index, ranking | `rust/src/index.rs` |
| flutter_rust_bridge surface | `rust/src/api.rs` |
| Vendored ternlight engine | `rust/src/engine/` (do not edit) |
| Parity test | `rust/tests/parity.rs` |
| Model fetch + SHA-256 | `scripts/fetch-model.mjs` |
| Fixture extraction | `scripts/extract-site-vectors.mjs` |
| Domain model | `lib/src/models/catalog.dart` |
| Paisa arithmetic | `lib/src/models/price.dart` |
| Catalog fetch / cache / validate | `lib/src/services/catalog_service.dart` |
| Search interface | `lib/src/services/search_engine.dart` |
| Bridge implementation | `lib/src/services/rust_search_engine.dart` |
| Card height constants | `lib/src/theme.dart` |
| Architecture and rationale | `README.md` |