//! Native-vs-site parity.
//!
//! This is the test that justifies the whole native rewrite. The website
//! embeds product text through ternlight's **WebAssembly** engine and ships
//! the resulting vectors in `catalog.sql`. This crate embeds the same text
//! through the **same ternlight engine, compiled for the host/Android**. If
//! these two ever disagree, every search result in the app is wrong in a way
//! nobody can see — there is no server to compare against and no error is
//! raised. A dot product of two different models still returns a plausible
//! ranking.
//!
//! So: `scripts/extract-site-vectors.mjs` lifts the site's published vectors
//! out of `catalog.sql`, and the tests below re-derive them natively and
//! compare.
//!
//! Re-extract after any catalog or model change:
//!
//! ```sh
//! node scripts/extract-site-vectors.mjs
//! cargo test -p alex_store_native --test parity
//! ```

use std::path::PathBuf;

use alex_store_native::index::ProductIndex;
use alex_store_native::{inference, EMBEDDING_DIMS};

const FIXTURE: &str = "tests/fixtures/site_vectors.json";

/// Per-dimension tolerance for native-vs-WASM.
///
/// Not zero, and cannot be: the WASM build sums the BitLinear matmul in 16
/// lanes of `i32` SIMD accumulate, while this build walks the scalar fallback
/// (there is no `core::arch::aarch64` SIMD path yet — see docs/PERF.md).
/// Different summation order over f32 gives different rounding, so the two
/// builds agree to roughly float precision rather than bit-for-bit.
///
/// This bound is far tighter than any *semantic* difference would produce. Two
/// genuinely different models score cosine < 0.9 against each other, so a
/// 1e-3 gate cannot be tripped by a model swap, a tokenizer change or a
/// mismatched `.bin` — only by numerical noise.
const DIM_TOLERANCE: f32 = 1e-3;

/// Cosine between the native vector and the site's vector for the same text.
///
/// The assertion that actually matters. Two vectors from the same model score
/// ≈ 1.0 even across summation orders; two from different models do not.
const COSINE_FLOOR: f32 = 0.9999;

struct FixtureProduct {
    slug: String,
    name: String,
    category: String,
    description: String,
    text: String,
    vector: Vec<f32>,
}

fn load_fixture() -> Vec<FixtureProduct> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(FIXTURE);
    let raw = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        panic!(
            "cannot read {}: {e}\n\
             Regenerate it from the site repo:\n  \
             node scripts/extract-site-vectors.mjs",
            path.display()
        )
    });

    let v: serde_json::Value = serde_json::from_str(&raw).expect("fixture is not valid JSON");

    assert_eq!(
        v["dims"].as_u64().expect("fixture has no dims") as usize,
        EMBEDDING_DIMS,
        "fixture was built for a different embedding width"
    );
    assert_eq!(
        v["model"].as_str().unwrap_or(""),
        "ternlight/base@0.1.1",
        "fixture model does not match SEARCH_MODEL in src/api.rs — the site changed \
         encoder, so every vector needs a full reindex on both sides"
    );

    v["products"]
        .as_array()
        .expect("fixture has no products array")
        .iter()
        .map(|p| FixtureProduct {
            slug: p["slug"].as_str().expect("product without slug").to_string(),
            name: p["name"].as_str().expect("product without name").to_string(),
            category: p["category"].as_str().expect("product without category").to_string(),
            description: p["description"].as_str().unwrap_or("").to_string(),
            text: p["text"].as_str().expect("product without text").to_string(),
            vector: p["vector"]
                .as_array()
                .expect("product without vector")
                .iter()
                .map(|x| x.as_f64().expect("non-numeric vector element") as f32)
                .collect(),
        })
        .collect()
}

fn dot(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

/// ── The headline test ───────────────────────────────────────────────────────

#[test]
fn native_reproduces_every_site_vector() {
    let products = load_fixture();
    assert!(!products.is_empty(), "fixture is empty");

    for p in &products {
        let native = inference::embed(&p.text);

        assert_eq!(
            native.len(),
            EMBEDDING_DIMS,
            "'{}' produced {} dims, expected {EMBEDDING_DIMS}",
            p.slug,
            native.len()
        );

        let worst = native
            .iter()
            .zip(&p.vector)
            .map(|(a, b)| (a - b).abs())
            .fold(0f32, f32::max);
        assert!(
            worst < DIM_TOLERANCE,
            "'{}' diverges from the site by {worst:.6} per dimension (limit {DIM_TOLERANCE}). \
             Either the weights, the tokenizer or the forward pass differ from the WASM build.",
            p.slug
        );

        let cosine = dot(&native, &p.vector);
        assert!(
            cosine >= COSINE_FLOOR,
            "'{}' has cosine {cosine:.6} against the site's vector (floor {COSINE_FLOOR}). \
             The app is embedding with a different model than the site indexed with.",
            p.slug
        );
    }
}

/// The site computes the embedded text as
/// `${name}. ${category}. ${description}`.trim() (CATALOG-GUIDE.md §4), in
/// `admin.js`. That single expression is the whole searchable text for a
/// product: name and category are a few tokens, the description is the bulk.
///
/// If it ever drifts on either side, every product vector silently describes
/// old text — `indexIsComplete()` stays true, search keeps working, and one
/// product quietly becomes unfindable. Nothing warns you. This asserts the Rust
/// copy of the expression reproduces the text the site actually embedded.
#[test]
fn embedding_text_expression_matches_the_site() {
    for p in load_fixture() {
        let recomposed =
            alex_store_native::product_embedding_text(&p.name, &p.category, &p.description);

        assert_eq!(
            recomposed, p.text,
            "'{}': this crate composes {recomposed:?} but the site embedded {:?}. \
             CATALOG-GUIDE.md §4 defines the expression; if the site changed, \
             the vectors need a full reindex on both sides.",
            p.slug, p.text
        );

        // The engine truncates at 128 tokens. A blurb that overflows gets cut
        // silently, so it is worth knowing if one ever comes close.
        let words = p.text.split_whitespace().count();
        assert!(
            words < 128,
            "'{}' embed text is {words} words, which likely exceeds the engine's \
             128-token cap and would be truncated mid-product",
            p.slug
        );
    }
}

// ── Ranking parity ──────────────────────────────────────────────────────────
//
// Matching vectors is necessary but not sufficient. What the shopper sees is
// an *order*, so the ordering must survive too, and must survive for queries
// that were never used to build the index.

/// Phrasings a shopper would actually type, not product titles. CATALOG-GUIDE
/// §9 asks for exactly this kind of test: if a product can only be found by
/// its exact name, the descriptions are too thin.
const QUERIES: &[&str] = &[
    "something to drink out of",
    "warm up my hands in winter",
    "cooking",
    "gift for a new home",
    "decoration",
    "tableware for dinner parties",
    "candle",
    "flax",
    "brass",
    "dishwasher safe",
];

#[test]
fn ranking_order_matches_the_site() {
    let products = load_fixture();

    let slugs: Vec<String> = products.iter().map(|p| p.slug.clone()).collect();
    let site_vectors: Vec<Vec<f32>> = products.iter().map(|p| p.vector.clone()).collect();
    let native_index =
        ProductIndex::build(slugs.clone(), site_vectors).expect("site vectors must form a valid index");

    for q in QUERIES {
        let query_vec = inference::embed(q);

        // What the site would produce: dot(query, site_vector) over its rows.
        let mut expected: Vec<(String, f32)> = products
            .iter()
            .map(|p| (p.slug.clone(), dot(&query_vec, &p.vector)))
            .collect();
        expected.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap().then_with(|| a.0.cmp(&b.0)));

        // What the app produces: embed natively, rank against the same rows.
        let actual = native_index.search_vector(&query_vec, products.len());

        let expected_order: Vec<&str> = expected.iter().map(|(s, _)| s.as_str()).collect();
        let actual_order: Vec<&str> = actual.iter().map(|h| h.slug.as_str()).collect();

        assert_eq!(
            expected_order, actual_order,
            "ranking order differs for query {q:?}\n  site: {expected_order:?}\n  app : {actual_order:?}"
        );
    }
}

/// Scores must agree too, not just the order — a reordered tie or a shifted
/// score both indicate the two builds have diverged.
#[test]
fn ranking_scores_match_the_site() {
    let products = load_fixture();
    let slugs: Vec<String> = products.iter().map(|p| p.slug.clone()).collect();
    let site_vectors: Vec<Vec<f32>> = products.iter().map(|p| p.vector.clone()).collect();
    let idx = ProductIndex::build(slugs, site_vectors).unwrap();

    for q in QUERIES {
        let query_vec = inference::embed(q);
        let hits = idx.search_vector(&query_vec, products.len());

        let by_slug: std::collections::HashMap<&str, &Vec<f32>> =
            products.iter().map(|p| (p.slug.as_str(), &p.vector)).collect();

        for h in &hits {
            let site_score = dot(&query_vec, by_slug[h.slug.as_str()]);
            assert!(
                (h.score - site_score).abs() < 1e-5,
                "score for '{}' with query {q:?}: app {} vs site {}",
                h.slug,
                h.score,
                site_score
            );
        }
    }
}

// ── Engine sanity ───────────────────────────────────────────────────────────

#[test]
fn engine_reports_the_expected_model() {
    let summary = alex_store_native::model::config_summary();
    assert!(summary.contains("int4"), "expected an int4 build, got: {summary}");
    assert!(summary.contains("d_model=384"), "expected d_model=384, got: {summary}");
    assert!(
        summary.contains("vocab=30522"),
        "expected a BERT-base-uncased vocab of 30522, got: {summary}"
    );
}

#[test]
fn embeddings_are_unit_length() {
    for q in QUERIES {
        let v = inference::embed(q);
        let norm = dot(&v, &v).sqrt();
        assert!(
            (norm - 1.0).abs() < 1e-4,
            "embedding for {q:?} has length {norm}, expected ~1.0 (ranking assumes cosine)"
        );
    }
}

/// Same input, same output. A non-deterministic forward pass would make search
/// results flicker between identical queries.
#[test]
fn embedding_is_deterministic() {
    let a = inference::embed("stoneware mug");
    let b = inference::embed("stoneware mug");
    assert_eq!(a, b);
}

/// Truncation is at 128 tokens. Input well past that must still produce a
/// valid vector rather than panicking or silently returning zeros.
#[test]
fn long_input_is_truncated_not_rejected() {
    let long = "glazed stoneware ".repeat(400);
    let v = inference::embed(&long);
    assert_eq!(v.len(), EMBEDDING_DIMS);
    let norm = dot(&v, &v).sqrt();
    assert!((norm - 1.0).abs() < 1e-4, "got length {norm} for over-long input");
}

/// Guards the failure MEMORY.md §4 calls out: an empty query used to reach the
/// model and produce a meaningless "most similar" result.
#[test]
fn empty_input_still_produces_a_valid_vector() {
    // The engine has no way to signal "no query"; the Dart layer short-circuits
    // before calling. This test documents that the engine is total, so a bug
    // there surfaces here rather than as a panic in the app.
    let v = inference::embed("");
    assert_eq!(v.len(), EMBEDDING_DIMS);
    assert!(v.iter().all(|x| x.is_finite()), "empty input produced NaN/inf");
}