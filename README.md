# fathom

Charset / encoding detection for Crystal. Pure Crystal, zero runtime dependencies, and zero-allocation hot paths.

## Installation

```yaml
dependencies:
  fathom:
    github: x-ror/fathom
    version: ~> 0.3.0
```

## Usage

### Basic detection & decoding

```crystal
require "fathom"

encoding = Fathom.detect(bytes) # => "WINDOWS-1251", or nil
text = String.new(bytes, encoding) if encoding

# Detect, strip any leading BOM, and decode to a UTF-8 String in one call
text = Fathom.decode(bytes)
text = Fathom.decode(bytes, invalid: :skip) # pass invalid byte handling through to String.new

# Streaming IO (detects from up to 64 KiB by default; decode reads the full stream)
File.open("data.txt") do |file|
  encoding = Fathom.detect(file)
end
```

### Confidence scores, BOM & `iconv` names

```crystal
if match = Fathom.match(bytes)
  puts "#{match.encoding} (#{match.confidence.round(2)}, bom: #{match.bom?})"
  # Use match.iconv_name when passing to String.new(bytes, ...) if the
  # WHATWG canonical label differs from the platform iconv name:
  decoded = String.new(bytes, match.iconv_name)
end

Fathom.detect_all(bytes).each do |candidate|
  puts "#{candidate.encoding}: #{candidate.confidence.round(2)}"
end
```

### Custom detector & extensible probers

```crystal
struct MyProber
  include Fathom::Prober

  def probe(bytes : Bytes, stats : Fathom::ByteStats) : Fathom::Match?
    # Return Fathom::Match.new("...", confidence) or nil
  end
end

detector = Fathom::Detector.new(
  sample_size: 32_768,
  min_confidence: 0.25,
  probers: Fathom::SingleByte::PROBERS + ([MyProber.new] of Fathom::Prober),
)
detector.match(bytes)
```

## What it detects

- UTF-8, UTF-16LE/BE, and UTF-32LE/BE by BOM
- UTF-8 and ASCII without a BOM (reported as `UTF-8`, including truncated trailing multi-byte sequences and NUL-terminated strings)
- Slightly corrupted UTF-8 with lowered confidence when valid multi-byte UTF-8 sequences outnumber invalid high bytes (`>= 10:1`)
- BOM-less `UTF-16LE` and `UTF-16BE` (for ASCII/mixed-null payloads)
- Cyrillic: `WINDOWS-1251`, `KOI8-R`, `KOI8-U`, `ISO-8859-5`, `IBM866`
- Western European: `WINDOWS-1252`

Not yet built in: Central European, Greek, Turkish, CJK (can be plugged in via `Fathom::Prober`).

## Labels, Aliases & Platform `iconv` Support

- Canonical encoding labels follow the WHATWG Encoding Standard (uppercase, e.g. `UTF-8`, `WINDOWS-1252`, `IBM866`).
- ISO/Windows pairs differing only in `0x80..0x9F` (`ISO-8859-1`/`WINDOWS-1252`, `ISO-8859-9`/`WINDOWS-1254`, `ISO-8859-13`/`WINDOWS-1257`, `TIS-620`/`WINDOWS-874`) collapse to the Windows label via `Fathom::Encoding.canonical_name`, since the Windows variant decodes both.
- `Fathom::Encoding.iconv_name` (also exposed as `Match#iconv_name`) returns the name to pass to `String.new`, chosen to work on every supported platform. It equals the canonical label except `IBM866` → `CP866`, the only name musl accepts.
- Detection is platform-independent: `Fathom.detect` and `Fathom.match` always return canonical labels regardless of host OS. If the host `iconv` cannot decode a detected encoding, `Fathom.decode` raises `ArgumentError` just as `String.new` does.

CI decodes every built-in encoding through the platform `iconv` on Linux (glibc), Alpine (musl), macOS, and Windows (`spec/iconv_spec.cr`).

## CLI & Corpus Accuracy Baseline

A lightweight CLI under `tools/fathom.cr` (excluded from `shard.yml` `targets` so library consumers do not build an extra binary) supports file inspection and corpus evaluation:

```sh
crystal run tools/fathom.cr -- path/to/file.txt
crystal run tools/fathom.cr -- --all --json path/to/file.txt
crystal run tools/fathom.cr -- --decode --invalid-skip path/to/file.txt
crystal run tools/fathom.cr -- --corpus                    # evaluate built-in corpus/
crystal run tools/fathom.cr -- --corpus --compare=icu      # compare against ICU ucsdet
```

Baseline on `corpus/`: 27 Wikipedia articles in 9 languages (sources and license in `corpus/SOURCES.md`), encoded into every applicable encoding by `tools/gen_corpus.cr` and sliced to `64B`, `256B`, `1024B`, `4096B`, and full size. Slices of single-byte text that contain no non-ASCII bytes are skipped, since `UTF-8` is the correct answer for them.

| Input Size | Fathom | ICU (`ucsdet`) |
| --- | ---: | ---: |
| `64B` | 88 / 88 (100.0%) | 66 / 88 (75.0%) |
| `256B` | 90 / 90 (100.0%) | 81 / 90 (90.0%) |
| `1024B` | 90 / 90 (100.0%) | 84 / 90 (93.33%) |
| `4096B` | 16 / 16 (100.0%) | 16 / 16 (100.0%) |
| `full` | 90 / 90 (100.0%) | 84 / 90 (93.33%) |
| **Overall** | **374 / 374 (100.0%)** | **331 / 374 (88.5%)** |

(`0.2.0` unigram baseline was `373 / 374 (99.73%)`; language-level bigram models added in `0.3.0` resolve the remaining 64-byte `KOI8-U` vs `KOI8-R` case.)

## Development

```sh
crystal tool format --check
shards install && mkdir -p bin && crystal build -o bin/ameba lib/ameba/bin/ameba.cr  # once
bin/ameba
crystal spec
crystal docs
crystal run tools/train_models.cr -- --fetch        # train bigram models from Wikipedia
crystal run tools/gen_tables.cr > src/fathom/tables.cr # regenerate precomputed byte tables
crystal run --release bench/benchmark.cr             # run throughput benchmark
```

## License

MIT
