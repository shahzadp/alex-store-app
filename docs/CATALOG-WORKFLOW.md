# Changing the catalog

## One command

```bash
node scripts/publish-catalog.mjs
```

That is the whole workflow. It:

1. rebuilds `catalog.json` from `catalog.sql`, including every vector
2. proves `catalog.json` and `catalog.sql` agree
3. shows what changed, **before** committing
4. bumps the site's cache-buster and rebuilds its HTML
5. commits and pushes the site
6. waits for the published file to actually go live

Flags:

```bash
node scripts/publish-catalog.mjs --dry-run      # print every step, execute none
node scripts/publish-catalog.mjs --no-push      # rebuild locally, commit nothing
node scripts/publish-catalog.mjs --message "Add brass tray"
```

## Why it used to be four commands

The steps above were four separate commands in two repositories. Skipping one
produced a failure worth knowing about, because two of them are silent:

- **Skip the cache-buster** and the site serves a stale copy to everyone for as
  long as their browser caches it. The app is fine, the *website* looks broken.
- **Skip check-vectors-agree** and `catalog.json` can disagree with
  `catalog.sql`, which is the failure CATALOG-GUIDE.md spends most of its length
  on.

`--dry-run` is the safe way to look before committing anything.

## No app update, ever — unless the model changes

**Adding, renaming or repricing a product needs no app release.** The app
fetches `catalog.json` on every launch, and that file carries the vectors, so
everyone who has the app installed gets the new catalog on their next launch —
or immediately with pull-to-refresh on the home screen.

This works because of where the split is:

| Baked into the APK | Shipped in `catalog.json` |
| --- | --- |
| model weights (`model.bin`) | product vectors |
| the tokenizer | product text, prices, names |
| the engine | the search model id |

The app has no product list of its own, so there is nothing to go stale.

**The one exception is the model.** If the catalog is ever reindexed with a
different encoder, the vectors stop meaning anything and the app *refuses* to
search rather than ranking wrongly. That needs a new APK built with the matching
engine, in the same change. See MEMORY.md §3.

## Verifying it works

```bash
node scripts/check-vectors-agree.mjs      # the two files agree, byte for byte
node ../Store/build.mjs --check           # committed HTML matches the config
flutter test                              # includes the refresh path
```

`test/catalog_refresh_test.dart` is the one that matters: it publishes a
nine-product catalog over the wire to a running service and checks the new
product is visible *and searchable* — not just rendered.
