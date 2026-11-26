require "./spec_helper"

# Property specs over random, mutated and truncated input, aimed at the
# multi-byte state machines. Deterministic by default; for a longer run:
#
#   FUZZ_SEED=7 FUZZ_ITERATIONS=100000 crystal spec spec/fuzz_spec.cr
private FUZZ_SEED       = (ENV["FUZZ_SEED"]? || "1").to_u64
private FUZZ_ITERATIONS = (ENV["FUZZ_ITERATIONS"]? || "1500").to_i
private MULTI_BYTE      = {"SHIFT_JIS", "EUC-JP", "EUC-KR", "BIG5", "GBK", "ISO-2022-JP"}
private FUZZ_CORPUS     = Dir.glob(File.expand_path("fixtures/corpus/*/*", __DIR__)).sort.map do |path|
  {File.basename(File.dirname(path)), File.open(path, "rb", &.getb_to_end)}
end

# Random input shaped to reach the CJK decoders' states: uniform bytes, high
# bytes, lead/trail-like pairs, ISO-2022-JP escape fragments, NUL-heavy (UTF-16/32)
# and corpus slices with a few bytes overwritten.
private def fuzz_input(r : Random) : Bytes
  n = r.rand(0..300)
  case r.rand(6)
  when 0 then Bytes.new(n) { r.rand(256).to_u8 }
  when 1 then Bytes.new(n) { r.rand(0x80..0xFF).to_u8 }
  when 2 then Bytes.new(n) { (r.rand(3) == 0 ? r.rand(0x20..0x7E) : r.rand(0x81..0xFE)).to_u8 }
  when 3 then Bytes.new(n) { (r.rand(4) == 0 ? 0x1B : {0x24, 0x28, 0x40, 0x41, 0x42, 0x49, 0x4A, r.rand(0x21..0x7E)}.sample(r)).to_u8 }
  when 4 then Bytes.new(n) { (r.rand(2) == 0 ? 0 : r.rand(256)).to_u8 }
  else
    _, source = FUZZ_CORPUS.sample(r)
    bytes = source[r.rand(0..source.size // 2), Math.min(n, source.size // 2)].dup
    r.rand(0..3).times { bytes[r.rand(bytes.size)] = r.rand(256).to_u8 } unless bytes.empty?
    bytes
  end
end

private def fuzz(&)
  r = Random.new(FUZZ_SEED)
  FUZZ_ITERATIONS.times do
    bytes = fuzz_input(r)
    begin
      yield bytes, r
    rescue e
      fail "#{e.class}: #{e.message} on #{bytes.hexstring} (FUZZ_SEED=#{FUZZ_SEED})"
    end
  end
end

private def summary(m : Fathom::Match?)
  m.try { |x| {x.encoding, x.confidence, x.bom?, x.language} }
end

describe "Fuzzing" do
  it "returns consistent, supported matches" do
    fuzz do |bytes|
      m = Fathom.match(bytes)
      all = Fathom.detect_all(bytes)
      if m
        Fathom::Encoding::SUPPORTED.should contain m.encoding
        (0.0..1.0).should contain m.confidence
        {all[0].encoding, all[0].confidence}.should eq({m.encoding, m.confidence})
      else
        all.should be_empty
      end
    end
  end

  it "gives the same answer for bytes and IO, at any sample size" do
    fuzz do |bytes, r|
      summary(Fathom.match(IO::Memory.new(bytes))).should eq summary(Fathom.match(bytes))
      detector = Fathom::Detector.new(sample_size: r.rand(1..64))
      summary(detector.match(IO::Memory.new(bytes))).should eq summary(detector.match(bytes))
    end
  end

  it "decodes with invalid: :skip without raising" do
    fuzz do |bytes|
      Fathom.decode(bytes, invalid: :skip)
    rescue e : ArgumentError
      raise e unless e.message.to_s.starts_with?("Invalid encoding") # not in this platform's iconv
    end
  end

  it "feeds chardetng in chunks the same as at once" do
    fuzz do |bytes, r|
      {false, true}.each do |extended|
        whole = Fathom::Chardetng::Detector.new(extended: extended)
        whole.feed(bytes, last: true)
        chunked = Fathom::Chardetng::Detector.new(extended: extended)
        i = 0
        while i < bytes.size
          len = Math.min(r.rand(1..8), bytes.size - i)
          chunked.feed(bytes[i, len], last: false)
          i += len
        end
        chunked.feed(Bytes.empty, last: true)
        chunked.result.should eq whole.result
      end
    end
  end

  it "finds a stable character boundary in every multi-byte encoding" do
    fuzz do |bytes|
      MULTI_BYTE.each do |encoding|
        size = Fathom::WHATWG.complete_prefix_size(encoding, bytes)
        (0..bytes.size).should contain size
        Fathom::WHATWG.complete_prefix_size(encoding, bytes[0, size]).should eq size
      end
    end
  end

  it "decodes every prefix of CJK text detected as its encoding" do
    FUZZ_CORPUS.each do |(encoding, source)|
      next unless MULTI_BYTE.includes?(encoding)
      text = source[0, Math.min(source.size, 300)]
      (1..text.size).each do |n|
        prefix = text[0, n]
        Fathom.decode(prefix) if Fathom.detect(prefix) == encoding
      end
    end
  end
end
