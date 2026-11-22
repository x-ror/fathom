module Fathom
  # Canonical encoding labels (WHATWG Encoding Standard names, uppercased) and
  # platform `iconv` name resolution.
  module Encoding
    # Canonical encoding labels returned by the built-in probers.
    SUPPORTED = {
      "UTF-8",
      "UTF-16LE",
      "UTF-16BE",
      "UTF-32LE",
      "UTF-32BE",
      "WINDOWS-1252",
      "WINDOWS-1251",
      "KOI8-R",
      "KOI8-U",
      "ISO-8859-5",
      "IBM866",
    }

    # ISO/Windows pairs that differ only in `0x80..0x9F`.
    # Each pair is collapsed to the Windows superset because it decodes both.
    ISO_WINDOWS_ALIASES = {
      "ISO-8859-1"  => "WINDOWS-1252",
      "ISO-8859-9"  => "WINDOWS-1254",
      "ISO-8859-11" => "WINDOWS-874",
      "ISO-8859-13" => "WINDOWS-1257",
      "TIS-620"     => "WINDOWS-874",
    }

    # WHATWG labels for the supported encodings, plus the ISO/Windows rule.
    # Labels for other encodings are added together with their probers.
    ALIASES = {
      "UTF8"              => "UTF-8",
      "UNICODE-1-1-UTF-8" => "UTF-8",
      "UTF-16"            => "UTF-16LE",
      "ASCII"             => "WINDOWS-1252",
      "US-ASCII"          => "WINDOWS-1252",
      "ANSI_X3.4-1968"    => "WINDOWS-1252",
      "LATIN1"            => "WINDOWS-1252",
      "L1"                => "WINDOWS-1252",
      "ISO_8859-1"        => "WINDOWS-1252",
      "ISO8859-1"         => "WINDOWS-1252",
      "CP1252"            => "WINDOWS-1252",
      "X-CP1252"          => "WINDOWS-1252",
      "CP1251"            => "WINDOWS-1251",
      "X-CP1251"          => "WINDOWS-1251",
      "CP866"             => "IBM866",
      "866"               => "IBM866",
      "CSIBM866"          => "IBM866",
      "KOI8"              => "KOI8-R",
      "KOI8_R"            => "KOI8-R",
      "CSKOI8R"           => "KOI8-R",
      "KOI8-RU"           => "KOI8-U",
      "CYRILLIC"          => "ISO-8859-5",
      "ISO_8859-5"        => "ISO-8859-5",
      "ISO8859-5"         => "ISO-8859-5",
    }.merge(ISO_WINDOWS_ALIASES)

    # Normalizes *label* to Fathom's canonical uppercase encoding name.
    # Applies the ISO/Windows alias rule (e.g. `"ISO-8859-1"` -> `"WINDOWS-1252"`).
    def self.canonical_name(label : String) : String
      normalized = label.strip.upcase
      ALIASES[normalized]? || normalized
    end

    # Returns the encoding name to pass to Crystal's `String.new(bytes, name)` (`iconv`)
    # for the given canonical *encoding*.
    #
    # Names are chosen to work with every supported `iconv`: glibc, musl, macOS libiconv, and Windows.
    def self.iconv_name(encoding : String) : String
      case canonical = canonical_name(encoding)
      when "IBM866" then "CP866" # musl knows only "cp866"; the others accept both names
      else               canonical
      end
    end
  end
end
