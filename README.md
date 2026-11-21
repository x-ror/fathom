# fathom

Charset / encoding detection for Crystal. Pure Crystal, no C dependencies.

## Installation

```yaml
dependencies:
  fathom:
    github: x-ror/fathom
```

## Usage

```crystal
require "fathom"

encoding = Fathom.detect(bytes) # => "WINDOWS-1251", or nil if unknown
text = String.new(bytes, encoding) if encoding
```

## What it detects

- UTF-8, UTF-16 and UTF-32 by BOM
- UTF-8 and ASCII without a BOM (reported as `UTF-8`)
- Cyrillic: `WINDOWS-1251`, `KOI8-R`, `KOI8-U`, `ISO-8859-5`, `IBM866`
- Western European: `WINDOWS-1252`

Not yet: UTF-16 without a BOM, Central European, Greek, Turkish, CJK.

## Development

```sh
crystal spec
crystal run tools/gen_tables.cr > src/fathom/tables.cr # regenerate byte tables
```

## License

MIT
