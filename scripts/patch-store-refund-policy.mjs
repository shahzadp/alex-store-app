#!/usr/bin/env node
/**
 * Patch the Store repo's `db.js` so the refund policy reaches every product,
 * on the site and in the app, without a new APK.
 *
 * WHY A SCRIPT AND NOT A TEXT EDIT
 * db.js contains \n, \r\n and \r\r\n line endings in the same file (154 / 44 /
 * 471 at the time patch-store-catalog-json.mjs was written). Anything that
 * matches on newlines silently fails to find its anchor, and anything that
 * rewrites the file can normalise sixteen hundred lines of endings into a diff
 * nobody can review. CATALOG-GUIDE.md §10 says the same thing. So: single-line
 * anchors, and `readFileSync`/`writeFileSync` with no transformation of the
 * bytes in between.
 *
 * WHAT IT CHANGES
 *   - adds `REFUND_POLICY` (the wording) and the two helpers over it;
 *   - `toJson()` appends the note to every product's `details`;
 *   - the returned Catalog object exposes `REFUND_POLICY` and
 *     `stripRefundPolicy`, which `product.js` uses to show the same words on
 *     the product page.
 *
 * WHY `details`, AND WHY ONLY IN THE JSON
 * `catalog.json` is the only file the Flutter app can read, and the app renders
 * exactly three per-product text fields: `description` (embedded for search,
 * and pasted into the WhatsApp message — both wrong places for a policy),
 * `specs` (a label/value table), and `details`. `details` is the only one that
 * is neither searchable nor sent to the shop, so the note goes there — which is
 * what makes a policy change reach phones that already have the app, with no
 * re-index and no new build.
 *
 * Appending in `toJson()` rather than into the `products` table is deliberate:
 * the shop's own copy stays clean, the admin's editor never shows the note, and
 * a product added next month cannot miss it. `toJson()` is also the one export
 * path that both the admin's Download button and
 * `scripts/regen-catalog-json.mjs` drive.
 *
 * THE WORDING IS ONE SENTENCE, ON PURPOSE
 * "Once an order has been dispatched, a cancellation fee applies." A longer
 * paragraph reads as a wall of small print under a product's description, and
 * the rest of the policy - the refund window, who pays the return, how refunds
 * are paid - belongs on the About page, which is where a shopper goes when they
 * actually care. The product page prints exactly this line from this constant;
 * the app prints it as the last line of the product's "Full description".
 *
 * IDEMPOTENT. Re-running after the patch is a no-op.
 */

import { readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const TARGET = resolve(HERE, '..', '..', 'Store', 'db.js');

let src = readFileSync(TARGET, 'utf8');
let changed = 0;

function patch(anchor, replacement, label, marker) {
  if (src.includes(marker)) {
    console.log(`  = ${label} (already applied)`);
    return;
  }
  const occurrences = src.split(anchor).length - 1;
  if (occurrences !== 1) {
    throw new Error(`anchor for "${label}" matched ${occurrences} times, expected exactly 1`);
  }
  src = src.replace(anchor, replacement);
  changed++;
  console.log(`  + ${label}`);
}

// ── 1. The wording, and the helpers over it ────────────────────────────────

const POLICY = String.raw`const REFUND_POLICY = {
  heading: 'Refunds and cancellations',
  note: 'Once an order has been dispatched, a cancellation fee applies.',
};

/** The exact text toJson() appends, and the only thing stripRefundPolicy
 *  removes. Built from REFUND_POLICY so the two cannot drift apart. */
function refundBlock() {
  return '\n\n' + REFUND_POLICY.note;
}

/** A product's copy with any appended note taken back off.
 *
 *  Trims, so re-exporting a catalog that already carries the note cannot stack
 *  a second copy - the admin's editor may have been seeded from a published
 *  catalog.json, note and all. That is also why the older, longer wording is
 *  removed on sight: the catalog.json published on 16 Oct 2026 carried a
 *  paragraph beginning "Refund policy: ", and a product showing both would read
 *  as two different promises.
 *
 *  The old text is matched whole and exactly. Anything that is not that string
 *  is the shopkeeper's own copy, and is left alone. */
const REFUND_LEGACY =
  '\n\nRefund policy: Cancel free before dispatch; a cancellation fee applies after dispatch. ' +
  'Damaged or wrong items are replaced or refunded in full if reported within 7 days. ' +
  'Full policy is on the About page.';

function stripRefundPolicy(text) {
  const body = String(text || '')
    .split(refundBlock())
    .join('')
    .split(REFUND_LEGACY)
    .join('')
    .trim();
  // A product with no copy at all exports as the bare note, with no blank line
  // in front of it. Without this it would grow a second copy on every export.
  return body === REFUND_POLICY.note ? '' : body;
}

/** A product's copy with the note on the end. */
function withRefundPolicy(text) {
  const body = stripRefundPolicy(text);
  return body ? body + refundBlock() : REFUND_POLICY.note;
}`;

patch(
  `const SEARCH_DIMS = 384;`,
  `const SEARCH_DIMS = 384;

// The refund policy, in one place.
//
// THREE consumers need the same words, and two of them cannot see each other:
//
//   * catalog.json, which is the only file the Flutter app can read. toJson()
//     appends the note to every product's \`details\`, because the app renders
//     exactly three per-product text fields and \`details\` is the only one that
//     is neither embedded for search nor pasted into the WhatsApp message. That
//     is what carries a policy change to phones that already have the app.
//   * product.js, which shows the note under every product's full description.
//   * src/about.html, which carries the full wording and the cancellation fee.
//
// The About page is static copy on purpose - it should still state the policy
// if a script fails to load - so it is NOT generated from this constant, and
// the two must agree: if the fee or the window ever changes, change both. The
// product page and the app cannot drift apart, because they read this.
${POLICY}`,
  'REFUND_POLICY + helpers',
  'const REFUND_POLICY = {',
);

// ── 2. toJson() appends it to every product's details ──────────────────────

patch(
  `      details: p.details || '',`,
  `      // The refund note is appended here, not stored in the products table:
      // the shop's own copy stays clean, and a product added later cannot miss
      // it. \`p.details || p.description\` keeps the app's own fall-back - it
      // shows the one-line description when there is no long copy - and then
      // adds the note, so nothing that used to be visible stops being visible.
      details: withRefundPolicy(p.details || p.description || ''),`,
  'toJson() appends the note to details',
  'details: withRefundPolicy(',
);

// ── 3. Expose it to the pages ──────────────────────────────────────────────

patch(
  `    getSetting,`,
  `    getSetting,

    REFUND_POLICY,

    stripRefundPolicy,`,
  'Catalog exposes REFUND_POLICY and stripRefundPolicy',
  `    REFUND_POLICY,

    stripRefundPolicy,`,
);

// ── 4. And in the store block, for a future app build ──────────────────────

patch(
  `          currency: 'PKR',`,
  `          currency: 'PKR',
          // The same words as the note appended to every product's \`details\`,
          // for an app build that would rather render the policy as its own
          // element than as the tail of a description. Nothing reads this
          // today; it is here so the data exists before the code needs it.
          refund_policy: {
            heading: REFUND_POLICY.heading,
            note: REFUND_POLICY.note,
          },`,
  'store.refund_policy in catalog.json',
  'refund_policy: {',
);

// ── write ───────────────────────────────────────────────────────────────────

if (changed === 0) {
  console.log('\nNothing to do: db.js already carries all four patches.');
} else {
  writeFileSync(TARGET, src, 'utf8');
  console.log(`\nWrote ${TARGET} (${changed} change${changed === 1 ? '' : 's'}).`);
  console.log('Byte-for-byte elsewhere: only the four anchors were replaced.');
}
