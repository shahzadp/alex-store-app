#!/usr/bin/env node
/**
 * Render assets/icon/app_icon.svg into the Android launcher mipmaps.
 *
 * # WHY A SCRIPT AND NOT flutter_launcher_icons
 *
 * That package is a Dart-only solution: it scales an existing PNG into every
 * density. Android does not accept SVG for a launcher icon, so something has to
 * rasterise first, and that is the part it does not do. `sharp` bundles
 * librsvg, so it handles both steps.
 *
 * # The density ladder
 *
 * Android picks `ic_launcher` per density bucket. Getting one size wrong shows
 * up as a blurry or clipped icon on real hardware, so all five are written:
 *
 *   mdpi    48    xxhdpi  144
 *   hdpi    72    xxxhdpi 192
 *   xhdpi   96
 *
 * The source is 108x108 (the Play Store's legacy asset size). Each render is
 * scaled from that, not upscaled from mdpi, so edges stay clean.
 *
 * Usage:  node scripts/render-launcher-icons.mjs
 */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, '..');
const SRC = resolve(REPO, 'assets', 'icon', 'app_icon.svg');
const RES = resolve(REPO, 'android', 'app', 'src', 'main', 'res');

const DENSITIES = [
  ['mipmap-mdpi', 48],
  ['mipmap-hdpi', 72],
  ['mipmap-xhdpi', 96],
  ['mipmap-xxhdpi', 144],
  ['mipmap-xxxhdpi', 192],
];

// `sharp` is a dev-time renderer only. It is NOT a dependency of the app, and
// it is deliberately not in the repo's package.json: the icons are committed
// once generated, so a fresh clone never needs an image toolchain to build.
const require = createRequire(import.meta.url);
let sharp;
try {
  sharp = require('sharp');
} catch {
  console.error('sharp is not installed. This script is only needed when the icon changes:\n');
  console.error('  npm install --no-save sharp\n');
  process.exit(1);
}

const svg = readFileSync(SRC);

for (const [dir, size] of DENSITIES) {
  const out = join(RES, dir, 'ic_launcher.png');
  mkdirSync(dirname(out), { recursive: true });
  await sharp(svg, { density: 384 })
    .resize(size, size, { fit: 'fill' })
    .png({ compressionLevel: 9 })
    .toFile(out);
  console.log(`  ${dir}/ic_launcher.png  ${size}x${size}`);
}

console.log('\nWrote the launcher icon to every density bucket.');