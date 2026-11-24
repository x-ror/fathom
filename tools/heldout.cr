# Held-out accuracy benchmark: test files Fathom was never tuned on.
#
#   crystal run tools/heldout.cr
#
# Samples come from the uchardet test suite (test/<lang>/<charset>) and the
# check("...", ENCODING) cases in chardetng's src/lib.rs, limited to encodings
# Fathom can report. They are downloaded into tools/heldout_data/ on first run
# and never committed (uchardet's tests are MPL-1.1/GPL/LGPL). The files are
# only read as data.
#
# Each sample is scored at the 64B and 256B prefixes and in full; a pure-ASCII
# prefix of a non-UTF sample is skipped since UTF-8 is the right label for it.
# An answer is correct when it decodes the sample to the same text as the true
# encoding (both sides with `invalid: :skip`, so a cut trailing character
# doesn't count), e.g. WINDOWS-1257 is right for ISO-8859-13 text that has none
# of the bytes where the two differ.
require "http/client"
require "digest/sha256"
require "../src/fathom"

UCHARDET_COMMIT = "06029ec3340cdf6bf9a6a537dafb3f39eda0560e"
# GitLab builds archives on the fly, so the pinned commit (not a hash) fixes the content.
UCHARDET_URL     = "https://gitlab.freedesktop.org/uchardet/uchardet/-/archive/#{UCHARDET_COMMIT}/uchardet-#{UCHARDET_COMMIT}.tar.gz"
CHARDETNG_URL    = "https://static.crates.io/crates/chardetng/chardetng-1.0.0.crate"
CHARDETNG_SHA256 = "13de944a44b5064ee5d3a5ceccc49a41bfec50f2580e66f82e87703acdb88b53"

CACHE = File.expand_path("heldout_data", __DIR__)
SIZES = [64, 256, nil]

record Sample, name : String, encoding : String, iconv : String, bytes : Bytes

# Downloads *url* into the cache (once) and extracts it into its own directory.
def fetch(url : String, archive : String, sha256 : String? = nil) : String
  path = File.join(CACHE, archive)
  dir = File.join(CACHE, archive.sub(/\.(tar\.gz|crate)$/, ""))
  return dir if Dir.exists?(dir)

  Dir.mkdir_p(CACHE)
  unless File.exists?(path)
    STDERR.puts "fetching #{url}"
    HTTP::Client.get(url) do |res|
      abort "#{url}: HTTP #{res.status_code}" unless res.success?
      File.open(path, "wb") { |f| IO.copy(res.body_io, f) }
    end
  end
  if sha256 && (actual = Digest::SHA256.new.file(path).hexfinal) != sha256
    File.delete(path)
    abort "#{archive}: SHA-256 #{actual}, expected #{sha256}"
  end
  Dir.mkdir_p(dir)
  status = Process.run("tar", ["-xzf", path, "-C", dir, "--strip-components=1"], error: STDERR)
  abort "tar failed for #{archive}" unless status.success?
  dir
end

# Upstream label ("iso-8859-1", "ibm852", "utf-16.be", "WINDOWS_1252") -> {canonical, iconv}.
def labels(name : String) : {String, String}
  raw = name.upcase.tr("_", "-").sub(".BE", "BE").sub(".LE", "LE")
  raw = "X-MAC-CYRILLIC" if raw == "MAC-CYRILLIC"
  canonical = Fathom::Encoding.canonical_name(raw)
  iconv = case raw
          when /^IBM(\d+)$/       then "CP#{$1}"
          when "X-MAC-CYRILLIC"   then "MACCYRILLIC"
          when "UTF-16", "UTF-32" then raw + "BE"
          else                         raw
          end
  {canonical, iconv}
end

def unescape(rust : String) : String
  rust.gsub(/\\(u\{([0-9A-Fa-f]+)\}|.)/) do |_, m|
    if hex = m[2]?
      hex.to_i(16).chr.to_s
    else
      case m[1]
      when "n" then "\n"
      when "t" then "\t"
      else          m[1]
      end
    end
  end
end

def samples : Array(Sample)
  result = [] of Sample
  supported = ->(canonical : String) { Fathom::Encoding::SUPPORTED.includes?(canonical) }

  uchardet = fetch(UCHARDET_URL, "uchardet.tar.gz")
  Dir.glob(File.join(uchardet, "test", "*", "*")).sort.each do |path|
    file = File.basename(path)
    next if file.ends_with?(".c") || file == "CMakeLists.txt"
    canonical, iconv = labels(file.rchop(".txt"))
    next unless supported.call(canonical)
    lang = File.basename(File.dirname(path))
    result << Sample.new("uchardet/#{lang}/#{file}", canonical, iconv, File.open(path, "rb", &.getb_to_end))
  end

  chardetng = fetch(CHARDETNG_URL, "chardetng-1.0.0.crate", CHARDETNG_SHA256)
  source = File.read(File.join(chardetng, "src", "lib.rs"))
  source.scan(/\bcheck\("((?:[^"\\]|\\.)*)",\s*([A-Z0-9_]+)\)/).each_with_index do |m, i|
    canonical, iconv = labels(m[2])
    next unless supported.call(canonical)
    bytes = unescape(m[1]).encode(iconv) rescue next # not representable in that encoding
    result << Sample.new("chardetng/check_#{i}", canonical, iconv, bytes)
  end
  result
end

def decode(bytes : Bytes, iconv : String) : String?
  String.new(bytes, iconv, invalid: :skip)
rescue ArgumentError
  nil
end

totals = Hash(String, {Int32, Int32}).new({0, 0})
full_by_encoding = Hash(String, {Int32, Int32}).new({0, 0})
misses = [] of String

samples.each do |sample|
  SIZES.each do |limit|
    next if limit && limit >= sample.bytes.size
    slice = limit ? sample.bytes[0, limit] : sample.bytes
    next if !sample.encoding.starts_with?("UTF") && slice.all? { |b| b < 0x80 }

    match = Fathom.match(slice)
    expected = decode(slice, sample.iconv)
    ok = !match.nil? && !expected.nil? && decode(slice, match.iconv_name) == expected

    key = limit ? "#{limit}B" : "full"
    hits, count = totals[key]
    totals[key] = {hits + (ok ? 1 : 0), count + 1}
    next if limit

    hits, count = full_by_encoding[sample.encoding]
    full_by_encoding[sample.encoding] = {hits + (ok ? 1 : 0), count + 1}
    misses << "#{sample.name} (#{sample.encoding}) -> #{match.try(&.encoding) || "nil"}" unless ok
  end
end

pct = ->(hits : Int32, count : Int32) { count.zero? ? "-" : "#{(hits * 100.0 / count).round(2)}%" }

puts "| Input Size | Correct | Total | Accuracy |"
puts "| --- | ---: | ---: | ---: |"
all_hits = all_count = 0
SIZES.each do |limit|
  key = limit ? "#{limit}B" : "full"
  hits, count = totals[key]
  all_hits += hits
  all_count += count
  puts "| #{key} | #{hits} | #{count} | #{pct.call(hits, count)} |"
end
puts "| **Overall** | **#{all_hits}** | **#{all_count}** | **#{pct.call(all_hits, all_count)}** |"

puts "\nFull files by encoding:"
full_by_encoding.to_a.sort_by!(&.[0]).each do |encoding, (hits, count)|
  puts "  #{encoding.ljust(15)} #{hits}/#{count}"
end
puts "\nFull-file misses:" unless misses.empty?
misses.each { |miss| puts "  #{miss}" }
