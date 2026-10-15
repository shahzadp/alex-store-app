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

Use the file as-is only if you keep the current signing setup. The fingerprint
in it is:

```
5C:E3:40:89:...:88:D2
```

which is the **debug** keystore's, because
`android/app/build.gradle.kts` signs release builds with `signingConfigs
.getByName("debug")`.

**Before publishing, create a real release keystore.** The debug fingerprint is
generated per machine, so it will not match on another computer, and anyone can
generate a debug keystore — publishing it means any app signed with any debug
keystore on any machine can claim your links.

```bash
keytool -genkey -v -keystore release.jks -keyalg RSA -keysize 2048 \
        -validity 10000 -alias alex-store
keytool -list -v -keystore release.jks -alias alex-store | grep SHA256
```

Put the new fingerprint in `docs/assetlinks.json`, and point
`android/app/build.gradle.kts` at `release.jks` (read it from
`key.properties`, which must not be committed).
