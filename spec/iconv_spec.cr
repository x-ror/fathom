require "./spec_helper"

# Fathom encodings the platform iconv cannot decode, filled in from CI results per platform
# (e.g. `{% if flag?(:musl) %}Set{"IBM866"}{% else %}...`). Detection itself stays
# platform-independent; only decoding raises ArgumentError.
private KNOWN_UNSUPPORTED_ICONV = begin
  {% if flag?(:musl) %}
    Set{"IBM852", "MACINTOSH", "X-MAC-CYRILLIC", "WINDOWS-874"}
  {% else %}
    Set(String).new
  {% end %}
end

private FIXTURE_CORPUS_DIR = File.expand_path("fixtures/corpus", __DIR__)

private struct UnsupportedEncodingProber
  include Fathom::Prober

  def probe(bytes : Bytes, stats : Fathom::ByteStats) : Fathom::Match?
    return nil if stats.high_bytes == 0
    Fathom::Match.new("X-FATHOM-UNSUPPORTED-ICONV", 0.99)
  end
end

describe "Cross-platform iconv compatibility" do
  it "verifies String.new and Fathom.decode support for every Fathom encoding" do
    Fathom::Encoding::SUPPORTED.each do |encoding|
      iconv_name = Fathom::Encoding.iconv_name(encoding)
      sample_dir = File.join(FIXTURE_CORPUS_DIR, encoding)
      Dir.exists?(sample_dir).should be_true

      sample_file = Dir.children(sample_dir).sort.first
      bytes = File.open(File.join(sample_dir, sample_file), "rb", &.getb_to_end)

      match = Fathom.match(bytes).should_not be_nil
      match.encoding.should eq encoding
      match.iconv_name.should eq iconv_name

      payload = match.bom? ? bytes[Fathom::BOM.byte_size(encoding), bytes.size - Fathom::BOM.byte_size(encoding)] : bytes

      if KNOWN_UNSUPPORTED_ICONV.includes?(encoding)
        expect_raises(ArgumentError) { String.new(payload, iconv_name) }
        expect_raises(ArgumentError) { Fathom.decode(bytes) }
      else
        direct = String.new(payload, iconv_name)
        decoded = Fathom.decode(bytes).should_not be_nil
        decoded.should eq direct
        decoded.valid_encoding?.should be_true
      end
    end
  end

  it "maps every built-in SingleByte prober to a decodable iconv name" do
    Fathom::SingleByte::PROBERS.each do |prober|
      table = prober.as(Fathom::SingleByte::Table)
      Fathom::Encoding::SUPPORTED.includes?(table.encoding).should be_true

      iconv_name = Fathom::Encoding.iconv_name(table.encoding)
      unless KNOWN_UNSUPPORTED_ICONV.includes?(table.encoding)
        String.new("A".to_slice, iconv_name).should eq "A"
      end
    end
  end

  it "keeps detection platform-independent and raises ArgumentError in decode when iconv cannot decode" do
    detector = Fathom::Detector.new(probers: [UnsupportedEncodingProber.new] of Fathom::Prober)
    bytes = Bytes[0xC0, 0xC1, 0xC2]

    detector.detect(bytes).should eq "X-FATHOM-UNSUPPORTED-ICONV"
    expect_raises(ArgumentError) { detector.decode(bytes) }
  end
end
