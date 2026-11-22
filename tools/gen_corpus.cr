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

CORPUS  = File.expand_path("../corpus", __DIR__)
FIXTURE = File.expand_path("../spec/fixtures/corpus", __DIR__)
MAX_LEN = 4096

# lang => article titles. The first article of each language also goes into the CI gate fixture.
ARTICLES = {
  "ru" => ["Волга", "Фотосинтез", "Пушкин, Александр Сергеевич"],
  "uk" => ["Шевченко Тарас Григорович", "Фотосинтез", "Карпати"],
  "be" => ["Мінск", "Янка Купала", "Нёман"],
  "de" => ["Rhein", "Photosynthese", "Johann Wolfgang von Goethe"],
  "fr" => ["Loire (fleuve)", "Photosynthèse", "Victor Hugo"],
  "es" => ["Ebro", "Fotosíntesis", "Miguel de Cervantes"],
  "it" => ["Po", "Fotosintesi clorofilliana", "Dante Alighieri"],
  "pt" => ["Rio Tejo", "Fotossíntese", "Luís de Camões"],
  "en" => ["Zürich", "Crème brûlée", "Pelé"],
}

# encoding => languages encoded into it.
TARGETS = {
  "WINDOWS-1251" => %w(ru uk be),
  "KOI8-R"       => %w(ru),
  "KOI8-U"       => %w(uk),
  "ISO-8859-5"   => %w(ru uk),
  "IBM866"       => %w(ru),
  "WINDOWS-1252" => %w(de fr es it pt en),
}

# ASCII stand-ins for punctuation that legacy Cyrillic code pages cannot encode.
FALLBACK = {'«' => "\"", '»' => "\"", '„' => "\"", '“' => "\"", '”' => "\"",
            '‘' => "'", '’' => "'", '—' => "-", '–' => "-", '…' => "...", ' ' => " "}

def fetch(lang : String, title : String) : String
  query = URI::Params.encode({"action" => "query", "prop" => "extracts", "explaintext" => "1",
                              "redirects" => "1", "format" => "json", "formatversion" => "2", "titles" => title})
  res = nil
  wait = 2
  6.times do
    sleep wait.seconds # Wikipedia rate-limits bursts with HTTP 429
    res = HTTP::Client.get("https://#{lang}.wikipedia.org/w/api.php?#{query}",
      headers: HTTP::Headers{"User-Agent" => "fathom-corpus/0.1"})
    break unless res.status_code == 429
    wait = res.headers["Retry-After"]?.try(&.to_i?) || wait * 2
  end
  res = res.not_nil!
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

def encode(text : String, encoding : String) : Bytes
  io = IO::Memory.new
  text.each_char do |c|
    begin
      io.write c.to_s.encode(encoding)
    rescue ArgumentError
      FALLBACK[c]?.try { |s| io.write s.encode(encoding) } # otherwise drop (e.g. combining stress marks)
    end
  end
  io.to_slice
end

def write(dir : String, name : String, bytes : Bytes)
  Dir.mkdir_p(dir)
  File.write(File.join(dir, name), bytes)
end

if ARGV.includes?("--fetch")
  # Resumable: articles already in corpus/UTF-8 are kept; delete a file to re-fetch it.
  sources = String.build do |md|
    md << "# Corpus sources\n\nText from Wikipedia, licensed [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). "
    md << "Fetched with `crystal run tools/gen_corpus.cr -- --fetch`.\n\n"
    ARTICLES.each do |lang, titles|
      titles.each_with_index do |title, i|
        path = File.join(CORPUS, "UTF-8", "#{lang}_#{i + 1}.txt")
        write(File.dirname(path), File.basename(path), fetch(lang, title).to_slice) unless File.exists?(path)
        md << "- `#{lang}_#{i + 1}.txt`: [#{title}](https://#{lang}.wikipedia.org/wiki/#{URI.encode_path(title.tr(" ", "_"))})\n"
      end
    end
  end
  File.write(File.join(CORPUS, "SOURCES.md"), sources)
end

sources = Dir.glob(File.join(CORPUS, "UTF-8", "*.txt")).reject(&.ends_with?("_bom.txt")).sort
abort "no sources in corpus/UTF-8; run with --fetch" if sources.empty?
Dir.glob(File.join(FIXTURE, "*", "*.txt")).each { |f| File.delete(f) }
Dir.glob(File.join(CORPUS, "*", "*.txt")).each { |f| File.delete(f) unless f.starts_with?(File.join(CORPUS, "UTF-8", "")) && !f.ends_with?("_bom.txt") }

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

  outputs.each do |encoding, file, bytes|
    write(File.join(CORPUS, encoding), file, bytes) unless encoding == "UTF-8" && file == name
    write(File.join(FIXTURE, encoding), file, bytes) if gate
  end
end

puts "corpus: #{Dir.glob(File.join(CORPUS, "*", "*.txt")).size} files, gate fixture: #{Dir.glob(File.join(FIXTURE, "*", "*.txt")).size} files"
