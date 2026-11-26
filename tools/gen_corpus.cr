# Builds the accuracy corpus from real Wikipedia text.
#
#   crystal run tools/gen_corpus.cr -- --fetch   # download sources into corpus/UTF-8, then encode
#   crystal run tools/gen_corpus.cr              # re-encode from the committed corpus/UTF-8 sources
#
# The UTF-8 files are the source of truth: fetched articles change over time, so
# the committed copy (not a re-fetch) is what makes results reproducible.
# Text is licensed CC BY-SA 4.0; sources are listed in corpus/SOURCES.md.
require "http/client"
require "json"
require "uri"
require "../src/fathom/encoding"

CORPUS  = File.expand_path("../corpus", __DIR__)
FIXTURE = File.expand_path("../spec/fixtures/corpus", __DIR__)
MAX_LEN = 4096

# lang => article titles. The first article of each language also goes into the CI gate fixture.
ARTICLES = {
  "ru"      => ["Волга", "Фотосинтез", "Пушкин, Александр Сергеевич"],
  "uk"      => ["Шевченко Тарас Григорович", "Фотосинтез", "Карпати"],
  "be"      => ["Мінск", "Янка Купала", "Нёман"],
  "de"      => ["Rhein", "Photosynthese", "Johann Wolfgang von Goethe"],
  "fr"      => ["Loire (fleuve)", "Photosynthèse", "Victor Hugo"],
  "es"      => ["Ebro", "Fotosíntesis", "Miguel de Cervantes"],
  "it"      => ["Po", "Fotosintesi clorofilliana", "Dante Alighieri"],
  "pt"      => ["Rio Tejo", "Fotossíntese", "Luís de Camões"],
  "en"      => ["Zürich", "Crème brûlée", "Pelé"],
  "pl"      => ["Wisła", "Fotosynteza", "Adam Mickiewicz"],
  "cs"      => ["Vltava", "Fotosyntéza", "Karel Čapek"],
  "hu"      => ["Duna", "Fotoszintézis", "Petőfi Sándor"],
  "lt"      => ["Nemunas", "Fotosintezė", "Maironis"],
  "lv"      => ["Daugava", "Fotosintēze", "Rainis"],
  "el"      => ["Άρης (πλανήτης)", "Φωτοσύνθεση", "Άρτα"],
  "tr"      => ["Fırat", "Fotosentez", "Orhan Pamuk"],
  "he"      => ["ירדן", "פוטוסינתזה", "דוד בן-גוריון"],
  "ar"      => ["النيل", "تمثيل ضوئي", "نجيب محفوظ"],
  "th"      => ["แม่น้ำเจ้าพระยา", "การสังเคราะห์ด้วยแสง", "สุนทรภู่"],
  "ja"      => ["信濃川", "光合成", "夏目漱石"],
  "ko"      => ["한강", "광합성", "이순신"],
  "zh-hans" => ["长江", "光合作用", "鲁迅"],
  "zh-hant" => ["淡水河", "光合作用", "梁實秋"],
}

# Chinese script variants are served by zh.wikipedia.org with a `variant` conversion.
VARIANTS = {"zh-hans" => "zh-cn", "zh-hant" => "zh-tw"}

def host(lang : String) : String
  "#{lang.split('-').first}.wikipedia.org"
end

# encoding => languages encoded into it.
TARGETS = {
  "WINDOWS-1251"   => %w[ru uk be],
  "KOI8-R"         => %w[ru],
  "KOI8-U"         => %w[uk],
  "ISO-8859-5"     => %w[ru uk],
  "IBM866"         => %w[ru],
  "X-MAC-CYRILLIC" => %w[ru uk],
  "WINDOWS-1252"   => %w[de fr es it pt en],
  "IBM850"         => %w[fr pt es],
  "MACINTOSH"      => %w[de fr es it pt],
  "WINDOWS-1250"   => %w[pl cs hu],
  "ISO-8859-2"     => %w[pl cs],
  "IBM852"         => %w[pl cs hu],
  "WINDOWS-1257"   => %w[lt lv],
  "ISO-8859-13"    => %w[lt lv],
  "WINDOWS-1253"   => %w[el],
  "ISO-8859-7"     => %w[el],
  "WINDOWS-1254"   => %w[tr],
  "WINDOWS-1255"   => %w[he],
  "WINDOWS-1256"   => %w[ar],
  "ISO-8859-6"     => %w[ar],
  "WINDOWS-874"    => %w[th],
  "SHIFT_JIS"      => %w[ja],
  "EUC-JP"         => %w[ja],
  "ISO-2022-JP"    => %w[ja],
  "EUC-KR"         => %w[ko],
  "GBK"            => %w[zh-hans],
  "BIG5"           => %w[zh-hant],
}

# ASCII stand-ins for punctuation that legacy Cyrillic code pages cannot encode.
FALLBACK = {'«' => "\"", '»' => "\"", '„' => "\"", '“' => "\"", '”' => "\"",
            '‘' => "'", '’' => "'", '—' => "-", '–' => "-", '…' => "...", ' ' => " "}

def fetch(lang : String, title : String) : String
  params = {"action" => "query", "prop" => "extracts", "explaintext" => "1",
            "redirects" => "1", "format" => "json", "formatversion" => "2", "titles" => title}
  VARIANTS[lang]?.try { |variant| params["variant"] = variant }
  query = URI::Params.encode(params)
  res = nil
  wait = 2
  6.times do
    sleep wait.seconds # Wikipedia rate-limits bursts with HTTP 429
    res = HTTP::Client.get("https://#{host(lang)}/w/api.php?#{query}",
      headers: HTTP::Headers{"User-Agent" => "fathom-corpus/0.1"})
    break unless res.status_code == 429
    wait = res.headers["Retry-After"]?.try(&.to_i?) || wait * 2
  end
  res = res || raise "#{lang}:#{title}: no response"
  raise "#{lang}:#{title}: HTTP #{res.status_code}" unless res.success?
  extract = JSON.parse(res.body)["query"]["pages"][0]["extract"]?.try(&.as_s)
  raise "#{lang}:#{title}: no extract" unless extract

  # Keep running prose only: infobox remnants and headings are short or contain markup.
  text = ""
  extract.each_line do |line|
    line = line.strip
    next if line.size < 200 || line.includes?('|') || line.includes?('=')
    break if text.bytesize + line.bytesize > MAX_LEN
    text += line + "\n"
  end
  raise "#{lang}:#{title}: no prose paragraphs" if text.empty?
  text
end

# Encoders to use where the decoding iconv name can't encode (macOS iconv decodes
# BIG5-HKSCS but refuses to encode plain text with it; Big5 is its subset).
ENCODE_AS = {"BIG5" => "BIG5"}

def encode(text : String, encoding : String) : Bytes
  encoding = ENCODE_AS[encoding]? || Fathom::Encoding.iconv_name(encoding)
  # Clean per character, then encode in one call: stateful encodings
  # (ISO-2022-JP) must not switch character sets around every character.
  cleaned = String.build do |io|
    text.each_char do |c|
      c.to_s.encode(encoding)
      io << c
    rescue ArgumentError
      FALLBACK[c]?.try { |s| io << s } # otherwise drop (e.g. combining stress marks)
    end
  end
  cleaned.encode(encoding)
end

def write(dir : String, name : String, bytes : Bytes)
  Dir.mkdir_p(dir)
  File.write(File.join(dir, name), bytes)
end

sources = String.build do |md|
  md << "# Corpus sources\n\nText from Wikipedia, licensed [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). "
  md << "Fetched with `crystal run tools/gen_corpus.cr -- --fetch`.\n\n"
  ARTICLES.each do |lang, titles|
    titles.each_with_index do |title, i|
      path = File.join(CORPUS, "UTF-8", "#{lang}_#{i + 1}.txt")
      if ARGV.includes?("--fetch") && !File.exists?(path)
        write(File.dirname(path), File.basename(path), fetch(lang, title).to_slice)
      end
      md << "- `#{lang}_#{i + 1}.txt`: [#{title}](https://#{host(lang)}/wiki/#{URI.encode_path(title.tr(" ", "_"))}#{VARIANTS[lang]?.try { |v| "?variant=#{v}" }})\n"
    end
  end
  md << "\n## Synthetic samples\n\n"
  md << "- `IBM437/dos_1.txt`: Synthetic DOS CP437 receipt and lab-notes sample generated by `tools/gen_corpus.cr` (not from Wikipedia; exercises CP437 symbols `¢`, `¥`, `±`, `≈`, `√`).\n"
end
File.write(File.join(CORPUS, "SOURCES.md"), sources)

sources = Dir.glob(File.join(CORPUS, "UTF-8", "*.txt")).reject(&.ends_with?("_bom.txt")).sort!
abort "no sources in corpus/UTF-8; run with --fetch" if sources.empty?
Dir.glob(File.join(FIXTURE, "*", "*.txt")).each { |f| File.delete(f) }
Dir.glob(File.join(CORPUS, "*", "*.txt")).each { |f| File.delete(f) if !f.starts_with?(File.join(CORPUS, "UTF-8", "")) || f.ends_with?("_bom.txt") }

sources.each do |path|
  name = File.basename(path)
  lang = name.split('_').first
  text = File.read(path)
  gate = name.ends_with?("_1.txt")

  outputs = [{"UTF-8", name, text.to_slice}]
  TARGETS.each do |encoding, langs|
    outputs << {encoding, name, encode(text, encoding)} if langs.includes?(lang)
  end
  if lang == "ru"
    bom = name.sub(".txt", "_bom.txt")
    outputs << {"UTF-8", bom, Bytes[0xEF, 0xBB, 0xBF] + text.to_slice}
    {"UTF-16LE" => Bytes[0xFF, 0xFE], "UTF-16BE" => Bytes[0xFE, 0xFF],
     "UTF-32LE" => Bytes[0xFF, 0xFE, 0, 0], "UTF-32BE" => Bytes[0, 0, 0xFE, 0xFF]}.each do |encoding, mark|
      outputs << {encoding, bom, mark + text.encode(encoding)}
    end
  end
  if lang == "en"
    # BOM-less UTF-16 is only detectable for mostly-ASCII text (via NUL bytes).
    nobom = name.sub(".txt", "_nobom.txt")
    {"UTF-16LE", "UTF-16BE"}.each { |encoding| outputs << {encoding, nobom, text.encode(encoding)} }
  end
  if name == "en_1.txt"
    # DOS CP437 shares basic accented letters with IBM850; include CP437-specific symbols
    # (¢, ¥, ±, ≈, √) so the sample genuinely distinguishes IBM437 from IBM850.
    cp437_sample = (<<-TEXT * 16)
      DOS CP437: 50¢, ¥200 - Zürich café (1992):
        Item A: résumé printing     50¢   (±2¢ tax, 98.6°F)
        Item B: über coffee roast  ¥200   (√2 ≈ 1.41, 2² = 4)
        Notes: naïve façade check; à la carte total = 50¢ + ¥200.
      TEXT
    outputs << {"IBM437", "dos_1.txt", encode(cp437_sample, "IBM437")}
  end

  outputs.each do |encoding, file, bytes|
    write(File.join(CORPUS, encoding), file, bytes) unless encoding == "UTF-8" && file == name
    # lt_1.txt has none of ISO-8859-13's distinguishing quote bytes (0xA1/0xA5/0xB4/0xFF)
    # and therefore tie-breaks to WINDOWS-1257; use lt_3.txt in the CI gate fixture instead.
    in_gate = encoding == "ISO-8859-13" && lang == "lt" ? file == "lt_3.txt" : gate
    write(File.join(FIXTURE, encoding), file, bytes) if in_gate
  end
end

puts "corpus: #{Dir.glob(File.join(CORPUS, "*", "*.txt")).size} files, gate fixture: #{Dir.glob(File.join(FIXTURE, "*", "*.txt")).size} files"
