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

  it "treats NUL-heavy buffers as binary rather than UTF-8" do
    Fathom.detect(Bytes.new(1000, 0)).should be_nil
    Fathom.decode(Bytes.new(1000, 0)).should be_nil
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

  it "detects BOM-less UTF-32LE and UTF-32BE" do
    ["abcd", "Hello, world!", "Привіт — 日本語 😀"].each do |text|
      Fathom.detect(text.encode("UTF-32LE")).should eq "UTF-32LE"
      Fathom.detect(text.encode("UTF-32BE")).should eq "UTF-32BE"
      Fathom.decode(text.encode("UTF-32LE")).should eq text
      Fathom.decode(text.encode("UTF-32BE")).should eq text
    end
    # A cut trailing unit is ignored for detection and dropped by decode.
    Fathom.decode("hello".encode("UTF-32BE")[0, 18]).should eq "hell"
  end

  it "does not read NUL-padded binary or UTF-16 as BOM-less UTF-32" do
    Fathom.detect("abc".encode("UTF-32LE")).should be_nil                                       # fewer than 4 units is not enough evidence
    Fathom.detect("abcd".encode("UTF-32LE") + Bytes[0, 0, 0, 0]).should be_nil                  # U+0000 unit
    Fathom.detect("abcd".encode("UTF-32LE") + Bytes[0, 0xD8, 0, 0]).should_not eq "UTF-32LE"    # surrogate U+D800
    Fathom.detect("abcd".encode("UTF-32LE") + Bytes[0x41, 0, 0x11, 0]).should_not eq "UTF-32LE" # U+110041
    Fathom.detect("Hello, world!".encode("UTF-16LE")).should eq "UTF-16LE"
    Fathom.detect("Hello, world!".encode("UTF-16BE")).should eq "UTF-16BE"
    Fathom.detect("abcd".encode("UTF-32LE") + Bytes[0, 0, 0x05, 0]).should_not eq "UTF-32LE" # U+50000, unassigned plane 5
  end

  it "does not read UTF-16 alternating with tab, LF or CR as BOM-less UTF-32" do
    # Such UTF-16 pairs into units like U+9xxxx/U+Axxxx/U+Dxxxx (unassigned planes).
    ["1\n2\n3\n4\n", "a\tb\tc\td\t", "x\ry\rz\rw\r", "\n1\n2\n3\n4", "\ta\tb\tc\td"].each do |text|
      Fathom.detect(text.encode("UTF-16LE")).should eq "UTF-16LE"
      Fathom.detect(text.encode("UTF-16BE")).should eq "UTF-16BE"
    end
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
    it "detects Russian in {{ enc.id }}" do
      detect(RU, {{ enc }}).should eq {{ enc }}
    end

    it "detects a short Russian phrase in {{ enc.id }}" do
      detect("Привет, мир", {{ enc }}).should eq {{ enc }}
    end
  {% end %}

  {% for enc in %w[WINDOWS-1251 KOI8-U ISO-8859-5] %}
    it "detects Ukrainian in {{ enc.id }}" do
      # ISO-8859-5 has no "ґ".
      detect(UK.delete('ґ'), {{ enc }}).should eq {{ enc }}
    end
  {% end %}

  it "detects Western European text as WINDOWS-1252" do
    detect(FR, "WINDOWS-1252").should eq "WINDOWS-1252"
    detect(DE, "WINDOWS-1252").should eq "WINDOWS-1252"
    detect(EN, "WINDOWS-1252").should eq "WINDOWS-1252"
  end

  describe ".match" do
    it "returns structured Match metadata with BOM flag and confidence" do
      bom_match = Fathom.match(Bytes[0xEF, 0xBB, 0xBF, 0x41]).should_not be_nil
      bom_match.encoding.should eq "UTF-8"
      bom_match.confidence.should eq 1.0
      bom_match.bom?.should be_true

      win_match = Fathom.match(RU.encode("WINDOWS-1251")).should_not be_nil
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
    it "returns candidates sorted by descending confidence without duplicate encodings" do
      matches = Fathom.detect_all(RU.encode("WINDOWS-1251"))
      matches.should_not be_empty
      matches.first.encoding.should eq "WINDOWS-1251"
      matches.map(&.encoding).uniq!.size.should eq matches.size
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
      m = Fathom.match(io).should_not be_nil
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
      m = detector.match("café".encode("WINDOWS-1252")).should_not be_nil
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
      Fathom::Encoding.canonical_name("ISO-8859-8").should eq "ISO-8859-8"
      Fathom::Encoding.canonical_name("ISO-8859-9").should eq "WINDOWS-1254"
      Fathom::Encoding.canonical_name("ISO-8859-13").should eq "ISO-8859-13"
      Fathom::Encoding.canonical_name("latin7").should eq "ISO-8859-13"
      Fathom::Encoding.canonical_name("TIS-620").should eq "WINDOWS-874"
      Fathom::Encoding.canonical_name("iso-8859-11").should eq "WINDOWS-874"
      Fathom::Encoding.canonical_name("cp1251").should eq "WINDOWS-1251"
      Fathom::Encoding.canonical_name("cp866").should eq "IBM866"
      Fathom::Encoding.canonical_name("cp1250").should eq "WINDOWS-1250"
      Fathom::Encoding.canonical_name("latin2").should eq "ISO-8859-2"
      Fathom::Encoding.canonical_name("latin5").should eq "WINDOWS-1254"
      Fathom::Encoding.canonical_name("cp1255").should eq "WINDOWS-1255"
      Fathom::Encoding.canonical_name("arabic").should eq "ISO-8859-6"
      Fathom::Encoding.canonical_name("greek").should eq "ISO-8859-7"
      Fathom::Encoding.canonical_name("cp874").should eq "WINDOWS-874"
      Fathom::Encoding.canonical_name("cp437").should eq "IBM437"
      Fathom::Encoding.canonical_name("cp850").should eq "IBM850"
      Fathom::Encoding.canonical_name("cp852").should eq "IBM852"
      Fathom::Encoding.canonical_name("macroman").should eq "MACINTOSH"
      Fathom::Encoding.canonical_name("cp10007").should eq "X-MAC-CYRILLIC"
    end

    it "provides iconv-compatible names via Match#iconv_name" do
      Fathom::Match.new("WINDOWS-1251", 0.9).iconv_name.should eq "WINDOWS-1251"
      Fathom::Match.new("iso-8859-1", 0.9).iconv_name.should eq "WINDOWS-1252"
      Fathom::Match.new("IBM437", 0.9).iconv_name.should eq "CP437"
      Fathom::Match.new("IBM850", 0.9).iconv_name.should eq "CP850"
      Fathom::Match.new("IBM852", 0.9).iconv_name.should eq "CP852"
      Fathom::Match.new("IBM866", 0.9).iconv_name.should eq "CP866"
      expected_mac = {% if flag?(:win32) %} "MACROMAN" {% else %} "MACINTOSH" {% end %}
      Fathom::Match.new("MACINTOSH", 0.9).iconv_name.should eq expected_mac
      Fathom::Match.new("X-MAC-CYRILLIC", 0.9).iconv_name.should eq "MACCYRILLIC"
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

    it "drops an incomplete trailing character that detection accepts" do
      Fathom.decode("Привет".to_slice[0, 11]).should eq "Приве"
      Fathom.decode("hello world".encode("UTF-16LE") + Bytes[0x41]).should eq "hello world"
      Fathom.decode(Bytes[0xFF, 0xFE, 0x41]).should eq ""
      Fathom.decode("hello world 😀".encode("UTF-16BE")[0, 26]).should eq "hello world "
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

  describe "bigram disambiguation" do
    it "separates short Ukrainian without unique letters in KOI8-U from Russian KOI8-R" do
      uk_no_unique = "Тарас Григорович Шевченко (25 лютого (9 березня) 1814, село Моринці)"
      detect(uk_no_unique, "KOI8-U").should eq "KOI8-U"

      ru_short = "Александр Сергеевич Пушкин (26 мая (6 июня) 1799, Москва)"
      detect(ru_short, "KOI8-R").should eq "KOI8-R"
    end
  end

  describe "short Russian words" do
    it "labels short KOI8 text without Ukrainian-only letters as KOI8-R" do
      ["да", "хорошо", "мама", "Город", "Цена: 100 руб.", "Дата: 01.02.2024"].each do |text|
        detect(text, "KOI8-R").should eq "KOI8-R"
      end
    end

    it "does not read IBM866 as WINDOWS-1251 letters separated by symbols" do
      ["хорошо", "работа", "пароль", "папа", "Дата", "Всё хорошо"].each do |text|
        detect(text, "IBM866").should eq "IBM866"
      end
    end
  end

  describe "mixed ASCII and Cyrillic" do
    it "does not read Cyrillic words inside English text as WINDOWS-1252" do
      log = "2024-05-01 12:00:01 ERROR [main] Failed to open file: Файл не найден\n"
      %w[WINDOWS-1251 KOI8-R ISO-8859-5 IBM866].each do |enc|
        detect(log, enc).should_not eq "WINDOWS-1252"
      end
      detect(log, "WINDOWS-1251").should eq "WINDOWS-1251"
      detect(log, "IBM866").should eq "IBM866"
    end
  end

  describe "CJK and ISO-2022-JP" do
    # Encoded ahead of time so the specs don't depend on the platform's iconv encoders.
    sjis = "82B182EA82CD93FA967B8CEA82CC8365834C8358836782C582B78142".hexbytes # これは日本語のテキストです。
    iso = "1B2442467C4B5C386C244E2546252D253925481B2842".hexbytes              # 日本語のテキスト

    it "detects each CJK encoding with its language" do
      {
        {"SHIFT_JIS", "ja", sjis},
        {"EUC-JP", "ja", "A4B3A4ECA4CFC6FCCBDCB8ECA4CEA5C6A5ADA5B9A5C8A4C7A4B9A1A3".hexbytes},
        {"EUC-KR", "ko", "C0CCB0CDC0BA20C7D1B1B9BEEE20B9AEC0E5C0D4B4CFB4D92E".hexbytes},
        {"GBK", "zh", "D5E2CAC7D2BBB8F6D6D0CEC4BEE4D7D3A1A3".hexbytes},
        {"BIG5", "zh", "B36FAC4FA440ADD3A4A4A4E5A579A46CA143".hexbytes},
      }.each do |encoding, language, bytes|
        match = Fathom.match(bytes).should_not be_nil
        {encoding, match.encoding, match.language}.should eq({encoding, encoding, language})
      end
    end

    it "detects 7-bit ISO-2022-JP before treating input as ASCII" do
      match = Fathom.match(iso).should_not be_nil
      match.encoding.should eq "ISO-2022-JP"
      match.language.should eq "ja"
      Fathom.decode(iso).should eq "日本語のテキスト"
    end

    it "keeps ASCII with other escapes as UTF-8" do
      Fathom.detect("\e[31mred\e[0m".to_slice).should eq "UTF-8"
      Fathom.detect("abc\e".to_slice).should eq "UTF-8"
    end

    it "accepts a CJK character cut at the end and drops it when decoding" do
      Fathom.detect(sjis[0, sjis.size - 1]).should eq "SHIFT_JIS"
      Fathom.decode(sjis[0, sjis.size - 1]).should eq "これは日本語のテキストです"
      Fathom.detect(iso[0, iso.size - 4]).should eq "ISO-2022-JP"
      Fathom.decode(iso[0, iso.size - 4]).should eq "日本語のテキス"
    end

    it "maps WHATWG labels and iconv names" do
      Fathom::Encoding.canonical_name("windows-31j").should eq "SHIFT_JIS"
      Fathom::Encoding.canonical_name("ks_c_5601-1987").should eq "EUC-KR"
      Fathom::Encoding.canonical_name("gb2312").should eq "GBK"
      Fathom::Encoding.canonical_name("gb18030").should eq "GBK"
      Fathom::Encoding.canonical_name("big5-hkscs").should eq "BIG5"
      Fathom::Encoding.iconv_name("SHIFT_JIS").should eq "CP932"
      Fathom::Encoding.iconv_name("GBK").should eq "GB18030"
    end
  end

  describe "edge cases" do
    it "detects WINDOWS-1252 when the only high bytes are symbols" do
      match = Fathom.match("100 €".encode("WINDOWS-1252")).should_not be_nil
      match.encoding.should eq "WINDOWS-1252"
      # Neutral evidence (punctuation only) counts as a tie, not as a confident guess.
      match.confidence.should eq Fathom::Chardetng::Prober::TIE_CONFIDENCE
    end

    it "accepts UTF-8 whose first multi-byte character is cut by the sample boundary" do
      text = ("a" * 65_535) + "é and more text é"
      Fathom.detect(text.to_slice).should eq "UTF-8"
    end
  end

  describe "tolerant UTF-8" do
    it "detects slightly corrupted UTF-8 with lowered confidence" do
      corrupt = RU.to_slice + Bytes[0xFF, 0x80]
      m = Fathom.match(corrupt).should_not be_nil
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
      m = Fathom.match(valid_multibyte_dominant).should_not be_nil
      m.encoding.should eq "UTF-8"
      m.confidence.should be < 1.0
    end
  end

  describe "expanded single-byte encodings and language metadata" do
    it "detects all 15 newly added single-byte encodings from fixtures" do
      {
        {"WINDOWS-1250", "pl_1.txt", "pl"},
        {"ISO-8859-2", "cs_1.txt", "cs"},
        {"IBM852", "hu_1.txt", "hu"},
        {"WINDOWS-1257", "lv_1.txt", "lv"},
        {"WINDOWS-1253", "el_1.txt", "el"},
        {"ISO-8859-7", "el_1.txt", "el"},
        {"WINDOWS-1254", "tr_1.txt", "tr"},
        {"WINDOWS-1255", "he_1.txt", "he"},
        {"WINDOWS-1256", "ar_1.txt", "ar"},
        {"ISO-8859-6", "ar_1.txt", "ar"},
        {"WINDOWS-874", "th_1.txt", "th"},
        {"IBM437", "dos_1.txt", nil},
        {"IBM850", "fr_1.txt", nil},
        {"MACINTOSH", "de_1.txt", nil},
        {"X-MAC-CYRILLIC", "uk_1.txt", "uk"},
      }.each do |encoding, file, expected_lang|
        bytes = File.read(File.join(__DIR__, "fixtures", "corpus", encoding, file)).to_slice
        match = Fathom.match(bytes).should_not be_nil
        match.encoding.should eq encoding
        match.language.should eq expected_lang
      end
    end

    it "reports ISO 639-1 language codes for single-language models and nil for shared encodings" do
      {
        {"WINDOWS-1251", "ru_1.txt", "ru"},
        {"WINDOWS-1251", "uk_1.txt", "uk"},
        {"WINDOWS-1251", "be_1.txt", "be"},
        {"WINDOWS-1250", "pl_1.txt", "pl"},
        {"WINDOWS-1250", "cs_1.txt", "cs"},
        {"WINDOWS-1250", "hu_1.txt", "hu"},
        {"WINDOWS-1257", "lt_1.txt", "lt"},
        {"WINDOWS-1257", "lv_1.txt", "lv"},
        {"WINDOWS-1253", "el_1.txt", "el"},
        {"WINDOWS-1254", "tr_1.txt", "tr"},
        {"WINDOWS-1255", "he_1.txt", "he"},
        {"WINDOWS-1256", "ar_1.txt", "ar"},
        {"WINDOWS-874", "th_1.txt", "th"},
        {"UTF-8", "ru_1.txt", nil},
        {"UTF-16LE", "en_1_nobom.txt", nil},
        {"WINDOWS-1252", "fr_1.txt", nil},
      }.each do |encoding, file, expected_lang|
        bytes = File.read(File.join(__DIR__, "fixtures", "corpus", encoding, file)).to_slice
        match = Fathom.match(bytes).should_not be_nil
        match.language.should eq expected_lang
      end
    end

    it "detects all-uppercase European inputs without dropping to MACINTOSH or nil" do
      detect("GRÜSSE AUS MÜNCHEN", "WINDOWS-1252").should eq "WINDOWS-1252"
      detect("ZAŻÓŁĆ GĘŚLĄ JAŹŃ", "WINDOWS-1250").should eq "WINDOWS-1250"
    end

    it "detects Latvian pangrams as WINDOWS-1257 (lv) rather than Cyrillic" do
      [
        "Glāžšķūņa rūķīši dzērumā čiepj Baha concertflīģeļu vākus.",
        "Muļķa hipiji mēģina brīvi nogaršot celofāna žņaudzējčūsku.",
      ].each do |pangram|
        match = Fathom.match(pangram.encode("WINDOWS-1257")).should_not be_nil
        match.encoding.should eq "WINDOWS-1257"
        match.language.should eq "lv"
      end
    end

    it "preserves strong confidence on Western text with smart quotes or symbols" do
      smart = Fathom.match(EN.encode("WINDOWS-1252")).should_not be_nil
      smart.encoding.should eq "WINDOWS-1252"
      smart.confidence.should be >= 0.55

      copyright = Fathom.match("Copyright © 2024 Acme Corp. All rights reserved.".encode("WINDOWS-1252")).should_not be_nil
      copyright.encoding.should eq "WINDOWS-1252"
      copyright.confidence.should be >= 0.55
    end

    it "detects visual-order Hebrew as WINDOWS-1255 with Hebrew language metadata" do
      match = Fathom.match(".\xed\xe9\xe5\xe5\xfa \xe3\xe5\xe3\xe9\xf7 \xef\xe7\xe1\xee \xe5\xe4\xe6".to_slice).should_not be_nil
      match.encoding.should eq "WINDOWS-1255"
      match.language.should eq "he"
    end

    it "does not fold visual Hebrew into WINDOWS-1255 when windows-1255 can't decode it" do
      # 0xDF is "‗" in ISO-8859-8 but undefined in windows-1255.
      bytes = ".\xed\xe9\xe5\xe5\xfa \xe3\xe5\xe3\xe9\xf7 \xef\xe7\xe1\xee \xe5\xe4\xe6 \xdf\xdf".to_slice
      Fathom.detect(bytes).should_not eq "WINDOWS-1255"
      Fathom.decode(bytes) # must not raise
    end

    it "detects and decodes ISO-8859-13 with Baltic quotation marks" do
      text = "„Glāžšķūņa rūķīši dzērumā čiepj Baha concertflīģeļu vākus.”"
      bytes = text.encode("ISO-8859-13")
      match = Fathom.match(bytes).should_not be_nil
      match.encoding.should eq "ISO-8859-13"
      match.language.should eq "lv"
      Fathom.decode(bytes).should eq text
    end
  end
end
