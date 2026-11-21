require "benchmark"
require "../src/fathom"

ascii = ("The quick brown fox jumps over the lazy dog.\n" * 100).to_slice
utf8 = ("Съешь же ещё этих мягких французских булок, да выпей чаю.\n" * 40).to_slice
# Build a ~4 KiB UTF-16LE buffer without repeating headers.
utf16le_buf = ("The quick brown fox jumps over the lazy dog.\n" * 45).encode("UTF-16LE")
win1251 = ("Съешь же ещё этих мягких французских булок, да выпей чаю.\n" * 70).encode("WINDOWS-1251")
win1252 = ("Voilà l'été : les élèves ont déjà oublié leçons et problèmes.\n" * 70).encode("WINDOWS-1252")
win1251_1mb = ("Съешь же ещё этих мягких французских булок, да выпей чаю.\n" * 18_000).encode("WINDOWS-1251")

puts "Sample sizes: ASCII=#{ascii.size}B, UTF-8=#{utf8.size}B, UTF-16LE=#{utf16le_buf.size}B, WIN1251=#{win1251.size}B, WIN1252=#{win1252.size}B, 1MB=#{win1251_1mb.size}B"

Benchmark.ips do |x|
  x.report("ASCII (4 KiB)") { Fathom.detect(ascii) }
  x.report("UTF-8 (4 KiB)") { Fathom.detect(utf8) }
  x.report("UTF-16LE (4 KiB)") { Fathom.detect(utf16le_buf) }
  x.report("WINDOWS-1251 (4 KiB)") { Fathom.detect(win1251) }
  x.report("WINDOWS-1252 (4 KiB)") { Fathom.detect(win1252) }
  x.report("WINDOWS-1251 (1 MiB)") { Fathom.detect(win1251_1mb) }
end
