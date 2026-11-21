require "./spec_helper"

RU = "Съешь же ещё этих мягких французских булок, да выпей чаю. Широкая электрификация южных губерний даст мощный толчок подъёму сельского хозяйства."
UK = "Жебракують філософи при ґанку церкви в Гадячі, ще й шатро їхнє п'яне знаємо. Щастям б'єш жука їх глицю в фон й ґедзь пріч."
FR = "Voilà l'été : les élèves ont déjà oublié leçons et problèmes, près de la forêt où coule un ruisseau glacé."
DE = "Zwölf Boxkämpfer jagen Viktor quer über den großen Sylter Deich, während die Mädchen fröhlich grüßen."
EN = "It’s a “quoted” sentence — with curly punctuation only."

private def detect(text, encoding)
  Fathom.detect(text.encode(encoding))
end

describe Fathom do
  it "trusts a BOM" do
    Fathom.detect(Bytes[0xEF, 0xBB, 0xBF, 0x41]).should eq "UTF-8"
    Fathom.detect(Bytes[0xFF, 0xFE, 0x41, 0x00]).should eq "UTF-16LE"
    Fathom.detect(Bytes[0xFE, 0xFF, 0x00, 0x41]).should eq "UTF-16BE"
    Fathom.detect(Bytes[0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00]).should eq "UTF-32LE"
  end

  it "detects UTF-8, ASCII and empty input" do
    Fathom.detect(RU.to_slice).should eq "UTF-8"
    Fathom.detect("plain ascii".to_slice).should eq "UTF-8"
    Fathom.detect(Bytes.empty).should eq "UTF-8"
  end

  it "accepts UTF-8 cut in the middle of a character" do
    # Every character here is two bytes, so one of these cuts lands mid-character.
    Fathom.detect("Привет".to_slice[0, 4]).should eq "UTF-8"
    Fathom.detect("Привет".to_slice[0, 5]).should eq "UTF-8"
  end

  it "returns nil for binary data" do
    Fathom.detect(Bytes[0x00, 0x9F, 0x92, 0x00, 0xFF, 0x10]).should be_nil
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
end
