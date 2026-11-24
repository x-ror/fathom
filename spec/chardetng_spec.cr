require "./spec_helper"
require "../src/fathom/chardetng"

private CORPUS_DIR = File.expand_path("fixtures/corpus", __DIR__)

# Expected guesses come from upstream chardetng 1.0.0
# (`guess(None, Utf8Detection::Allow)`, ISO-2022-JP allowed).
# Columns: path relative to fixtures/corpus, prefix length (-1 = whole file), guess.
private EXPECTED = File.read_lines(File.expand_path("fixtures/chardetng_expected.tsv", __DIR__)).map(&.split('\t'))

private def hex_bytes(hex : String) : Bytes
  Bytes.new(hex.size // 2) { |i| hex[2 * i, 2].to_u8(16) }
end

# chardetng's own CJK test strings (src/lib.rs), encoded as upstream encodes them.
private UPSTREAM_CJK_CASES = [
  {"日本語", "ISO-2022-JP", "1B2442467C4B5C386C1B2842"},
  {"这是一个字符编码测试。", "GBK", "D5E2CAC7D2BBB8F6D7D6B7FBB1E0C2EBB2E2CAD4A1A3"},
  {"這是一個字符編碼測試。", "BIG5", "B36FAC4FA440ADD3A672B2C5BD73BD58B4FAB8D5A143"},
  {"이것은 문자 인코딩 테스트입니다.", "EUC-KR", "C0CCB0CDC0BA20B9AEC0DA20C0CEC4DAB5F920C5D7BDBAC6AEC0D4B4CFB4D92E"},
  {"これは文字実験です。 (Shift_JIS)", "SHIFT_JIS", "82B182EA82CD95B68E9A8EC08CB182C582B78142"},
  {"これは文字実験です。 (EUC-JP)", "EUC-JP", "A4B3A4ECA4CFCAB8BBFABCC2B8B3A4C7A4B9A1A3"},
  {"ﾊｰﾄﾞｳｪｱ x5", "SHIFT_JIS", "CAB0C4DEB3AAB1CAB0C4DEB3AAB1CAB0C4DEB3AAB1CAB0C4DEB3AAB1CAB0C4DEB3AAB1"},
]

# Edge cases; expected guesses come from upstream chardetng 1.0.0.
private CJK_EDGE_CASES = [
  {"empty", "UTF-8", ""},
  {"ASCII", "UTF-8", "706C61696E2041534349492074657874"},
  {"ANSI escape (ESC not starting ISO-2022-JP)", "UTF-8", "1B5B33316D7265641B5B306D2074657874"},
  {"ISO-2022-JP after an ASCII prefix", "ISO-2022-JP", "616263201B2442467C4B5C386C1B2842"},
  {"ISO-2022-JP followed by a byte >= 0x80", "WINDOWS-1252", "1B2442467C4B5C386C1B284220636166E9"},
  {"Shift_JIS cut inside the last character", "WINDOWS-1252", "82B182EA82CD95B68E9A8EC08CB182C582B781"},
  {"EUC-JP cut inside the last character", "WINDOWS-1252", "A4B3A4ECA4CFCAB8BBFABCC2B8B3A4C7A4B9A1"},
  {"GBK with a four-byte gb18030 character", "GBK", "D5E2CAC7D2BBB8F6D7D6B7FBB1E0C2EBB2E2CAD4A1A39439FC39B2E2CAD4"},
  {"Big5 with a plane-2 character", "BIG5", "B36FAC4FA440ADD3A672B2C5BD73BD58B4FAB8D5A1438740B4FAB8D5"},
]

private def sample(path : String, limit : Int32) : Bytes
  bytes = File.open(File.join(CORPUS_DIR, path), "rb", &.getb_to_end)
  limit < 0 ? bytes : bytes[0, Math.min(limit, bytes.size)]
end

describe Fathom::Chardetng do
  it "matches upstream chardetng on the fixture corpus" do
    EXPECTED.should_not be_empty
    EXPECTED.each do |(path, limit, expected)|
      {path, limit, Fathom::Chardetng.guess(sample(path, limit.to_i))}.should eq({path, limit, expected})
    end
  end

  it "gives the same guess regardless of how the stream is chunked" do
    EXPECTED.each do |(path, limit, expected)|
      bytes = sample(path, limit.to_i)
      [1, 2, 7, 64].each do |chunk|
        detector = Fathom::Chardetng::Detector.new
        offset = 0
        while offset + chunk < bytes.size
          detector.feed(bytes[offset, chunk], last: false)
          offset += chunk
        end
        detector.feed(bytes[offset..], last: true)
        {path, limit, chunk, detector.guess}.should eq({path, limit, chunk, expected})
      end
    end
  end

  it "detects CJK and ISO-2022-JP (upstream test cases)" do
    UPSTREAM_CJK_CASES.each do |(name, encoding, hex)|
      {name, Fathom::Chardetng.guess(hex_bytes(hex))}.should eq({name, encoding})
    end
  end

  it "matches upstream on CJK and ISO-2022-JP edge cases" do
    CJK_EDGE_CASES.each do |(name, encoding, hex)|
      {name, Fathom::Chardetng.guess(hex_bytes(hex))}.should eq({name, encoding})
    end
  end

  it "gives the same CJK and ISO-2022-JP guesses regardless of chunking" do
    (UPSTREAM_CJK_CASES + CJK_EDGE_CASES).each do |(name, encoding, hex)|
      bytes = hex_bytes(hex)
      [1, 2, 7].each do |chunk|
        detector = Fathom::Chardetng::Detector.new
        offset = 0
        while offset + chunk < bytes.size
          detector.feed(bytes[offset, chunk], last: false)
          offset += chunk
        end
        detector.feed(bytes[offset..], last: true)
        {name, chunk, detector.guess}.should eq({name, chunk, encoding})
      end
    end
  end

  it "detects visual-order Hebrew (upstream test case)" do
    Fathom::Chardetng.guess(".\xed\xe9\xe5\xe5\xfa \xe3\xe5\xe3\xe9\xf7 \xef\xe7\xe1\xee \xe5\xe4\xe6".to_slice).should eq "ISO-8859-8"
  end

  it "scores Spanish ordinals and rejects truncated UTF-8" do
    Fathom::Chardetng.guess("n.\xBA1 y la 3\xAA ".to_slice).should eq "WINDOWS-1252"
    Fathom::Chardetng.guess("caf\xC3".to_slice).should_not eq "UTF-8"
    Fathom::Chardetng.guess("caf\xC3\xA9".to_slice).should eq "UTF-8"
  end

  it "sizes MAX_SCORES for every single-byte candidate, visual Hebrew and the five CJK candidates" do
    Fathom::Chardetng::Detector::MAX_SCORES.should eq Fathom::Chardetng::Detector::CAPACITY + 6
  end

  it "raises when fed after the last chunk" do
    detector = Fathom::Chardetng::Detector.new
    detector.feed(Bytes.empty, last: true)
    expect_raises(ArgumentError) { detector.feed(Bytes.empty, last: false) }
  end
end
