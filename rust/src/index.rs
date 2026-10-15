//! The product vector index and ranking.
//!
//! This is the part ternlight does not have. On the website the index lives in
//! SQLite (`product_vectors`) and the ranking is a loop in `search.js`; here it
//! is held in memory behind a mutex and crossed into Dart by value.
//!
//! # Ranking is a plain dot product, on purpose
//!
//! Both the site and this app rank with `dot(a, b)` over L2-normalised
//! vectors. MEMORY.md records that an earlier BM25/IDF weighting was removed
//! because it is meaningless across dense embedding dimensions. Nothing here
//! should reintroduce one.
//!
//! # Vectors are defensively re-normalised
//!
//! ternlight always returns unit vectors, and the site's vectors came from
//! ternlight, so normalising here should be a no-op. It is done anyway
//! because a dot product silently stops meaning "cosine similarity" the moment
//! a malformed export hands us an unnormalised row, and a wrong-but-plausible
//! ranking is much harder to notice than a rejected load.

use std::fmt;

use crate::EMBEDDING_DIMS;

/// A ranked result. `score` is a cosine similarity in `[-1, 1]`.
#[derive(Debug, Clone, PartialEq)]
pub struct Hit {
    pub slug: String,
    pub score: f32,
}

#[derive(Debug)]
pub enum IndexError {
    /// A vector was not `EMBEDDING_DIMS` long. In practice this means the
    /// vectors were produced by a different model, and the dot product would
    /// be meaningless — so it is refused rather than padded.
    WrongDimensions { slug: String, got: usize },
    /// `slugs` and `vectors` disagreed in length.
    MismatchedLength { slugs: usize, vectors: usize },
    /// Zero vectors cannot be normalised; excluded rather than turned into NaN.
    ZeroVector { slug: String },
    /// No vectors at all. Search against an empty index returns nothing, which
    /// is indistinguishable from a broken index — so it is an error.
    Empty,
}

impl fmt::Display for IndexError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            IndexError::WrongDimensions { slug, got } => write!(
                f,
                "vector for '{slug}' has {got} dims, expected {EMBEDDING_DIMS} — \
                 the catalog was indexed with a different model; rebuild it"
            ),
            IndexError::MismatchedLength { slugs, vectors } => write!(
                f,
                "{slugs} slugs but {vectors} vectors — slugs and vectors must line up 1:1"
            ),
            IndexError::ZeroVector { slug } => {
                write!(f, "vector for '{slug}' is all zeroes and cannot be normalised")
            }
            IndexError::Empty => f.write_str("index is empty"),
        }
    }
}

impl std::error::Error for IndexError {}

/// An immutable, memory-resident set of product vectors.
#[derive(Debug, Clone, Default)]
pub struct ProductIndex {
    /// `slugs[i]` is the product whose vector starts at `i * EMBEDDING_DIMS`.
    /// Keeping slugs and vectors as parallel arrays avoids a `Vec<Vec<f32>>`
    /// of separately-allocated rows, which for a small catalog is measurably
    /// slower to walk and much harder to hand across the FFI boundary.
    slugs: Vec<String>,
    /// Row-major, L2-normalised, `EMBEDDING_DIMS` per row.
    vectors: Vec<f32>,
}

impl ProductIndex {
    /// Build an index from parallel `slugs` / `vectors` arrays.
    ///
    /// Returns an error rather than a degraded index: every way this can be
    /// wrong produces a plausible-looking but incorrect ranking, which is the
    /// failure mode MEMORY.md §4 is largely about.
    pub fn build(slugs: Vec<String>, vectors: Vec<Vec<f32>>) -> Result<Self, IndexError> {
        if slugs.len() != vectors.len() {
            return Err(IndexError::MismatchedLength {
                slugs: slugs.len(),
                vectors: vectors.len(),
            });
        }
        if slugs.is_empty() {
            return Err(IndexError::Empty);
        }

        let mut flat = Vec::with_capacity(slugs.len() * EMBEDDING_DIMS);
        for (slug, vec) in slugs.iter().zip(vectors.into_iter()) {
            if vec.len() != EMBEDDING_DIMS {
                return Err(IndexError::WrongDimensions {
                    slug: slug.clone(),
                    got: vec.len(),
                });
            }
            let norm = l2_norm(&vec);
            if norm <= f32::EPSILON {
                return Err(IndexError::ZeroVector { slug: slug.clone() });
            }
            for v in vec {
                flat.push(v / norm);
            }
        }

        Ok(ProductIndex { slugs, vectors: flat })
    }

    pub fn len(&self) -> usize {
        self.slugs.len()
    }

    pub fn is_empty(&self) -> bool {
        self.slugs.is_empty()
    }

    pub fn slugs(&self) -> &[String] {
        &self.slugs
    }

    /// Embed `query`, then rank it against every product by dot product.
    ///
    /// `limit` is clamped to `len()`. Ties break on slug so the order is
    /// stable — two products with identical descriptions would otherwise swap
    /// between runs and make the UI look buggy.
    pub fn search_text(&self, query: &str, limit: usize) -> Result<Vec<Hit>, IndexError> {
        let q = crate::inference::embed(query);
        if q.len() != EMBEDDING_DIMS {
            return Err(IndexError::WrongDimensions {
                slug: "<query>".to_string(),
                got: q.len(),
            });
        }
        Ok(self.search_vector(&q, limit))
    }

    /// Rank a pre-computed query vector against the index.
    pub fn search_vector(&self, query: &[f32], limit: usize) -> Vec<Hit> {
        let n = self.slugs.len();
        let take = limit.min(n);

        let mut hits: Vec<Hit> = (0..n)
            .map(|i| {
                let row = &self.vectors[i * EMBEDDING_DIMS..(i + 1) * EMBEDDING_DIMS];
                let score = dot(query, row);
                Hit { slug: self.slugs[i].clone(), score }
            })
            .collect();

        hits.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.slug.cmp(&b.slug))
        });
        hits.truncate(take);
        hits
    }
}

#[inline]
fn dot(a: &[f32], b: &[f32]) -> f32 {
    // Debug-only length check: in release the two slices are always
    // EMBEDDING_DIMS because `search_vector` is called with a checked query
    // and every stored row is checked in `build`.
    debug_assert_eq!(a.len(), b.len());
    let mut acc = 0f32;
    for i in 0..a.len().min(b.len()) {
        acc += a[i] * b[i];
    }
    acc
}

#[inline]
fn l2_norm(v: &[f32]) -> f32 {
    let mut acc = 0f32;
    for &x in v {
        acc += x * x;
    }
    acc.sqrt()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A unit vector with `dim` at index `at` — an exact, reproducible fixture.
    fn axis(dim: usize, at: usize) -> Vec<f32> {
        let mut v = vec![0f32; dim];
        v[at] = 1.0;
        v
    }

    #[test]
    fn build_rejects_wrong_dimensions() {
        let err = ProductIndex::build(vec!["a".into()], vec![vec![0f32; 128]])
            .expect_err("128 dims must be rejected");
        assert!(matches!(err, IndexError::WrongDimensions { got: 128, .. }));
    }

    #[test]
    fn build_rejects_empty_index() {
        assert!(matches!(
            ProductIndex::build(vec![], vec![]),
            Err(IndexError::Empty)
        ));
    }

    #[test]
    fn build_rejects_length_mismatch() {
        let err = ProductIndex::build(vec!["a".into(), "b".into()], vec![axis(EMBEDDING_DIMS, 0)]);
        assert!(matches!(err, Err(IndexError::MismatchedLength { slugs: 2, vectors: 1 })));
    }

    #[test]
    fn build_rejects_zero_vector() {
        assert!(matches!(
            ProductIndex::build(vec!["a".into()], vec![vec![0f32; EMBEDDING_DIMS]]),
            Err(IndexError::ZeroVector { .. })
        ));
    }

    #[test]
    fn identical_vectors_score_one() {
        let v = axis(EMBEDDING_DIMS, 7);
        let idx = ProductIndex::build(vec!["a".into()], vec![v.clone()]).unwrap();
        let hits = idx.search_vector(&v, 10);
        assert_eq!(hits.len(), 1);
        assert!((hits[0].score - 1.0).abs() < 1e-6, "got {}", hits[0].score);
    }

    #[test]
    fn orthogonal_vectors_score_zero() {
        let idx = ProductIndex::build(
            vec!["a".into(), "b".into()],
            vec![axis(EMBEDDING_DIMS, 0), axis(EMBEDDING_DIMS, 1)],
        )
        .unwrap();
        let hits = idx.search_vector(&axis(EMBEDDING_DIMS, 0), 10);
        assert!((hits[0].score).abs() < 1e-6);
    }

    #[test]
    fn unnormalised_input_is_normalised() {
        // Same direction, magnitude 3 vs 1 — cosine must ignore the scale.
        let mut big = axis(EMBEDDING_DIMS, 3);
        for x in &mut big {
            *x *= 3.0;
        }
        let idx = ProductIndex::build(vec!["a".into()], vec![big]).unwrap();
        let hits = idx.search_vector(&axis(EMBEDDING_DIMS, 3), 1);
        assert!((hits[0].score - 1.0).abs() < 1e-6, "got {}", hits[0].score);
    }

    #[test]
    fn results_are_sorted_descending() {
        let idx = ProductIndex::build(
            vec!["a".into(), "b".into(), "c".into()],
            vec![
                axis(EMBEDDING_DIMS, 0),
                axis(EMBEDDING_DIMS, 1),
                axis(EMBEDDING_DIMS, 2),
            ],
        )
        .unwrap();
        let hits = idx.search_vector(&axis(EMBEDDING_DIMS, 2), 3);
        assert_eq!(hits.iter().map(|h| h.slug.as_str()).collect::<Vec<_>>(), ["c", "b", "a"]);
    }

    #[test]
    fn limit_is_clamped_to_index_size() {
        let idx = ProductIndex::build(vec!["a".into()], vec![axis(EMBEDDING_DIMS, 0)]).unwrap();
        assert_eq!(idx.search_vector(&axis(EMBEDDING_DIMS, 0), 99).len(), 1);
    }

    #[test]
    fn ties_break_on_slug_deterministically() {
        let same = axis(EMBEDDING_DIMS, 5);
        let idx = ProductIndex::build(
            vec!["zebra".into(), "apple".into(), "mango".into()],
            vec![same.clone(), same.clone(), same],
        )
        .unwrap();
        let hits = idx.search_vector(&axis(EMBEDDING_DIMS, 5), 3);
        assert_eq!(
            hits.iter().map(|h| h.slug.as_str()).collect::<Vec<_>>(),
            ["apple", "mango", "zebra"],
            "equal scores must order by slug so the UI is stable"
        );
    }
}