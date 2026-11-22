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

## `0.2.0` — Accuracy Baseline, WHATWG Labels & Bigram Models

- Corpus accuracy benchmark suite measuring precision and recall across languages and input sizes, establishing a baseline (including comparisons with `uchardet`/ICU) before changing scoring.
- Decide canonical encoding labels aligned with the WHATWG Encoding Standard, verifying compatibility with Crystal's `String.new(bytes, encoding)` (`iconv`) and collapsing statistically indistinguishable aliases (e.g., `ISO-8859-1` → `WINDOWS-1252`, `ISO-8859-9` → `WINDOWS-1254`, `TIS-620` → `WINDOWS-874`).
- Language-level bigram models trained on corpora and projected through encoding tables, applied first to existing encodings (Cyrillic + `WINDOWS-1252`) so algorithm changes are isolated from new encoding coverage.

## `0.3.0` — Expanded Single-Byte Encodings & Language Metadata

- Expand distinct single-byte tables:
  - Central / Baltic / Western Europe: `WINDOWS-1250`, `ISO-8859-2`, `ISO-8859-15`, `WINDOWS-1257`, `ISO-8859-13`
  - Greek (`WINDOWS-1253`, `ISO-8859-7`), Turkish (`WINDOWS-1254`)
  - Hebrew (`WINDOWS-1255`), Arabic (`WINDOWS-1256`, `ISO-8859-6`), Thai (`WINDOWS-874`)
  - Defer complex edge-case encodings (`WINDOWS-1258`, visual/logical `ISO-8859-8`).
- Optional `language : String?` field on `Fathom::Match`.

## `0.4.0` — Multi-Byte Encodings (CJK), `ISO-2022-JP`, BOM-less `UTF-32` & Fuzz Testing

- Stateful multi-byte `Fathom::Prober` implementations: `SHIFT_JIS`, `EUC-JP`, `GB18030` / `GBK`, `BIG5`, `EUC-KR`.
- 7-bit `ISO-2022-JP` detection via escape sequences (prior to the ASCII fast path).
- BOM-less `UTF-32LE` / `UTF-32BE` detection (omitting error-prone NUL-less `UTF-16`).
- Fuzz and property specs over random and truncated byte slices to catch out-of-bounds bugs in multi-byte state machines.

## `0.5.0` — Real-World Context & Targeted Optimizations

- HTML/XML tag filtering during scoring so ASCII markup does not skew character statistics.
- Context hints (`preferred_encodings` / `locale`).
- SWAR / `UInt64`-word hot-loop optimizations where benchmarks show a measurable bottleneck.
- Keep the single-shot `Fathom::Prober` design with prefix `IO` sampling (no separate `StreamDetector` state API).

## `0.9.0` — Release Candidate & Stabilization

- Public API freeze, complete `crystal docs` coverage, usage guides, and published accuracy/throughput metrics.

## `1.0.0` — Stable Release

- Semantic Versioning backward-compatibility guarantees.
- Full coverage of major world encodings (Unicode, European, Cyrillic, Middle Eastern, CJK) backed by verified accuracy and throughput benchmarks.
