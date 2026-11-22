require "./spec_helper"
require "../src/fathom/chardetng"

private CORPUS_DIR = File.expand_path("fixtures/corpus", __DIR__)

# Expected guesses come from upstream chardetng 1.0.0 with the CJK and
# ISO-2022-JP candidates disqualified (`guess(None, Utf8Detection::Allow)`).
# Columns: path relative to fixtures/corpus, prefix length (-1 = whole file), guess.
private EXPECTED = File.read_lines(File.expand_path("fixtures/chardetng_expected.tsv", __DIR__)).map(&.split('\t'))

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

  it "detects visual-order Hebrew (upstream test case)" do
    Fathom::Chardetng.guess(".\xed\xe9\xe5\xe5\xfa \xe3\xe5\xe3\xe9\xf7 \xef\xe7\xe1\xee \xe5\xe4\xe6".to_slice).should eq "ISO-8859-8"
  end

  it "scores Spanish ordinals and rejects truncated UTF-8" do
    Fathom::Chardetng.guess("n.\xBA1 y la 3\xAA ".to_slice).should eq "WINDOWS-1252"
    Fathom::Chardetng.guess("caf\xC3".to_slice).should_not eq "UTF-8"
    Fathom::Chardetng.guess("caf\xC3\xA9".to_slice).should eq "UTF-8"
  end

  it "sizes MAX_SCORES for every candidate plus visual Hebrew" do
    Fathom::Chardetng::Detector::MAX_SCORES.should eq Fathom::Chardetng::Detector::CAPACITY + 1
  end

  it "raises when fed after the last chunk" do
    detector = Fathom::Chardetng::Detector.new
    detector.feed(Bytes.empty, last: true)
    expect_raises(ArgumentError) { detector.feed(Bytes.empty, last: false) }
  end
end
