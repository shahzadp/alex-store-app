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
- **The Rust crate builds and its tests run** (18 of 19 green). The Dart side is
  still design-only: no Flutter SDK, no Android build, no device, no emulator.
- **Search is not yet trustworthy.** The engine now responds to its input, but
  its vectors do not match the site's. Treat every ranking claim as unverified
  until `native_reproduces_every_site_vector` passes. See §3.

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

### The one that is currently open

**The native engine still does not reproduce the site's vectors.** After the
fix below, `cargo test --test parity` runs 8/9 green but
`native_reproduces_every_site_vector` fails with **cosine ≈ 0.0** against the
engine's own output (0.26 worst, −0.12 worst — i.e. uncorrelated). The engine is
now input-dependent again, but the numbers are wrong.

#### The 192-byte misalignment (FOUND and FIXED)

The single biggest trap so far, and it produced a *silently useless* app.

The blob inside the WASM is **192 bytes shorter than `compute_layout` expects**
(7,492,088 vs 7,492,280). Applied as-is, the engine reads every section 192
bytes late, and the consequences compound:

1. The last 192 bytes of the projection bias fall off the end of the data and
   land on the WASM's own panic strings — literally `"W_out has bias"`.
2. Each LayerNorm bias picks up 48 words of packed-int4 data from the following
   weight block. Decoded as fp32 those are ~1e+13 … 1e+25.
3. A 1e+25 LayerNorm bias makes BitLinear's internal LayerNorm overflow:
   `var` → `Inf` → `inv_std` → 0, so every Q/K/V collapses to exactly zero.
4. `embed()` still returns a unit-length vector and still "works", so nothing
   errors — but **it returns the same vector for every input**. Search silently
   returns one fixed ranking for every query.

The engine is **not** at fault. `compute_layout` is correct; the blob's
*embedding section* is shorter than it assumes. `training/pack/encoders.py`
packs `vocab × (d_model/2)` = 30522 rows, but the data holds **30521** rows
(30521 × 192 = 5,860,032, not 5,860,224).

`scripts/rebuild-model-from-wasm.mjs` repacks the blob with that correction.
It reads each section at the *measured* offsets and writes it at the *engine's*
offsets, zero-filling the 192-byte gap. The vendored engine is never touched.

#### How the 192 bytes were pinned

`encode_embedding_int4` forces `scales[0] = 0.0` for the padding row and zeroes
row 0's packed bytes. An **exact fp32 `0.0` followed by ~30,000 plausible
positive floats** is not a coincidence, so it fixes the start of the scale array
unambiguously: **5,860,064**, not the 5,860,256 that `compute_layout` computes.

Corroboration, all independent:
- the file then totals exactly 7,492,088 — matching where the float data ends;
- all twelve BitLinear scales become plausible **positive** values (several were
  *negative* before, which is impossible for a weight scale);
- every LayerNorm bias, both projection arrays, and `scales[0] == 0` check out;
- the measured section boundaries coincide with an independent fp32-region
  detector (`6,132,692` = W_out scale, `6,438,364` = fc2 scale, `6,590,444` =
  layer-1 W_out scale — all exact).

#### What is ruled out, all empirically

| Suspect | Verdict | Evidence |
| --- | --- | --- |
| `catalog.json` / base64 encoding | **ruled out** | The site's own WASM engine reproduces every `catalog.json` vector at cosine **1.0000002**, with zero dimensions differing by more than 0.01. `scripts/generate-wasm-fixture.mjs` builds the fixture from the engine directly, so the JSON is no longer even in the loop. |
| Wrong model (d256 vs d384) | **was a bug, fixed** | Every HF `wenshutang/ternlight` checkpoint is d_model=256/n_heads=4/ffn=1024; the site uses 384/6/1536. Same 384-dim *output* width, which is why nothing failed loudly. |
| Tokenizer | **ruled out** | Byte-identical to the wasm's embedded copy (sha256 `d241a60d…`), and both produce the same id sequence (`active=23`, identical prefix) for the product texts. |
| Scalar vs SIMD matmul | **ruled out, by inspection** | Both are *exact integer* arithmetic — `i8 × i8 → i32` with no floating point — so they cannot disagree. (The old "bit-identical, max diff 0" check was measured on the host, where `#[cfg(not(target_arch = "wasm32"))]` compiles the scalar fallback and the SIMD path does not even exist. It compared scalar to scalar.) |
| Section offsets | **was the bug, fixed** | The 192-byte misalignment above. |
| Forward-pass math | **matches the reference** | `rust/src/engine/inference.rs` + `kernels.rs` follow `training/pack/unpack.py` step for step: parameterless LN → per-token AbsMax → round/clamp to int8 → i8 matmul → `+bias` in pre-rescale space → divide by `(w_scale * x_scale)`; GELU is the exact erf form; attention is `[T, n_heads, d_head]` with `1/√d_head`. Ternary codes unpack low-bits-first with `0b01→+1`, `0b10→−1`, exactly as the packer wrote them. |

#### Next step

The engine and the file now agree with the reference, so the remaining gap is
in the **data the repack cannot verify**: the packed ternary blocks themselves
have no self-describing structure, so nothing checks that the right 36,864
bytes were copied. The one thing that would settle it is a stage-by-stage
differential against a second implementation reading the *same* file:

1. Port `unpack.py::UnpackedModel.forward` to JS (≈150 lines; the format is now
   fully known) and run it against the rebuilt `model.bin`.
2. If JS reproduces the WASM, the Rust engine diverges and each stage can be
   bisected. If JS does *not* reproduce the WASM, the repacked bytes are wrong
   and the 30521-row reading is the thing to re-examine.

Until that lands, treat search as **unverified**. It is no longer input-blind,
which is a real improvement, but it does not yet match the site.

#### Traps worth remembering

- **"The extracted weights are byte-identical to the wasm" was circular.** The
  comparison was `model.bin` against the very wasm slice it was cut from. It
  proved a file equals itself. Never compare an artefact to its own source.
- **`ranking_scores_match_the_site` is not a parity test.** It scores the app's
  own query vector against the site's stored vectors, so it passes for *any*
  embedding. `native_reproduces_every_site_vector` is the only real check.
- **The engine's `debug_assert` in `compute_layout` disagrees with the real
  file by 192 bytes.** It is a `debug_assert`, so the WASM release build never
  trips it. This is not noise — it was the whole bug. Treat it as a bug report.
- **The WASM build carries no trailing SHA-256**, so `format.rs::verify_sha256`
  cannot be satisfied by the extracted blob; the scripts recompute one.
- Three separate probe scripts produced wrong answers from **the same class of
  bug**: `subarray(32)` (stripping the header) combined with offsets that were
  *already* header-inclusive, silently shifting every reading by 32 bytes. Pick
  one coordinate system and never mix.

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

**The parity tolerance cannot be zero.** WASM accumulates the matmul in 16
lanes of `i32` SIMD; the scalar path accumulates one at a time. Different
summation order over `f32`, so the two builds differ in the last bits. The
test allows `1e-3` per dimension and demands cosine ≥ `0.9999`. That is far
tighter than any semantic difference — two different models score below 0.9 —
so it catches a model swap and ignores rounding.

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
- [x] ~~Run the parity test~~ — it runs, and correctly reports failure.
- [x] ~~Fix the 192-byte section misalignment~~ — the app was returning the
      same embedding for every input; see §3. Parity itself is still open.
- [ ] **Close the parity gap.** `native_reproduces_every_site_vector` is the one
      red test. See "Next step" in §3 — port `unpack.py`'s forward pass to JS and
      bisect against the rebuilt `model.bin`.

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