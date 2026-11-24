# fathom

Charset / encoding detection for Crystal. Pure Crystal, zero runtime dependencies, and zero-allocation hot paths.

## Installation

```yaml
dependencies:
  fathom:
    github: x-ror/fathom
    version: ~> 0.4.0
```

## Usage

### Basic detection & decoding

```crystal
require "fathom"

encoding = Fathom.detect(bytes) # => "WINDOWS-1251", or nil
text = String.new(bytes, encoding) if encoding

# Detect, strip any leading BOM, drop an incomplete trailing character, and decode to a UTF-8 String
text = Fathom.decode(bytes)
text = Fathom.decode(bytes, invalid: :skip) # pass invalid byte handling through to String.new

# Streaming IO (detects from up to 64 KiB by default; decode reads the full stream)
File.open("data.txt") do |file|
  encoding = Fathom.detect(file)
end
```

`Fathom.decode` strips any leading BOM, drops an incomplete character at the very end of the input (a cut multi-byte UTF-8 sequence, an odd trailing UTF-16 byte, or a lone high surrogate — matching what detection accepts), and passes `invalid:` (`nil` or `:skip`) unchanged to `String.new`.

### Confidence scores, BOM, language & `iconv` names

```crystal
if match = Fathom.match(bytes)
  puts "#{match.encoding} (#{match.confidence.round(2)}, bom: #{match.bom?}, lang: #{match.language || "none"})"
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
  probers: Fathom::Detector::DEFAULT_PROBERS + ([MyProber.new] of Fathom::Prober),
)
detector.match(bytes)
```

## What it detects

- UTF-8, UTF-16LE/BE, and UTF-32LE/BE by BOM
- UTF-8 and ASCII without a BOM (reported as `UTF-8`, including truncated trailing multi-byte sequences and NUL-terminated strings)
- Slightly corrupted UTF-8 with lowered confidence when valid multi-byte UTF-8 sequences outnumber invalid high bytes (`>= 10:1`)
- BOM-less `UTF-16LE` and `UTF-16BE` (for ASCII/mixed-null payloads)
- BOM-less `UTF-32LE` and `UTF-32BE` (at least 4 code units, i.e. 16 bytes)
- Western European: `WINDOWS-1252`, `IBM437`, `IBM850`, `MACINTOSH` (`ISO-8859-15` is omitted because it differs from `WINDOWS-1252` in only 8 positions)
- Cyrillic: `WINDOWS-1251`, `KOI8-R`, `KOI8-U`, `ISO-8859-5`, `IBM866`, `X-MAC-CYRILLIC`
- Central & Baltic Europe: `WINDOWS-1250`, `ISO-8859-2`, `IBM852`, `WINDOWS-1257`, `ISO-8859-13`
- Greek & Turkish: `WINDOWS-1253`, `ISO-8859-7`, `WINDOWS-1254`
- Hebrew, Arabic & Thai: `WINDOWS-1255`, `WINDOWS-1256`, `ISO-8859-6`, `WINDOWS-874`
- Optional `Match#language` populates the ISO 639-1 language code for single-language probers (`ru`, `uk`, `be`, `pl`, `cs`, `hu`, `lt`, `lv`, `el`, `tr`, `he`, `ar`, `th`, or `nil` for shared encodings such as `UTF-8`, `UTF-16*`, `UTF-32*`, `WINDOWS-1252`, `IBM437`, `IBM850`, `MACINTOSH`)

Not yet built in: CJK (can be plugged in via `Fathom::Prober`).

## Labels, Aliases & Platform `iconv` Support

- Canonical encoding labels follow the WHATWG Encoding Standard (uppercase, e.g. `UTF-8`, `WINDOWS-1252`, `IBM866`, `MACINTOSH`).
- ISO/Windows pairs differing only in `0x80..0x9F` (`ISO-8859-1`/`WINDOWS-1252`, `ISO-8859-9`/`WINDOWS-1254`, `ISO-8859-11` & `TIS-620`/`WINDOWS-874`) collapse to the Windows label via `Fathom::Encoding.canonical_name`, since the Windows variant decodes both. Visual-order Hebrew (`ISO-8859-8`) is reported as `WINDOWS-1255` when it is valid `WINDOWS-1255`; `ISO-8859-13` is a separate supported encoding because it differs from `WINDOWS-1257` at `0xA1`, `0xA5`, `0xB4`, and `0xFF`.
- **Tie-breaking on shared bytes**: encodings whose differing codepoints do not appear in a given input score identically and resolve by prober registration order (`WINDOWS-1252` before `IBM850`/`IBM437`/`MACINTOSH`, `WINDOWS-1250` before `ISO-8859-2`, `WINDOWS-1253` before `ISO-8859-7`, `WINDOWS-1257` before `ISO-8859-13`, `WINDOWS-1256` before `ISO-8859-6`). For example, symbol-only Western strings such as `Copyright ©…` or plain Greek text lacking `'Ά'` (`U+0386`) cannot distinguish those pairs at the byte level.
- `Fathom::Encoding.iconv_name` (also exposed as `Match#iconv_name`) returns the name to pass to `String.new`, chosen to work on supported platforms:
  - `IBM437` → `CP437`, `IBM850` → `CP850`, `IBM852` → `CP852`, `IBM866` → `CP866`
  - `MACINTOSH` → `MACROMAN` on Windows, `MACINTOSH` elsewhere
  - `X-MAC-CYRILLIC` → `MACCYRILLIC`
  - All other canonical labels are returned as-is
- Detection is platform-independent: `Fathom.detect` and `Fathom.match` always return canonical labels regardless of host OS. On Alpine Linux (`musl`), `musl`'s built-in `iconv` does not support `IBM852`, `MACINTOSH`, `X-MAC-CYRILLIC`, or `WINDOWS-874`; detection still succeeds, while `Fathom.decode` raises `ArgumentError` just as `String.new` does.

CI decodes every supported encoding through the platform `iconv` on Linux (glibc), Alpine (musl, excluding the 4 `musl`-unsupported encodings), macOS, and Windows (`spec/iconv_spec.cr`).

## CLI & Corpus Accuracy Baseline

A lightweight CLI under `tools/fathom.cr` (excluded from `shard.yml` `targets` so library consumers do not build an extra binary) supports file inspection and corpus evaluation:

```sh
crystal run tools/fathom.cr -- path/to/file.txt
crystal run tools/fathom.cr -- --all --json path/to/file.txt
crystal run tools/fathom.cr -- --decode --invalid-skip path/to/file.txt
crystal run tools/fathom.cr -- --corpus                    # evaluate built-in corpus/
crystal run tools/fathom.cr -- --corpus --compare=icu      # compare against ICU ucsdet
```

Baseline on `corpus/`: `208` files (`57` Wikipedia articles in 19 languages plus `1` synthetic `IBM437` sample, sources and license in `corpus/SOURCES.md`) evaluated at `64B`, `256B`, `1024B`, `4096B`, and full size (`840` slices total: `328` UTF, `512` single-byte; pure-ASCII slices of single-byte files are skipped since `UTF-8` is the right label for them).

Notice that ICU `ucsdet` does not output 10 of Fathom's built-in corpus encodings (`IBM437`, `IBM850`, `IBM852`, `IBM866`, `ISO-8859-13`, `KOI8-U`, `MACINTOSH`, `WINDOWS-1257`, `WINDOWS-874`, `X-MAC-CYRILLIC` — 240 slices), so both the full-corpus total and the fair head-to-head subset over encodings ICU actually outputs are reported below:

| Input Size | Fathom | ICU (`ucsdet`) |
| --- | ---: | ---: |
| `64B` | 169 / 201 (84.08%) | 113 / 201 (56.22%) |
| `256B` | 186 / 208 (89.42%) | 139 / 208 (66.83%) |
| `1024B` | 201 / 207 (97.1%) | 144 / 207 (69.57%) |
| `4096B` | 16 / 16 (100.0%) | 16 / 16 (100.0%) |
| `full` | 204 / 208 (98.08%) | 144 / 208 (69.23%) |
| **Overall (all 27 encodings)** | **776 / 840 (92.38%)** | **556 / 840 (66.19%)** |
| **Single-byte only** | **448 / 512 (87.5%)** | **234 / 512 (45.7%)** |
| **Shared encodings only (17 encodings / 600 slices)** | **580 / 600 (96.67%)** *(SB: 252/272 = 92.65%)* | **556 / 600 (92.67%)** *(SB: 234/272 = 86.03%)* |

## Development

```sh
crystal tool format --check
shards install && mkdir -p bin && crystal build -o bin/ameba lib/ameba/bin/ameba.cr  # once
bin/ameba
crystal spec
crystal docs
crystal run tools/train_models.cr -- --fetch        # train bigram models from Wikipedia
crystal run tools/gen_tables.cr > src/fathom/tables.cr # regenerate precomputed byte tables
crystal run tools/gen_chardetng_data.cr -- path/to/chardetng-1.0.0/src/data.rs  # regenerate chardetng tables
crystal run tools/heldout.cr                          # held-out accuracy on the uchardet/chardetng test suites
crystal run tools/gen_whatwg_indexes.cr               # regenerate the WHATWG multi-byte indexes
crystal run --release bench/benchmark.cr             # run throughput benchmark
```

## Acknowledgements

Single-byte detection is a Crystal port of [chardetng](https://github.com/hsivonen/chardetng) 1.0.0 by Henri Sivonen (copyright Mozilla Foundation), extended with DOS, Mac and `KOI8-R` encodings. chardetng's code is used under the MIT license (see [`LICENSE-chardetng`](LICENSE-chardetng)); its data tables are dedicated to the public domain (CC0).

The multi-byte code point indexes in `src/fathom/whatwg/` are generated from the [WHATWG Encoding Standard](https://encoding.spec.whatwg.org/) (copyright WHATWG) and are licensed under the BSD 3-Clause License (see [`LICENSE-whatwg`](LICENSE-whatwg)).

## License

MIT (see [`LICENSE`](LICENSE)). The chardetng port in `src/fathom/chardetng.cr` is also covered by chardetng's MIT license (see [`LICENSE-chardetng`](LICENSE-chardetng)). The WHATWG indexes in `src/fathom/whatwg/` are under the BSD 3-Clause License (see [`LICENSE-whatwg`](LICENSE-whatwg)).
