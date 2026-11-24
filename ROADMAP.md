# Roadmap

This document outlines the planned evolution of **fathom** from `0.1.0` to a stable `1.0.0` release.

## `0.1.0` — Foundation & MVP (Released)

- Modular architecture: `Detector`, `Match`, `Prober`, `ByteStats`, `BOM`, `UTF`, and `SingleByte::Table`.
- Precomputed `StaticArray` lookup tables generated via `tools/gen_tables.cr` into `src/fathom/tables.cr`.
- Zero-allocation hot paths for `Bytes` and stack-buffered `IO` sampling (`detect`, `match`, `detect_all`).
- Encoding support:
  - BOM detection (`UTF-8`, `UTF-16LE`, `UTF-16BE`, `UTF-32LE`, `UTF-32BE`)
  - UTF-8 and ASCII (including truncated trailing multi-byte sequences and NUL-terminated strings)
  - BOM-less `UTF-16LE` and `UTF-16BE` (for ASCII/mixed-null payloads)
  - Cyrillic (`WINDOWS-1251`, `KOI8-R`, `KOI8-U`, `ISO-8859-5`, `IBM866`) and Western European (`WINDOWS-1252`)
- GitHub Actions CI, specs, and throughput benchmark (`bench/benchmark.cr`).

## `0.2.0` — Accuracy Baseline, WHATWG Labels, `decode` & Tolerant UTF-8 (Released)

- Corpus accuracy benchmark suite measuring precision and recall across languages and input sizes, establishing a baseline (including comparisons with `uchardet`/ICU) before changing scoring.
- Accuracy regression gate in CI: a small corpus subset runs as specs with per-encoding thresholds, so a drop in accuracy fails the build. The full corpus stays outside CI and is driven by the CLI tool.
- Decide canonical encoding labels aligned with the WHATWG Encoding Standard, exposing a separate `iconv` name where the label differs from what Crystal's `String.new(bytes, encoding)` accepts.
- Alias rule for ISO/Windows pairs that differ only in `0x80..0x9F` (`ISO-8859-1`/`WINDOWS-1252`, `ISO-8859-9`/`WINDOWS-1254`, `ISO-8859-13`/`WINDOWS-1257`, `TIS-620`/`WINDOWS-874`): the pair is reported as a single encoding under the Windows label, since the Windows variant decodes both. (`ISO-8859-13` was split out in `0.4.0`: `WINDOWS-1257` leaves its `0xA1`/`0xA5` undefined.)
- Detection results are platform-independent: an encoding is reported even when the platform's `iconv` cannot decode it. In that case `Fathom.decode` raises the same `ArgumentError` as `String.new`, and the README documents per-platform decode support.
- Add a cross-platform spec (glibc, musl, macOS, and Windows in CI) verifying that every encoding name returned by `fathom` decodes via `String.new(bytes, name)`, with an explicit per-platform list of known-unsupported encodings.
- Add `Fathom.decode(bytes) : String?` (detect encoding, strip leading BOM, and decode; the `invalid` argument is passed through to `String.new` unchanged).
- Add tolerance for slightly corrupted UTF-8 based on the ratio of valid multi-byte UTF-8 sequences to invalid bytes (not raw ASCII+byte ratio), returning `UTF-8` with lowered confidence.
- Add a lightweight CLI tool under `tools/` (kept out of `shard.yml` `targets` so library consumers do not compile a binary on `shards install`) for inspecting files and driving the accuracy corpus.

## `0.3.0` — Bigram Models (Released)

- Language-level bigram models trained on corpora and projected through encoding tables, applied only to existing encodings (Cyrillic + `WINDOWS-1252`) so algorithm changes are isolated from new encoding coverage and measured against the `0.2.0` baseline.

## `0.4.0` — Expanded Single-Byte Encodings & Language Metadata (Released)

- Expand distinct single-byte tables:
  - Central / Baltic Europe: `WINDOWS-1250`, `ISO-8859-2`, `WINDOWS-1257`, `ISO-8859-13`
  - Greek (`WINDOWS-1253`, `ISO-8859-7`), Turkish (`WINDOWS-1254`)
  - Hebrew (`WINDOWS-1255`), Arabic (`WINDOWS-1256`, `ISO-8859-6`), Thai (`WINDOWS-874`)
  - DOS code pages (`IBM437`, `IBM850`, `IBM852`) and Mac encodings (`macintosh`, `x-mac-cyrillic`)
  - `ISO-8859-15` only if the accuracy corpus shows it is separable from `WINDOWS-1252` (they differ in eight positions).
- Optional `language : String?` field on `Fathom::Match`.
- Single-byte detection rebuilt on a Crystal port of [chardetng](https://github.com/hsivonen/chardetng) 1.0.0 (MIT, tables CC0), verified against upstream; `IBM437`/`IBM850`/`IBM852`/`MACINTOSH`/`X-MAC-CYRILLIC`/`KOI8-R` use byte-class tables derived from chardetng's by character. `ISO-8859-13` is its own encoding; visual Hebrew (`ISO-8859-8`) is reported as `WINDOWS-1255` when that decodes it. `ISO-8859-15` was not added.

## `0.5.0` — Multi-Byte Encodings (CJK), `ISO-2022-JP`, BOM-less `UTF-32` & Fuzz Testing

Done (in `CHANGELOG.md` `[Unreleased]`):

- Held-out accuracy benchmark (`tools/heldout.cr`) on the uchardet and chardetng test suites, scored by decode equivalence.
- Short-input accuracy: Mac Roman vs CP850 case rule, a better non-scoring fallback, and per-language bigram models settling Latin near-ties.
- Bigram probers that no longer affect results removed (`tables.cr` −30%, binaries −20%); `--release` builds down from ~2.5 minutes to ~12 seconds.
- chardetng's MIT license shipped as `LICENSE-chardetng`.
- BOM-less `UTF-32LE` / `UTF-32BE` detection (omitting error-prone NUL-less `UTF-16`).
- WHATWG multi-byte indexes and allocation-free `Shift_JIS`, `EUC-JP`, `EUC-KR`, `Big5`, `gb18030`/`GBK` and `ISO-2022-JP` decoders, matching encoding_rs step by step.
- chardetng's CJK (`GBK`, `EUC-JP`, `EUC-KR`, `Shift_JIS`, `Big5`) and `ISO-2022-JP` candidates ported over those decoders, matching unmodified chardetng; `Fathom.detect` doesn't report CJK or `ISO-2022-JP` yet.

Planned:

- Report the CJK encodings and `ISO-2022-JP` from `Fathom.detect`: add them to `Encoding::SUPPORTED` with per-platform `iconv` names, and check escape sequences before the ASCII fast path so 7-bit `ISO-2022-JP` isn't reported as `UTF-8`. Report their language from `Chardetng::Prober#language` directly, and measure how many short single-byte slices CJK candidates take first: e.g. upstream reads 64 bytes of Polish CP852 (`IBM852/pl_1.txt`) as `Big5`, and `IBM852` starts `RARE_HANDICAP` behind.
- Fuzz and property specs over random and truncated byte slices to catch out-of-bounds bugs in multi-byte state machines.
- CJK samples in `corpus/` and in the accuracy gate; `tools/heldout.cr` already contains CJK test files to measure against.

## `0.6.0` — Real-World Context & Targeted Optimizations

- Declared-encoding parsing (`<meta charset>`, `<?xml encoding="…"?>`), treated as a strong hint that statistical evidence can override if bytes contradict the declaration.
- HTML/XML tag filtering during scoring so ASCII markup does not skew character statistics.
- Context hints (`preferred_encodings` / `locale`).
- SWAR / `UInt64`-word hot-loop optimizations where benchmarks show a measurable bottleneck.

## `0.9.0` — Release Candidate & Stabilization

- Public API freeze, complete `crystal docs` coverage, usage guides, and published accuracy/throughput metrics.

## `1.0.0` — Stable Release

- Semantic Versioning backward-compatibility guarantees.
- Full coverage of major world encodings (Unicode, European, Cyrillic, Middle Eastern, CJK) backed by verified accuracy and throughput benchmarks.

## After `1.0`

- `WINDOWS-1258` (Vietnamese with combining diacritics) and `ISO-8859-4`: the chardetng port already scores both, but reporting them needs corpus samples (and decomposed-tone text for Vietnamese).

## Out of Scope

- **Mojibake repair** (e.g., `ftfy`-style text recovery) — belongs in a separate library.
- **Legacy/rare encodings** (`UTF-7`, `EBCDIC`, `HZ`, `ISCII`, `VISCII`) — negligible real-world usage and security risks (`UTF-7`).
- **Built-in fallback encoding options** — trivially handled by callers on top of `Fathom.match`.
- **Incremental `StreamDetector` API** — the single-shot `Fathom::Prober` design with prefix `IO` sampling covers streams; a stateful `feed`/`done?` API is not planned.
