require "./spec_helper"
require "../src/fathom/whatwg/decoders"

# Each row: encoding, input bytes as hex, and encoding_rs's step-by-step trace
# (tools/encoding_rs_oracle, driven one byte per call as chardetng does).
private TRACES = File.read_lines(File.expand_path("fixtures/decoder_traces.tsv", __DIR__)).map(&.split('\t'))

private def step_text(step : Fathom::WHATWG::Step) : String
  units = [] of String
  units << "%04X" % step.u0 if step.written > 0
  units << "%04X" % step.u1 if step.written > 1
  if step.output_full?
    "F"
  elsif step.malformed?
    "M#{step.malformed}/#{step.good}[#{units.join(",")}]"
  else
    "E[#{units.join(",")}]"
  end
end

private def trace(decoder, bytes : Bytes) : String
  steps = bytes.to_a.map { |b| step_text(decoder.feed(b)) }
  steps << step_text(decoder.finish)
  steps.join(" ")
end

private def trace(encoding : String, bytes : Bytes) : String
  case encoding
  when "SHIFT_JIS"   then trace(Fathom::WHATWG::ShiftJisDecoder.new, bytes)
  when "EUC-JP"      then trace(Fathom::WHATWG::EucJpDecoder.new, bytes)
  when "EUC-KR"      then trace(Fathom::WHATWG::EucKrDecoder.new, bytes)
  when "BIG5"        then trace(Fathom::WHATWG::Big5Decoder.new, bytes)
  when "GBK"         then trace(Fathom::WHATWG::Gb18030Decoder.new, bytes)
  when "ISO-2022-JP" then trace(Fathom::WHATWG::Iso2022JpDecoder.new, bytes)
  else                    raise "unknown encoding #{encoding}"
  end
end

private def hex(s : String) : Bytes
  Bytes.new(s.size // 2) { |i| s[2 * i, 2].to_u8(16) }
end

# Decodes complete input, returning the text or nil if any step is malformed.
private def decode(decoder, bytes : Bytes) : String?
  units = [] of UInt16
  (bytes.to_a.map { |b| decoder.feed(b) } << decoder.finish).each do |step|
    return nil if step.malformed?
    units << step.u0 if step.written > 0
    units << step.u1 if step.written > 1
  end
  String.from_utf16(Slice.new(units.to_unsafe, units.size))
end

describe "WHATWG multi-byte decoders" do
  it "match encoding_rs step by step on the fixture" do
    TRACES.size.should be > 10_000
    TRACES.each do |(encoding, input, expected)|
      {encoding, input, trace(encoding, hex(input))}.should eq({encoding, input, expected})
    end
  end

  it "decode CJK text" do
    decode(Fathom::WHATWG::ShiftJisDecoder.new, hex("93FA967B8CEA")).should eq "日本語"
    decode(Fathom::WHATWG::EucJpDecoder.new, hex("C6FCCBDCB8EC")).should eq "日本語"
    decode(Fathom::WHATWG::Iso2022JpDecoder.new, hex("1B2442467C4B5C386C1B2842")).should eq "日本語"
    decode(Fathom::WHATWG::EucKrDecoder.new, hex("C7D1B1B9BEEE")).should eq "한국어"
    decode(Fathom::WHATWG::Big5Decoder.new, hex("A4A4A4E5")).should eq "中文"
    decode(Fathom::WHATWG::Gb18030Decoder.new, hex("D6D0CEC4")).should eq "中文"
    decode(Fathom::WHATWG::Gb18030Decoder.new, hex("9439FC39")).should eq "😃" # four-byte, plane 1
  end

  it "reports truncated and invalid input as malformed" do
    decode(Fathom::WHATWG::ShiftJisDecoder.new, hex("93")).should be_nil
    decode(Fathom::WHATWG::EucKrDecoder.new, hex("C741")).should be_nil
    decode(Fathom::WHATWG::Gb18030Decoder.new, hex("81308130FF")).should be_nil
    decode(Fathom::WHATWG::Iso2022JpDecoder.new, hex("1B244246")).should be_nil # cut inside 日
  end
end
