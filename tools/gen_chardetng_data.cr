# Generates src/fathom/chardetng/data.cr from chardetng's src/data.rs (CC0 / public domain).
#
#   crystal run tools/gen_chardetng_data.cr -- ~/.cargo/registry/src/*/chardetng-1.0.0/src/data.rs
#
# The u8 tables of the single-byte candidates are emitted as is; the CJK
# frequency tables (u16) as little-endian byte pairs.
#
# Byte-class tables for encodings chardetng lacks (DOS, Mac, KOI8-R) are
# derived: chardetng classes are per character, so each byte is decoded with
# the host iconv and given the class the same character has in the upstream
# tables of its script. Symbols are classed by their behaviour in any upstream
# table; anything unknown counts as implausible next to letters. In IBM437, the
# box-art code page, box-drawing and block characters are space-like so frames
# and tables don't count against it. The acute accent is space-like too: DOS
# text uses it as the apostrophe the code pages lack ("l´Ardèche").

# Upstream byte-class tables: name => {iconv name, script, ascii + non_ascii classes}.
UPSTREAM = {
  "windows_1252"           => {"WINDOWS-1252", "western", 59},
  "windows_1250"           => {"WINDOWS-1250", "central", 68},
  "iso_8859_2"             => {"ISO-8859-2", "central", 68},
  "windows_1251"           => {"WINDOWS-1251", "cyrillic", 46},
  "koi8_u"                 => {"KOI8-U", "cyrillic", 46},
  "iso_8859_5"             => {"ISO-8859-5", "cyrillic", 46},
  "ibm866"                 => {"CP866", "cyrillic", 46},
  "windows_1258"           => {"WINDOWS-1258", "vietnamese", 52},
  "windows_1252_icelandic" => {"WINDOWS-1252", "icelandic", 40},
  "windows_1253"           => {"WINDOWS-1253", "greek", 37},
  "iso_8859_7"             => {"ISO-8859-7", "greek", 37},
  "windows_1254"           => {"WINDOWS-1254", "turkish", 39},
  "windows_1255"           => {"WINDOWS-1255", "hebrew", 36},
  "iso_8859_8"             => {"ISO-8859-8", "hebrew", 36},
  "windows_1256"           => {"WINDOWS-1256", "arabic", 53},
  "iso_8859_6"             => {"ISO-8859-6", "arabic", 53},
  "windows_1257"           => {"WINDOWS-1257", "baltic", 46},
  "iso_8859_13"            => {"ISO-8859-13", "baltic", 46},
  "iso_8859_4"             => {"ISO-8859-4", "baltic", 46},
  "windows_874"            => {"WINDOWS-874", "thai", 72},
}

# Derived byte-class tables, same shape as UPSTREAM.
BOX_ART = {"ibm437"}
DERIVED = {
  "ibm437"         => {"CP437", "western", 59},
  "ibm850"         => {"CP850", "western", 59},
  "macintosh"      => {"MACINTOSH", "western", 59},
  "ibm852"         => {"CP852", "central", 68},
  "koi8_r"         => {"KOI8-R", "cyrillic", 46},
  "x_mac_cyrillic" => {"MACCYRILLIC", "cyrillic", 46},
}

OTHER_TABLES = %w[
  latin_ascii non_latin_ascii turkish_ascii
  vietnamese central cyrillic western icelandic greek turkish hebrew arabic baltic thai
]

ASCII_DIGIT  =  100
UNSTORED_TAG = 1000 # semantic entries >= this are offsets past the script boundary

def decode(iconv : String, byte : Int32) : Char?
  s = String.new(Bytes[byte.to_u8], iconv) rescue return nil
  return nil unless s.size == 1
  c = s[0]
  c.ord.in?(0x80..0x9F) ? nil : c # C1 controls disqualify, as upstream
end

def derive(iconv : String, script : String, boundary : Int32, box_art : Bool, upstream : Hash(String, Array(UInt8))) : Array(UInt8)
  letters = {} of Char => UInt8
  semantic = {} of Char => Int32
  same_script = Set(Char).new
  # Same-script tables first so their symbol classes win.
  refs = UPSTREAM.to_a.sort_by! { |(_, (_, s, _))| s == script ? 0 : 1 }
  refs.each do |(name, (ref_iconv, ref_script, ref_boundary))|
    table = upstream[name]
    128.times do |i|
      c = decode(ref_iconv, i + 128) || next
      klass = table[i]
      next if klass == 255
      caseless = (klass & 0x7F).to_i
      same_script << c if ref_script == script
      if caseless == 0 || caseless == ASCII_DIGIT
        semantic[c] ||= caseless
      elsif caseless >= ref_boundary
        semantic[c] ||= UNSTORED_TAG + ((caseless - ref_boundary) | (klass & 0x80).to_i)
      elsif ref_script == script
        letters[c] ||= klass
      end
    end
  end
  Array.new(128) do |i|
    c = decode(iconv, i + 128)
    if c.nil?
      255_u8
    elsif c == '´' || (box_art && c.ord.in?(0x2500..0x259F) && !same_script.includes?(c))
      0_u8 # space-like
    elsif letter = letters[c]?
      letter
    elsif s = semantic[c]?
      if s >= UNSTORED_TAG
        offset = s - UNSTORED_TAG
        (((offset & 0x7F) + boundary) | (offset & 0x80)).to_u8
      else
        s.to_u8
      end
    else
      (boundary + 1).to_u8 # IMPLAUSIBLE_NEXT_TO_ALPHABETIC_ON_EITHER_SIDE
    end
  end
end

def emit(io : IO, name : String, bytes : Array(UInt8), last : Bool) : Nil
  io << "    # :nodoc:\n    " << name.upcase << " = (\n"
  rows = bytes.each_slice(32).to_a
  rows.each_with_index do |row, i|
    io << "      \""
    row.each { |b| io << "\\x" << b.to_s(16).rjust(2, '0') }
    io << '"' << (i == rows.size - 1 ? "" : " \\") << '\n'
  end
  io << "    ).to_slice # #{bytes.size} bytes\n"
  io << "\n" unless last
end

src_path = ARGV[0]? || abort "usage: gen_chardetng_data <path/to/chardetng/src/data.rs> [out.cr]"
out_path = ARGV[1]? || File.expand_path("../src/fathom/chardetng/data.cr", __DIR__)
src = File.read(src_path)
body = src[src.index!("pub static DETECTOR_DATA")..]

tables = (UPSTREAM.keys + OTHER_TABLES).to_h do |name|
  m = body.match(/\n\s+#{name}: \[([^\]]*)\]/) || abort "table #{name} not found"
  {name, m[1].scan(/\d+/).map(&.[0].to_u8)}
end
derived = DERIVED.to_h { |name, (iconv, script, boundary)| {name, derive(iconv, script, boundary, BOX_ART.includes?(name), tables)} }

# Most frequent CJK code points, in rank order (u16 hex in data.rs).
FREQUENT = %w[frequent_simplified frequent_kanji frequent_hangul]
frequent = FREQUENT.to_h do |name|
  m = body.match(/\n\s+#{name}: \[([^\]]*)\]/) || abort "table #{name} not found"
  values = m[1].scan(/0x([0-9A-Fa-f]+)/).map(&.[1].to_i(16))
  abort "#{name}: expected 128 entries, got #{values.size}" unless values.size == 128
  {name, values.flat_map { |v| [(v & 0xFF).to_u8, (v >> 8).to_u8] }}
end

code = String.build do |io|
  io << "# Generated by tools/gen_chardetng_data.cr from chardetng 1.0.0 src/data.rs. Do not edit.\n"
  io << "# The upstream tables are dedicated to the public domain (CC0) by the chardetng authors.\n"
  io << "module Fathom\n  module Chardetng\n"
  tables.each { |name, bytes| emit(io, name, bytes, false) }
  io << "    # Most frequent CJK code points in rank order, as little-endian UInt16.\n\n"
  frequent.each { |name, bytes| emit(io, name, bytes, false) }
  io << "    # Derived from the upstream tables via the host iconv; see tools/gen_chardetng_data.cr.\n\n"
  derived.each_with_index { |(name, bytes), i| emit(io, name, bytes, i == derived.size - 1) }
  io << "  end\nend\n"
end
File.write(out_path, code)
puts "wrote #{out_path}"
