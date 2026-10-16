# R8 rules for Alex Store.
#
# ─────────────────────────────────────────────────────────────────────────────
# Why this file is (almost) empty
# ─────────────────────────────────────────────────────────────────────────────
#
# R8 rewrites Java/Kotlin BYTECODE. It cannot see, rename, or remove anything in
# Dart or in a native library. The parts of this app that would be catastrophic
# to break are therefore not reachable from these rules at all — and that is
# worth writing down, because the instinct on enabling obfuscation is "keep my
# FFI symbol names, or R8 will mangle them", which is wrong:
#
#   * Semantic search is dart:ffi, not JNI. lib/src/services/native_engine.dart
#     opens libalex_store_native.so and resolves ten symbols — 'alex_search',
#     'alex_embed', 'alex_set_index', … — from STRING LITERALS at runtime. Those
#     literals are compiled into the Dart AOT snapshot (libapp.so); the symbols
#     live in the .so. R8 touches neither one.
#
#   * rust/src/ffi.rs is `extern "C"` + `#[no_mangle]` throughout, and is
#     deliberately free of JNI: there is no JNI_OnLoad and no `Java_…` export, so
#     there is no class or method name for R8 to rename in the first place. The
#     hand-written boundary (see MEMORY.md §6) is what buys that, and obfuscating
#     the Java side cannot reach across it.
#
# So `-keep` rules for the engine would be cost with no benefit. They are not
# here. What IS at risk is the plugin layer, which is reached reflectively — and
# it turns out Flutter and the plugins already cover all of it, automatically:
#
#   * $FLUTTER/packages/flutter_tools/gradle/flutter_proguard_rules.pro is added
#     to the release build type by FlutterPlugin.kt. It keeps every
#     implementation of FlutterPlugin, which is how app_links, path_provider and
#     url_launcher survive.
#
#   * GeneratedPluginRegistrant must keep its NAME, because Flutter's embedding
#     looks it up with Class.forName("io.flutter.plugins.GeneratedPluginRegistrant")
#     from GeneratedPluginRegister.class. It happens to be annotated @Keep, and
#     AGP's proguard-android-optimize.txt keeps @Keep-annotated classes, so no
#     rule is needed here. The failure would be silent and nasty — no plugin
#     registers, so the app opens and browses but cannot open WhatsApp, cannot
#     read its offline catalog and cannot follow a deep link — which is why
#     scripts/verify-release-apk.mjs asserts the name is still there in the
#     built APK rather than trusting this comment.
#
#   * path_provider_android 2.3.x depends on the `jni` package, whose Android
#     library ships android/consumer-rules.pro via consumerProguardFiles. AGP
#     applies a library's consumer rules automatically, so its keep rules are in
#     force without appearing here. (This is the package that does use JNI, and
#     it is not the search engine.)
#
# The verifier is the point. A redundant keep rule is cheap; a silent break is
# not, and a claim about R8 that is not checked in the artifact is just a hope.
#
# ─────────────────────────────────────────────────────────────────────────────
