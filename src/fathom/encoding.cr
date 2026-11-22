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
      "WINDOWS-1250",
      "WINDOWS-1251",
      "WINDOWS-1253",
      "WINDOWS-1254",
      "WINDOWS-1255",
      "WINDOWS-1256",
      "WINDOWS-1257",
      "WINDOWS-874",
      "ISO-8859-2",
      "ISO-8859-5",
      "ISO-8859-6",
      "ISO-8859-7",
      "KOI8-R",
      "KOI8-U",
      "IBM866",
      "IBM437",
      "IBM850",
      "IBM852",
      "MACINTOSH",
      "X-MAC-CYRILLIC",
    }

    # ISO/Windows pairs collapsed to the Windows superset because it shares the
    # script codepoints and decodes the ISO variant (most differ only in `0x80..0x9F`;
    # `WINDOWS-1255` also adds Hebrew niqqud/points over `ISO-8859-8`).
    ISO_WINDOWS_ALIASES = {
      "ISO-8859-1"  => "WINDOWS-1252",
      "ISO-8859-8"  => "WINDOWS-1255",
      "ISO-8859-9"  => "WINDOWS-1254",
      "ISO-8859-11" => "WINDOWS-874",
      "ISO-8859-13" => "WINDOWS-1257",
      "TIS-620"     => "WINDOWS-874",
    }

    # WHATWG labels for the supported encodings, plus the ISO/Windows rule.
    # Labels for other encodings are added together with their probers.
    ALIASES = {
      "UTF8"                => "UTF-8",
      "UNICODE-1-1-UTF-8"   => "UTF-8",
      "UTF-16"              => "UTF-16LE",
      "ASCII"               => "WINDOWS-1252",
      "US-ASCII"            => "WINDOWS-1252",
      "ANSI_X3.4-1968"      => "WINDOWS-1252",
      "LATIN1"              => "WINDOWS-1252",
      "L1"                  => "WINDOWS-1252",
      "ISO_8859-1"          => "WINDOWS-1252",
      "ISO8859-1"           => "WINDOWS-1252",
      "CP1252"              => "WINDOWS-1252",
      "X-CP1252"            => "WINDOWS-1252",
      "CP1250"              => "WINDOWS-1250",
      "X-CP1250"            => "WINDOWS-1250",
      "CP1251"              => "WINDOWS-1251",
      "X-CP1251"            => "WINDOWS-1251",
      "CP1253"              => "WINDOWS-1253",
      "X-CP1253"            => "WINDOWS-1253",
      "CP1254"              => "WINDOWS-1254",
      "X-CP1254"            => "WINDOWS-1254",
      "LATIN5"              => "WINDOWS-1254",
      "L5"                  => "WINDOWS-1254",
      "ISO_8859-9"          => "WINDOWS-1254",
      "ISO8859-9"           => "WINDOWS-1254",
      "CP1255"              => "WINDOWS-1255",
      "X-CP1255"            => "WINDOWS-1255",
      "ISO_8859-8"          => "WINDOWS-1255",
      "ISO8859-8"           => "WINDOWS-1255",
      "ISO-8859-8-I"        => "WINDOWS-1255",
      "HEBREW"              => "WINDOWS-1255",
      "VISUAL"              => "WINDOWS-1255",
      "CP1256"              => "WINDOWS-1256",
      "X-CP1256"            => "WINDOWS-1256",
      "CP1257"              => "WINDOWS-1257",
      "X-CP1257"            => "WINDOWS-1257",
      "CP874"               => "WINDOWS-874",
      "DOS-874"             => "WINDOWS-874",
      "ISO8859-11"          => "WINDOWS-874",
      "LATIN2"              => "ISO-8859-2",
      "L2"                  => "ISO-8859-2",
      "ISO_8859-2"          => "ISO-8859-2",
      "ISO8859-2"           => "ISO-8859-2",
      "CYRILLIC"            => "ISO-8859-5",
      "ISO_8859-5"          => "ISO-8859-5",
      "ISO8859-5"           => "ISO-8859-5",
      "ARABIC"              => "ISO-8859-6",
      "ASMO-708"            => "ISO-8859-6",
      "ECMA-114"            => "ISO-8859-6",
      "ISO_8859-6"          => "ISO-8859-6",
      "ISO8859-6"           => "ISO-8859-6",
      "GREEK"               => "ISO-8859-7",
      "GREEK8"              => "ISO-8859-7",
      "ELOT_928"            => "ISO-8859-7",
      "ECMA-118"            => "ISO-8859-7",
      "ISO_8859-7"          => "ISO-8859-7",
      "ISO8859-7"           => "ISO-8859-7",
      "CP866"               => "IBM866",
      "866"                 => "IBM866",
      "CSIBM866"            => "IBM866",
      "CP437"               => "IBM437",
      "437"                 => "IBM437",
      "CSPC8CODEPAGE437"    => "IBM437",
      "CP850"               => "IBM850",
      "850"                 => "IBM850",
      "CSPC850MULTILINGUAL" => "IBM850",
      "CP852"               => "IBM852",
      "852"                 => "IBM852",
      "CSPC852"             => "IBM852",
      "KOI8"                => "KOI8-R",
      "KOI8_R"              => "KOI8-R",
      "CSKOI8R"             => "KOI8-R",
      "KOI8-RU"             => "KOI8-U",
      "MAC"                 => "MACINTOSH",
      "MACROMAN"            => "MACINTOSH",
      "X-MAC-ROMAN"         => "MACINTOSH",
      "CSMACINTOSH"         => "MACINTOSH",
      "MACCYRILLIC"         => "X-MAC-CYRILLIC",
      "X-MAC-UKRAINIAN"     => "X-MAC-CYRILLIC",
      "CP10007"             => "X-MAC-CYRILLIC",
    }.merge(ISO_WINDOWS_ALIASES)

    # Normalizes *label* to Fathom's canonical uppercase encoding name.
    # Applies the ISO/Windows alias rule (e.g. `"ISO-8859-1"` -> `"WINDOWS-1252"`).
    def self.canonical_name(label : String) : String
      if normalized_already?(label)
        return ALIASES[label]? || label
      end
      normalized = label.strip.upcase
      ALIASES[normalized]? || normalized
    end

    private def self.normalized_already?(label : String) : Bool
      bytes = label.to_slice
      return true if bytes.empty?
      return false if bytes.unsafe_fetch(0) <= 0x20 || bytes.unsafe_fetch(bytes.size - 1) <= 0x20
      bytes.each do |b|
        return false if b >= 0x80_u8 || ('a'.ord <= b <= 'z'.ord)
      end
      true
    end

    # Returns the encoding name to pass to Crystal's `String.new(bytes, name)` (`iconv`)
    # for the given canonical *encoding*.
    #
    # Names are chosen to work across glibc, musl, macOS libiconv, and Windows where supported.
    def self.iconv_name(encoding : String) : String
      case canonical = canonical_name(encoding)
      when "IBM866"         then "CP866" # musl knows only "cp866"; the others accept both names
      when "IBM437"         then "CP437" # musl knows only "cp437"; the others accept both names
      when "IBM850"         then "CP850" # musl knows only "cp850"; the others accept both names
      when "IBM852"         then "CP852"
      when "X-MAC-CYRILLIC" then "MACCYRILLIC"
      when "MACINTOSH"
        {% if flag?(:win32) %}
          "MACROMAN"
        {% else %}
          "MACINTOSH"
        {% end %}
      else
        canonical
      end
    end
  end
end
