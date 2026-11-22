# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-11-22

### Added
- Pure-Crystal character encoding detection with zero runtime dependencies and zero-allocation hot paths.
- Byte Order Mark (BOM) detection for `UTF-8`, `UTF-16LE`, `UTF-16BE`, `UTF-32LE`, and `UTF-32BE`.
- UTF-8 and ASCII detection, including truncated trailing multi-byte UTF-8 sequences and NUL-terminated strings.
- BOM-less `UTF-16LE` and `UTF-16BE` detection via null-byte parity and code-unit validation.
- Single-byte encoding probers backed by precomputed `StaticArray` lookup tables (`WINDOWS-1251`, `KOI8-R`, `KOI8-U`, `ISO-8859-5`, `IBM866`, and `WINDOWS-1252`).
- Public API: `Fathom.detect`, `Fathom.match`, `Fathom.detect_all`, `Fathom::Match`, `Fathom::Detector` (supporting both `Bytes` and `IO` streaming), and pluggable `Fathom::Prober` interface.
