# Third-party notices

This repository contains third-party work, licensed by its own authors. The
licences for the components that are vendored or embedded here are reproduced
below in full. **The terms in this repository's `LICENSE` do not apply to this
material** - and, just as importantly, this material's permissive terms say
nothing about the rest of the repository.

The file is named `THIRD_PARTY_NOTICES.md` rather than anything containing the
word "LICENSE" on purpose: GitHub's licence detector treats a root file whose
name looks like a licence file as *the repository's* licence, and it used to
report this whole repository as MIT because of the text below. It is not the
repository's licence.

---

## ternlight - MIT

`rust/src/engine/` is vendored byte-for-byte unmodified from
[ternlight](https://github.com/soycaporal/ternlight), and the model weights
compiled into the native library come from
[`wenshutang/ternlight`](https://huggingface.co/wenshutang/ternlight). Both are
MIT:

```
MIT License

Copyright (c) 2026 Wenshu Tang

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

Everything else third-party is a **fetched** dependency rather than vendored
source - the Flutter/Dart packages in `pubspec.lock` and their native
dependencies. Those are not reproduced here; `README.md`'s "Third party" section
lists the ones that matter and what they are used for.
