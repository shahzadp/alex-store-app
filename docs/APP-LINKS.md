# Opening storefront links in the app

The app declares an intent filter for `https://shahzadp.github.io/store/*` with
`android:autoVerify="true"`, so a link to a product page offers **Alex Store**
as a place to open it, and opens the matching product.

That already works. What does *not* yet work is opening it **automatically**,
without Android asking which app to use.

## Why automatic needs a file we cannot publish from here

Android only skips the "Open with" chooser when it can fetch

```
https://shahzadp.github.io/.well-known/assetlinks.json
```

That file must sit at the **domain root**. The storefront is a GitHub Pages
*project* repo, so it is published under `/store/` and there is no way to make
it serve a file at `/` — the root belongs to a separate *user* site repo
(`shahzadp.github.io`) which does not exist:

```
$ curl -s -o /dev/null -w '%{http_code}' https://shahzadp.github.io/
404
```

So the chooser appears, with the app in it. **No code change is needed when
this is fixed** — the `autoVerify` flag already in the manifest starts working
the moment the file is reachable.

## To switch it on

Either create the user-site repo, or put a custom domain in front of the
storefront. Then publish `docs/assetlinks.json` at the well-known path.

The fingerprint in that file is the real release key's:

```
DA:5B:48:50:1D:CE:D4:5D:35:C7:5B:EC:8D:F0:D8:45:CF:8E:2C:19:4B:FC:D8:A6:DD:ED:AB:9B:D1:02:1A:C2
```

which belongs to `android/app/release-keystore.jks`. Release builds read it via
`android/key.properties`; neither file is committed, so a fresh clone has no
release identity until one is supplied — and the build refuses to produce a
release APK without one rather than falling back to something else. See the top
of `android/app/build.gradle.kts`.

Earlier this file carried the **debug** keystore's fingerprint, because release
builds were signed with `signingConfigs.getByName("debug")`. Publishing that
would have been a quiet version of the same mistake the fingerprint is meant to
prevent: the debug key is generated per machine and its password is literally
`android`, so any app signed with any debug keystore anywhere could have claimed
these links. It also meant the first release could never have been upgraded —
Android refuses to install an update whose signing key differs, so every install
of the debug-signed build would have had to be removed first.

**If the keystore is ever rotated, this fingerprint has to move with it**, in
the same commit as the new key, or the chooser comes back for everyone.
`node scripts/verify-release-apk.mjs` compares the built APK's certificate
against this file and fails when they disagree, which is how the staleness that
used to be here would now be caught.
