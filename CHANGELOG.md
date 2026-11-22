# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `Fathom.decode` and `Fathom::Detector#decode` (`Bytes` and `IO`) to detect encoding, strip any leading BOM, and decode via `String.new` with pass-through `invalid` handling.
- `Fathom::Encoding` (`SUPPORTED`, `ISO_WINDOWS_ALIASES`, `canonical_name`, `iconv_name`) and `Fathom::Match#iconv_name` aligned with WHATWG Encoding Standard labels (`ascii` maps to `WINDOWS-1252`) and the ISO/Windows `0x80..0x9F` alias rule.
- Tolerant UTF-8 detection (`Fathom::UTF.probe_tolerant_utf8`) returning `UTF-8` with lowered confidence based on the ratio of valid multi-byte UTF-8 sequences to invalid high bytes.
- Accuracy corpus under `corpus/` built from Wikipedia text by `tools/gen_corpus.cr`, and a CI accuracy regression gate (`spec/accuracy_spec.cr` over `spec/fixtures/corpus/`).
- Cross-platform `iconv` decode verification spec (`spec/iconv_spec.cr`) and CI matrix across Linux glibc, Alpine musl, macOS, and Windows.
- Lightweight CLI tool at `tools/fathom.cr` for file/stdin inspection, decoding, and corpus accuracy benchmarking (with optional `icu` / `uchardet` comparison).

### Fixed
- Latin text with isolated accented letters (e.g. Italian word-final `è`) is no longer detected as `WINDOWS-1251`: Cyrillic probers now reject input where most non-ASCII letters stand alone between ASCII bytes. Corpus accuracy 364/374 → 373/374.

## [0.1.0] - 2026-11-22

### Added
- Pure-Crystal character encoding detection with zero runtime dependencies and zero-allocation hot paths.
- Byte Order Mark (BOM) detection for `UTF-8`, `UTF-16LE`, `UTF-16BE`, `UTF-32LE`, and `UTF-32BE`.
- UTF-8 and ASCII detection, including truncated trailing multi-byte UTF-8 sequences and NUL-terminated strings.
- BOM-less `UTF-16LE` and `UTF-16BE` detection via null-byte parity and code-unit validation.
- Single-byte encoding probers backed by precomputed `StaticArray` lookup tables (`WINDOWS-1251`, `KOI8-R`, `KOI8-U`, `ISO-8859-5`, `IBM866`, and `WINDOWS-1252`).
- Public API: `Fathom.detect`, `Fathom.match`, `Fathom.detect_all`, `Fathom::Match`, `Fathom::Detector` (supporting both `Bytes` and `IO` streaming), and pluggable `Fathom::Prober` interface.
