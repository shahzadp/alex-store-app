//! Alex Store — native search engine.
//!
//! This crate is ternlight's inference engine, vendored from
//! <https://github.com/soycaporal/ternlight> (MIT) and compiled for Android
//! instead of WebAssembly. The storefront at shahzadp.github.io/store runs the
//! same weights through WebAssembly; the Android app cannot, because Dart
//! cannot host a WASM runtime. Running the same Rust natively means the app
//! ranks with the same vectors the site does, offline, with no model download.
//!
//! # Layout
//!
//! ```text
//! src/engine/   vendored from ternlight, byte-for-byte unmodified
//! src/assets/   model.bin + tokenizer.json (include_bytes! targets)
//! src/index.rs  ours: the product vector index and ranking
//! src/api.rs    ours: the flutter_rust_bridge surface
//! ```
//!
//! # Why `#[path]` instead of a `mod` tree
//!
//! The vendored files use `crate::format::`, `crate::model::` and friends. A
//! normal `src/engine/mod.rs` would break those and force edits. `#[path]`
//! lifts each module to the crate root so every `crate::` reference keeps
//! resolving and **the vendored sources stay byte-identical to upstream** —
//! which is what makes `git diff` against ternlight meaningful when we upgrade.
//!
//! `src/assets/` rather than `rust/assets/` is forced by the same concern:
//! `model.rs` does `include_bytes!("../assets/model.bin")`, which resolves
//! relative to the source file. Placing the assets one level up keeps that
//! line untouched as well.

#![forbid(unsafe_op_in_unsafe_fn)]

// ── Compile-time guards, reproduced from ternlight's own lib.rs ─────────────
//
// We do not vendor ternlight's lib.rs (its whole surface is #[wasm_bindgen]),
// so its two compile_error! guards come with it and are restated here.

#[cfg(not(any(
    feature = "emb_fp32",
    feature = "emb_int8",
    feature = "emb_ternary",
    feature = "emb_int4",
)))]
compile_error!(
    "alex_store_native requires exactly one embedding-format feature: \
     emb_fp32, emb_int8, emb_ternary or emb_int4. The vendored engine \
     dispatches on these to pick a wire format. The default build uses \
     emb_int4, which matches the site's product_vectors."
);

#[cfg(any(
    all(feature = "emb_fp32", feature = "emb_int8"),
    all(feature = "emb_fp32", feature = "emb_ternary"),
    all(feature = "emb_fp32", feature = "emb_int4"),
    all(feature = "emb_int8", feature = "emb_ternary"),
    all(feature = "emb_int8", feature = "emb_int4"),
    all(feature = "emb_ternary", feature = "emb_int4"),
))]
compile_error!(
    "alex_store_native accepts exactly one embedding-format feature. \
     Pick one of: emb_fp32 | emb_int8 | emb_ternary | emb_int4."
);

// The vendored BitLinear matmul uses WASM 128-bit SIMD intrinsics and falls
// back to a scalar loop on every other target. That fallback is correct, just
// slower, so it is a perf note rather than a build error — see `docs/PERF.md`.
#[cfg(all(target_arch = "wasm32", not(target_feature = "simd128")))]
compile_error!(
    "ternlight's BitLinear matmul needs WASM SIMD (+simd128) on wasm32. \
     Pass it via RUSTFLAGS. Not relevant to the Android build."
);

// ── Vendored ternlight engine ───────────────────────────────────────────────

#[path = "engine/format.rs"]
pub mod format;

#[path = "engine/tokenizer.rs"]
pub mod tokenizer;

#[path = "engine/model.rs"]
pub mod model;

#[path = "engine/kernels.rs"]
pub mod kernels;

#[path = "engine/inference.rs"]
pub mod inference;

// ── Ours ────────────────────────────────────────────────────────────────────

pub mod index;

#[cfg(feature = "frb")]
pub mod api;

/// Dimensions of a ternlight embedding. The site asserts this same number in
/// `db.js` as SEARCH_DIMS, and `product_vectors` rows decode to exactly this
/// length — a mismatch means the vectors were built by a different model and
/// the dot product is meaningless.
pub const EMBEDDING_DIMS: usize = 384;

/// The exact text the site's admin panel embeds for each product. See
/// CATALOG-GUIDE.md §4. Kept here so the parity harness can regenerate the
/// site's vectors and prove we still agree.
///
///     `${name}. ${category}. ${description}`.trim()
pub fn product_embedding_text(name: &str, category: &str, description: &str) -> String {
    format!("{}. {}. {}", name, category, description).trim().to_string()
}

/// Force the 4.6 MB model to parse, the tokenizer to build and every ternary
/// weight to unpack. Worth calling once at app start: it is ~150 ms of
/// one-time work that would otherwise land on the user's first search, and it
/// surfaces a bad `model.bin` at launch instead of at query time.
///
/// Idempotent and safe to call from any thread.
pub fn warm_up() {
    let _ = inference::embed("warm up");
}