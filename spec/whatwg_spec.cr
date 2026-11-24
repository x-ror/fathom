require "./spec_helper"
require "../src/fathom/whatwg"

# Expected values are taken from the WHATWG indexes.json the tables were generated from.
private def mapped(size : Int32, & : Int32 -> Int32) : Int32
  (0...size).count { |pointer| yield(pointer) != 0 }
end

describe Fathom::WHATWG do
  it "maps as many pointers as the WHATWG indexes" do
    mapped(11280) { |p| Fathom::WHATWG.jis0208(p) }.should eq 7724
    mapped(8836) { |p| Fathom::WHATWG.jis0212(p) }.should eq 6067
    mapped(63) { |p| Fathom::WHATWG.iso_2022_jp_katakana(p) }.should eq 63
    mapped(23940) { |p| Fathom::WHATWG.euc_kr(p) }.should eq 17048
    mapped(23940) { |p| Fathom::WHATWG.gb18030(p) }.should eq 23940
    mapped(19782) { |p| Fathom::WHATWG.big5(p) }.should eq 18590
  end

  it "returns the indexed code points" do
    {0 => 0x3000, 1410 => 20124, 7807 => 29081, 8272 => 32394}.each { |p, cp| Fathom::WHATWG.jis0208(p).should eq cp }
    {108 => 728, 3570 => 27860, 8835 => 0}.each { |p, cp| Fathom::WHATWG.jis0212(p).should eq cp }
    {0 => 44034, 9026 => 44032, 23939 => 0}.each { |p, cp| Fathom::WHATWG.euc_kr(p).should eq cp }
    {0 => 19970, 6555 => 12288, 23939 => 58565}.each { |p, cp| Fathom::WHATWG.gb18030(p).should eq cp }
    {0 => 12290, 62 => 12444}.each { |p, cp| Fathom::WHATWG.iso_2022_jp_katakana(p).should eq cp }
    {941 => 0, 942 => 17392, 1167 => 7873, 5024 => 12288, 19781 => 31188}.each { |p, cp| Fathom::WHATWG.big5(p).should eq cp }
  end

  it "restores Big5 code points in plane 2" do
    Fathom::WHATWG.big5(947).should eq 160359
    Fathom::WHATWG.big5(950).should eq 162993
  end

  it "returns 0 for pointers outside an index" do
    [-1, 11280].each { |p| Fathom::WHATWG.jis0208(p).should eq 0 }
    [-1, 19782].each { |p| Fathom::WHATWG.big5(p).should eq 0 }
  end

  it "implements the index gb18030 ranges code point algorithm" do
    Fathom::WHATWG.gb18030_ranges(0).should eq 0x80
    Fathom::WHATWG.gb18030_ranges(36).should eq 0xA5
    Fathom::WHATWG.gb18030_ranges(7457).should eq 0xE7C7
    Fathom::WHATWG.gb18030_ranges(39419).should_not eq 0
    Fathom::WHATWG.gb18030_ranges(39420).should eq 0
    Fathom::WHATWG.gb18030_ranges(189000).should eq 0x10000
    Fathom::WHATWG.gb18030_ranges(1237575).should eq 0x10FFFF
    Fathom::WHATWG.gb18030_ranges(1237576).should eq 0
  end
end
