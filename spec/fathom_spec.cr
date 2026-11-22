require "./spec_helper"

RU = "Съешь же ещё этих мягких французских булок, да выпей чаю. Широкая электрификация южных губерний даст мощный толчок подъёму сельского хозяйства."
UK = "Жебракують філософи при ґанку церкви в Гадячі, ще й шатро їхнє п'яне знаємо. Щастям б'єш жука їх глицю в фон й ґедзь пріч."
FR = "Voilà l'été : les élèves ont déjà oublié leçons et problèmes, près de la forêt où coule un ruisseau glacé."
DE = "Zwölf Boxkämpfer jagen Viktor quer über den großen Sylter Deich, während die Mädchen fröhlich grüßen."
EN = "It’s a “quoted” sentence — with curly punctuation only."

private def detect(text, encoding)
  Fathom.detect(text.encode(Fathom::Encoding.iconv_name(encoding)))
end

private struct MockAsciiXorProber
  include Fathom::Prober

  def probe(bytes : Bytes, stats : Fathom::ByteStats) : Fathom::Match?
    return nil if stats.high_bytes == 0
    Fathom::Match.new("X-CUSTOM-8BIT", 0.99)
  end
end

describe Fathom do
  it "trusts a BOM" do
    Fathom.detect(Bytes[0xEF, 0xBB, 0xBF, 0x41]).should eq "UTF-8"
    Fathom.detect(Bytes[0xFF, 0xFE, 0x41, 0x00]).should eq "UTF-16LE"
    Fathom.detect(Bytes[0xFE, 0xFF, 0x00, 0x41]).should eq "UTF-16BE"
    Fathom.detect(Bytes[0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00]).should eq "UTF-32LE"
    Fathom.detect(Bytes[0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x41]).should eq "UTF-32BE"
  end

  it "detects UTF-8, ASCII and empty input" do
    Fathom.detect(RU.to_slice).should eq "UTF-8"
    Fathom.detect("plain ascii".to_slice).should eq "UTF-8"
    Fathom.detect(Bytes[0x41]).should eq "UTF-8"
    Fathom.detect(Bytes.empty).should eq "UTF-8"
  end

  it "detects NUL-terminated UTF-8 strings as UTF-8" do
    Fathom.detect("hello\0".to_slice).should eq "UTF-8"
    Fathom.detect("Привет мир\0".to_slice).should eq "UTF-8"
    Fathom.detect("hello\0world\0".to_slice).should eq "UTF-8"
  end

  it "handles 1-byte and 2-byte non-UTF-8 inputs safely" do
    Fathom.detect(Bytes[0x00, 0xFF]).should be_nil
    Fathom.detect(Bytes[0xFF]).should_not be_nil
    Fathom.detect(Bytes[0xFF]).should_not eq "UTF-8"
  end

  it "accepts UTF-8 cut in the middle of a character" do
    # Every character here is two bytes, so one of these cuts lands mid-character.
    Fathom.detect("Привет".to_slice[0, 4]).should eq "UTF-8"
    Fathom.detect("Привет".to_slice[0, 5]).should eq "UTF-8"
  end

  it "does not misdetect single trailing Latin-1/Windows-1252 high byte as truncated UTF-8" do
    detect("café", "WINDOWS-1252").should eq "WINDOWS-1252"
  end

  it "rejects invalid trailing bytes after ASCII as UTF-8" do
    Fathom.detect(Bytes[0x61, 0x62, 0x63, 0xC0]).should_not eq "UTF-8"
    Fathom.detect(Bytes[0x61, 0x62, 0x63, 0xFF]).should_not eq "UTF-8"
  end

  it "detects BOM-less UTF-16LE and UTF-16BE" do
    Fathom.detect("Hello, world! Testing UTF-16 without BOM.".encode("UTF-16LE")).should eq "UTF-16LE"
    Fathom.detect("Hello, world! Testing UTF-16 without BOM.".encode("UTF-16BE")).should eq "UTF-16BE"
    Fathom.detect("Привіт — hello world in UTF-16LE!".encode("UTF-16LE")).should eq "UTF-16LE"
    Fathom.detect("Привіт — hello world in UTF-16BE!".encode("UTF-16BE")).should eq "UTF-16BE"
  end

  it "returns nil for binary data" do
    Fathom.detect(Bytes[0x00, 0x9F, 0x92, 0x00, 0xFF, 0x10]).should be_nil
    Fathom.detect(Bytes[0x01, 0x02, 0x03, 0x04, 0x7F, 0x10, 0x41, 0x42]).should be_nil
  end

  {% for enc in %w[WINDOWS-1251 KOI8-R ISO-8859-5 IBM866] %}
    it "detects Russian in {{enc.id}}" do
      detect(RU, {{enc}}).should eq {{enc}}
    end

    it "detects a short Russian phrase in {{enc.id}}" do
      detect("Привет, мир", {{enc}}).should eq {{enc}}
    end
  {% end %}

  {% for enc in %w[WINDOWS-1251 KOI8-U ISO-8859-5] %}
    it "detects Ukrainian in {{enc.id}}" do
      # ISO-8859-5 has no "ґ".
      detect(UK.delete('ґ'), {{enc}}).should eq {{enc}}
    end
  {% end %}

  it "detects Western European text as WINDOWS-1252" do
    detect(FR, "WINDOWS-1252").should eq "WINDOWS-1252"
    detect(DE, "WINDOWS-1252").should eq "WINDOWS-1252"
    detect(EN, "WINDOWS-1252").should eq "WINDOWS-1252"
  end

  describe ".match" do
    it "returns structured Match metadata with BOM flag and confidence" do
      bom_match = Fathom.match(Bytes[0xEF, 0xBB, 0xBF, 0x41]).not_nil!
      bom_match.encoding.should eq "UTF-8"
      bom_match.confidence.should eq 1.0
      bom_match.bom?.should be_true

      win_match = Fathom.match(RU.encode("WINDOWS-1251")).not_nil!
      win_match.encoding.should eq "WINDOWS-1251"
      win_match.confidence.should be > 0.5
      win_match.confidence.should be <= 1.0
      win_match.bom?.should be_false
    end

    it "compares Match instances by value equality across all fields" do
      a = Fathom::Match.new("KOI8-R", 0.5)
      b = Fathom::Match.new("WINDOWS-1251", 0.5)
      c = Fathom::Match.new("KOI8-R", 0.5)
      d = Fathom::Match.new("UTF-8", 1.0, bom: true)
      e = Fathom::Match.new("UTF-8", 1.0, bom: false)

      a.should_not eq b
      a.should eq c
      d.should_not eq e
    end
  end

  describe ".detect_all" do
    it "returns candidates sorted by descending confidence" do
      matches = Fathom.detect_all(RU.encode("WINDOWS-1251"))
      matches.should_not be_empty
      matches.first.encoding.should eq "WINDOWS-1251"
      matches.each_cons(2) do |(a, b)|
        a.confidence.should be >= b.confidence
      end
    end
  end

  describe "IO streaming" do
    it "detects and matches directly from an IO" do
      payload = UK.encode("KOI8-U")
      io = IO::Memory.new(payload)
      Fathom.detect(io).should eq "KOI8-U"

      io.rewind
      m = Fathom.match(io).not_nil!
      m.encoding.should eq "KOI8-U"
      m.bom?.should be_false
    end

    it "reads at most sample_size bytes from an IO" do
      payload = ("Привет, мир! " * 200).encode("WINDOWS-1251")
      io = IO::Memory.new(payload)
      detector = Fathom::Detector.new(sample_size: 128)
      detector.detect(io).should eq "WINDOWS-1251"
      io.pos.should eq 128
    end

    it "handles IOs larger than the stack buffer" do
      payload = ("Привет, мир! " * 500).encode("WINDOWS-1251")
      io = IO::Memory.new(payload)
      Fathom.detect(io).should eq "WINDOWS-1251"
      io.pos.should eq payload.size
    end
  end

  describe Fathom::Detector do
    it "validates sample_size" do
      expect_raises(ArgumentError) do
        Fathom::Detector.new(sample_size: 0)
      end
    end

    it "validates min_confidence" do
      expect_raises(ArgumentError) do
        Fathom::Detector.new(min_confidence: -0.1)
      end

      expect_raises(ArgumentError) do
        Fathom::Detector.new(min_confidence: 1.1)
      end
    end

    it "supports custom probers" do
      detector = Fathom::Detector.new(probers: [MockAsciiXorProber.new] of Fathom::Prober)
      m = detector.match("café".encode("WINDOWS-1252")).not_nil!
      m.encoding.should eq "X-CUSTOM-8BIT"
      m.confidence.should eq 0.99
    end
  end

  describe Fathom::Encoding do
    it "resolves WHATWG aliases and collapses ISO/Windows 0x80..0x9F pairs" do
      Fathom::Encoding.canonical_name("utf-8").should eq "UTF-8"
      Fathom::Encoding.canonical_name("us-ascii").should eq "WINDOWS-1252"
      Fathom::Encoding.canonical_name("ascii").should eq "WINDOWS-1252"
      Fathom::Encoding.canonical_name("iso-8859-1").should eq "WINDOWS-1252"
      Fathom::Encoding.canonical_name("latin1").should eq "WINDOWS-1252"
      Fathom::Encoding.canonical_name("ISO-8859-9").should eq "WINDOWS-1254"
      Fathom::Encoding.canonical_name("ISO-8859-13").should eq "WINDOWS-1257"
      Fathom::Encoding.canonical_name("TIS-620").should eq "WINDOWS-874"
      Fathom::Encoding.canonical_name("iso-8859-11").should eq "WINDOWS-874"
      Fathom::Encoding.canonical_name("cp1251").should eq "WINDOWS-1251"
      Fathom::Encoding.canonical_name("cp866").should eq "IBM866"
    end

    it "provides iconv-compatible names via Match#iconv_name" do
      Fathom::Match.new("WINDOWS-1251", 0.9).iconv_name.should eq "WINDOWS-1251"
      Fathom::Match.new("iso-8859-1", 0.9).iconv_name.should eq "WINDOWS-1252"
      Fathom::Match.new("IBM866", 0.9).iconv_name.should eq "CP866"
    end
  end

  describe ".decode" do
    it "detects and decodes UTF-8, single-byte, and BOM-less UTF-16 payloads" do
      Fathom.decode(RU.to_slice).should eq RU
      Fathom.decode(RU.encode("WINDOWS-1251")).should eq RU
      Fathom.decode(RU.encode("KOI8-R")).should eq RU
      Fathom.decode(FR.encode("WINDOWS-1252")).should eq FR

      ascii_utf16 = "Hello, world! Testing UTF-16 without BOM."
      Fathom.decode(ascii_utf16.encode("UTF-16LE")).should eq ascii_utf16
      Fathom.decode(ascii_utf16.encode("UTF-16BE")).should eq ascii_utf16
    end

    it "strips leading BOM bytes when decoding" do
      {
        {"UTF-8", Bytes[0xEF, 0xBB, 0xBF]},
        {"UTF-16LE", Bytes[0xFF, 0xFE]},
        {"UTF-16BE", Bytes[0xFE, 0xFF]},
        {"UTF-32LE", Bytes[0xFF, 0xFE, 0x00, 0x00]},
        {"UTF-32BE", Bytes[0x00, 0x00, 0xFE, 0xFF]},
      }.each do |enc, bom|
        encoded = RU.encode(enc)
        payload = Bytes.new(bom.size + encoded.size)
        bom.copy_to(payload)
        encoded.copy_to(payload + bom.size)

        Fathom.decode(payload).should eq RU
      end
    end

    it "returns nil for binary payloads and supports IO decoding" do
      Fathom.decode(Bytes[0x00, 0x9F, 0x92, 0x00, 0xFF, 0x10]).should be_nil

      io = IO::Memory.new(UK.encode("KOI8-U"))
      Fathom.decode(io).should eq UK
    end

    it "passes invalid option through to String.new unchanged" do
      corrupt = RU.to_slice + Bytes[0xFF]
      Fathom.detect(corrupt).should eq "UTF-8"

      expect_raises(ArgumentError) do
        Fathom.decode(corrupt)
      end

      Fathom.decode(corrupt, invalid: :skip).should eq RU
    end
  end

  describe "Latin text with isolated accents" do
    it "does not read Italian WINDOWS-1252 as WINDOWS-1251" do
      # Word-final "è"/"à" (0xE8/0xE0) are frequent Cyrillic letters in WINDOWS-1251.
      it_text = "La fotosintesi è un processo per mezzo del quale la città e la società producono più energia."
      Fathom.detect(it_text.encode("WINDOWS-1252")).should eq "WINDOWS-1252"
    end
  end

  describe "tolerant UTF-8" do
    it "detects slightly corrupted UTF-8 with lowered confidence" do
      corrupt = RU.to_slice + Bytes[0xFF, 0x80]
      m = Fathom.match(corrupt).not_nil!
      m.encoding.should eq "UTF-8"
      m.confidence.should be < 1.0
      m.confidence.should be >= 0.75
    end

    it "uses multi-byte sequence ratio rather than ASCII+byte ratio" do
      # Lots of ASCII, only 2 valid multi-byte chars, and 3 invalid bytes -> must NOT match UTF-8.
      mostly_ascii = ("plain ascii log line\n" * 40).to_slice + "éè".to_slice + Bytes[0xFF, 0xFE, 0x80]
      Fathom.detect(mostly_ascii).should_not eq "UTF-8"

      # Lots of ASCII, 10 valid multi-byte chars, and 1 invalid byte -> matches tolerant UTF-8.
      valid_multibyte_dominant = ("plain ascii log line\n" * 40).to_slice + "éèàçùêîôûä".to_slice + Bytes[0xFF]
      m = Fathom.match(valid_multibyte_dominant).not_nil!
      m.encoding.should eq "UTF-8"
      m.confidence.should be < 1.0
    end
  end
end
