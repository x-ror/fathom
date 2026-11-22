# fathom

Charset / encoding detection for Crystal. Pure Crystal, zero runtime dependencies, and zero-allocation hot paths.

## Installation

```yaml
dependencies:
  fathom:
    github: x-ror/fathom
    version: ~> 0.1.0
```

## Usage

### Basic detection

```crystal
require "fathom"

encoding = Fathom.detect(bytes) # => "WINDOWS-1251", or nil
text = String.new(bytes, encoding) if encoding

# Streaming IO (reads at most 64 KiB by default)
File.open("data.txt") do |file|
  encoding = Fathom.detect(file)
end
```

### Confidence scores & candidate lists

```crystal
if match = Fathom.match(bytes)
  puts "#{match.encoding} (#{match.confidence.round(2)}, bom: #{match.bom?})"
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
- UTF-8 and ASCII without a BOM (reported as `UTF-8`, including truncated trailing multi-byte sequences)
- BOM-less `UTF-16LE` and `UTF-16BE` (for ASCII/mixed-null payloads)
- Cyrillic: `WINDOWS-1251`, `KOI8-R`, `KOI8-U`, `ISO-8859-5`, `IBM866`
- Western European: `WINDOWS-1252`

Not yet built in: Central European, Greek, Turkish, CJK (can be plugged in via `Fathom::Prober`).

## Development

```sh
crystal spec
crystal run tools/gen_tables.cr > src/fathom/tables.cr # regenerate precomputed byte tables
crystal run --release bench/benchmark.cr             # run throughput benchmark
```

## License

MIT
