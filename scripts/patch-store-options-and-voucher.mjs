#!/usr/bin/env node
/**
 * Patch the Store repo's `db.js` so the catalog can carry:
 *
 *   1. a per-product `options` list  — selectable add-ons such as "Cold drink";
 *   2. a `delivery_percent` setting   — how much delivery adds to a price;
 *   3. a voucher                      — the free-delivery offer, announced
 *                                       instead of the old top strip.
 *
 * WHY A SCRIPT AND NOT A TEXT EDIT
 * `db.js` contains \n, \r\n and \r\r\n in the same file. An anchor written
 * with plain "\n" silently fails to match a run of "\r\r\n", which is how a
 * patch gets applied twice or not at all. CATALOG-GUIDE.md §10 says the same
 * thing. So every anchor here is turned into a "\r*\n" regex before it is
 * matched, and the file's bytes are never otherwise rewritten.
 *
 * WHAT "options" IS, AND WHAT IT IS NOT
 * An add-on is a *preference*, carried into the WhatsApp message ("Cold drink:
 * yes"). It is not a product, not a second price, and it never changes what a
 * product costs. That keeps the one purchase path (a WhatsApp message) the
 * only place a choice has to be understood.
 *
 * ADDING A COLUMN TOUCHES `db.js` IN FOUR PLACES (CATALOG-GUIDE.md §5):
 *   - the CREATE TABLE copy inside `toSql()`'s template literal;
 *   - the `productLines` serialiser;
 *   - the `INSERT INTO products (...)` column list in that same literal;
 *   - `validate()` plus the INSERT/UPDATE in createProduct/updateProduct.
 * `toJson()` is a fifth, because the app reads that file and needs the field.
 * Missing any one of them fails quietly, so this script changes all five.
 *
 * IDEMPOTENT. Each patch is recognised by an ASCII marker, not by its
 * replacement text (that text carries em dashes, and a mojibake copy in the
 * Store's file makes a replacement-text test read false — see
 * patch-store-catalog-json.mjs for how that once inserted a duplicate).
 *
 * Usage:
 *   node scripts/patch-store-options-and-voucher.mjs
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const TARGET = resolve(HERE, '..', '..', 'Store', 'db.js');

let src = readFileSync(TARGET, 'utf8');
const before = src;
let changed = 0;

const escapeRegExp = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/**
 * Replace one anchor, tolerating any mix of \n, \r\n and \r\r\n inside it.
 *
 * `marker` is an ASCII string unique to the patched state; it, never the
 * replacement text, decides whether the patch is already applied.
 */
function patch(anchor, replacement, label, marker) {
  if (src.includes(marker)) {
    console.log(`  = ${label} (already applied)`);
    return;
  }
  const re = new RegExp(anchor.split('\n').map(escapeRegExp).join('\\r*\\n'));
  const matches = src.match(re);
  const count = matches ? matches.length : 0;
  if (count !== 1) {
    throw new Error(`anchor for "${label}" matched ${count} times, expected exactly 1`);
  }
  src = src.replace(re, () => replacement);
  changed++;
  console.log(`  + ${label}`);
}

// ── 1. The draft key, bumped because the schema changed ─────────────────────

patch(
  `const DRAFT_KEY = 'alexstore.catalogDraft.v3';`,
  `// v4: products gained an \`options\` column (selectable add-ons) and the store
// gained a delivery percentage and a voucher. A v3 draft predates them, so it
// is discarded rather than half-read.
const DRAFT_KEY = 'alexstore.catalogDraft.v4';`,
  'DRAFT_KEY v3 -> v4',
  `alexstore.catalogDraft.v4`,
);

// ── 2. The CREATE TABLE copy inside toSql()'s template literal ──────────────

patch(
  `  -- JSON object of label -> value for the specifications box.
  specs       TEXT,
  image_url   TEXT,`,
  `  -- JSON object of label -> value for the specifications box.
  specs       TEXT,
  -- JSON array of selectable add-ons, e.g.
  -- [{"key":"cold_drink","label":"Cold drink"}]. An add-on is a preference
  -- carried into the WhatsApp message; it never changes the price.
  options     TEXT,
  image_url   TEXT,`,
  'toSql() CREATE TABLE gains options',
  `-- JSON array of selectable add-ons`,
);

// ── 3. The productLines serialiser ──────────────────────────────────────────

patch(
  "          `  (${escape(p.slug)}, ${escape(p.name)}, ${escape(p.description)}, ` +\n" +
    "          `${escape(p.details)}, ${escape(p.specs)}, ${escape(p.category)}, ` +",
  "          `  (${escape(p.slug)}, ${escape(p.name)}, ${escape(p.description)}, ` +\n" +
    "          `${escape(p.details)}, ${escape(p.specs)}, ${escape(p.options)}, ${escape(p.category)}, ` +",
  'toSql() productLines writes options',
  '`${escape(p.specs)}, ${escape(p.options)}, ${escape(p.category)}, `',
);

// ── 4. The INSERT column list inside that literal ───────────────────────────

patch(
  `INSERT INTO products (slug, name, description, details, specs, category, price_cents, image_url, tint, in_stock, sort_order) VALUES`,
  `INSERT INTO products (slug, name, description, details, specs, options, category, price_cents, image_url, tint, in_stock, sort_order) VALUES`,
  'toSql() INSERT column list gains options',
  'details, specs, options, category, price_cents, image_url, tint, in_stock, sort_order) VALUES',
);

// ── 5. optionPairs()/normaliseOptions(), next to the specs helpers ──────────

patch(
  `  /** Parses the stored specs JSON into ordered [label, value] pairs. */
  function specPairs(raw) {
    if (!raw) return [];
    try {
      const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw;
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return [];
      return Object.entries(parsed).filter(([k, v]) => k && v);
    } catch {
      return [];
    }
  }`,
  `  /** Parses the stored specs JSON into ordered [label, value] pairs. */
  function specPairs(raw) {
    if (!raw) return [];
    try {
      const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw;
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return [];
      return Object.entries(parsed).filter(([k, v]) => k && v);
    } catch {
      return [];
    }
  }

  /**
   * Parses a product's selectable add-ons into ordered {key, label} objects.
   *
   * An add-on is a preference, not a price: it is carried into the WhatsApp
   * message so the shop knows what to pack ("Cold drink: yes"). Stored as a
   * JSON array so more can be added without another schema change.
   */
  function optionPairs(raw) {
    if (!raw) return [];
    try {
      const parsed = typeof raw === 'string' ? JSON.parse(raw) : raw;
      if (!Array.isArray(parsed)) return [];
      return parsed
        .map((o) => ({
          key: String((o && o.key) || '').trim(),
          label: String((o && o.label) || '').trim(),
        }))
        .filter((o) => o.key && o.label);
    } catch {
      return [];
    }
  }

  /**
   * Canonical JSON for the \`options\` column, or null when there are none.
   *
   * The admin submits one option label per line; already-stored JSON passes
   * straight back through on edit. The key is derived from the label, so a
   * product saved through the admin cannot lose a mis-typed key.
   */
  function normaliseOptions(input) {
    let rows = [];
    if (typeof input === 'string' && input.trim()) {
      const raw = input.trim();
      if (raw.startsWith('[')) return optionPairs(raw).length ? JSON.stringify(optionPairs(raw)) : null;
      rows = raw.split('\\n').map((line) => line.trim()).filter(Boolean);
    } else if (Array.isArray(input)) {
      rows = input.map((o) => (typeof o === 'string' ? o : (o && (o.label || o.key)) || ''));
    }

    const out = [];
    for (const label of rows.slice(0, 6)) {
      const text = String(label || '').trim().slice(0, 60);
      if (!text || out.some((o) => o.label === text)) continue;
      out.push({ key: slugify(text), label: text });
    }
    return out.length ? JSON.stringify(out) : null;
  }`,
  'optionPairs() + normaliseOptions()',
  'function normaliseOptions(input) {',
);

// ── 6. validate(): read the options, and include them in the value ──────────

patch(
  `    const specs = normaliseSpecs(input.specs);`,
  `    const specs = normaliseSpecs(input.specs);

    // Selectable add-ons, e.g. "Cold drink". A preference, never a price.
    const options = normaliseOptions(input.options);`,
  'validate() reads options',
  `const options = normaliseOptions(input.options);`,
);

patch(
  `        description,
        details,
        specs,
        category,`,
  `        description,
        details,
        specs,
        options,
        category,`,
  'validate() returns options',
  `        specs,
        options,
        category,`,
);

// ── 7. createProduct(): the INSERT ──────────────────────────────────────────

patch(
  "      `INSERT INTO products\n" +
    "         (slug, name, description, details, specs, category, price_cents, image_url, tint, in_stock, sort_order)\n" +
    "       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,\n" +
    "      [value.slug, value.name, value.description, value.details, value.specs,\n" +
    "       value.category, value.price_cents, value.image_url, value.tint,\n" +
    "       value.in_stock, value.sort_order],",
  "      `INSERT INTO products\n" +
    "         (slug, name, description, details, specs, options, category, price_cents, image_url, tint, in_stock, sort_order)\n" +
    "       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,\n" +
    "      [value.slug, value.name, value.description, value.details, value.specs, value.options,\n" +
    "       value.category, value.price_cents, value.image_url, value.tint,\n" +
    "       value.in_stock, value.sort_order],",
  'createProduct() inserts options',
  'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`',
);

// ── 8. updateProduct(): the UPDATE ──────────────────────────────────────────

patch(
  "      `UPDATE products\n" +
    "          SET slug = ?, name = ?, description = ?, details = ?, specs = ?,\n" +
    "              category = ?, price_cents = ?, image_url = ?, tint = ?,\n" +
    "              in_stock = ?, sort_order = ?\n" +
    "        WHERE id = ?`,\n" +
    "      [value.slug, value.name, value.description, value.details, value.specs,\n" +
    "       value.category, value.price_cents, value.image_url, value.tint,\n" +
    "       value.in_stock, value.sort_order, id],",
  "      `UPDATE products\n" +
    "          SET slug = ?, name = ?, description = ?, details = ?, specs = ?, options = ?,\n" +
    "              category = ?, price_cents = ?, image_url = ?, tint = ?,\n" +
    "              in_stock = ?, sort_order = ?\n" +
    "        WHERE id = ?`,\n" +
    "      [value.slug, value.name, value.description, value.details, value.specs, value.options,\n" +
    "       value.category, value.price_cents, value.image_url, value.tint,\n" +
    "       value.in_stock, value.sort_order, id],",
  'updateProduct() writes options',
  'details = ?, specs = ?, options = ?,',
);

// ── 9. toJson(): each product carries its options ───────────────────────────

patch(
  `      image_url: p.image_url || null,
      tint: p.tint || null,
      vector: vectorFor(p.slug),
    }));`,
  `      image_url: p.image_url || null,
      tint: p.tint || null,
      // Selectable add-ons (e.g. "Cold drink"), as stored. The buyer's choice
      // travels in the WhatsApp message; the price never changes.
      options: optionPairs(p.options),
      vector: vectorFor(p.slug),
    }));`,
  'toJson() products include options',
  `options: optionPairs(p.options),`,
);

// ── 10. toJson(): the store carries the delivery percent and the voucher ────

patch(
  `          free_delivery_over_paisa: Number(settings.free_delivery_over_paisa || 0),
          currency: 'PKR',`,
  `          free_delivery_over_paisa: Number(settings.free_delivery_over_paisa || 0),
          // Delivery is a percentage of the order. Both surfaces show the
          // pre-delivery price struck through and the price itself unchanged,
          // so a percentage is the only number either of them needs. One
          // setting, read by the site AND the app, so they cannot disagree.
          delivery_percent: Number(settings.delivery_percent || 0),
          // The free-delivery offer, announced as a claimable voucher instead
          // of the old top strip. The threshold itself stays in
          // free_delivery_over_paisa; this is only how it is worded.
          voucher: {
            title: settings.voucher_title || 'Free delivery',
            code: settings.voucher_code || '',
            description: settings.voucher_description || '',
            terms: settings.voucher_terms || '',
          },
          currency: 'PKR',`,
  'toJson() store gains delivery_percent + voucher',
  `voucher: {`,
);

// ── 11. Expose optionPairs to the admin and the pages ───────────────────────

patch(
  `    specPairs,
    SEARCH_MODEL,`,
  `    specPairs,
    optionPairs,
    SEARCH_MODEL,`,
  'Catalog exposes optionPairs',
  `    optionPairs,`,
);

// ── write ───────────────────────────────────────────────────────────────────

if (src === before) {
  console.log('\nNothing to do: db.js already carries every patch.');
} else {
  writeFileSync(TARGET, src, 'utf8');
  console.log(`\nWrote ${TARGET} (${changed} change${changed === 1 ? '' : 's'}).`);
  console.log('Only the anchored regions changed; every other byte is as it was.');
}
