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
- **Nothing has been compiled or run.** No Flutter SDK, no Android SDK build,
  no device, no emulator. Every claim about runtime behaviour is from code
  review, not observation. Treat it as a design that has been written down
  carefully, not as something that works.

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

- [ ] **Generate `android/`.** It comes from `flutter create`; nothing in this
      repo can produce it without the Flutter SDK.
- [ ] **Run `flutter_rust_bridge_codegen`.** `lib/src/api/` does not exist, so
      `rust_search_engine.dart` does not compile yet. That is the first thing
      to break on the first build.
- [ ] **Compile the Rust crate.** The vendored engine has never been built for
      a non-wasm target in this repo. `cd rust && cargo test` is the check.
- [ ] **Run the parity test against the real site vectors.** The fixture is
      extracted and validated; the assertion has never executed.

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