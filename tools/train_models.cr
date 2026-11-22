# Trains language-level bigram models from disjoint Wikipedia articles and writes
# quantized 64x64 matrices to tools/models/*.json.
#
#   crystal run tools/train_models.cr -- --fetch   # download articles into tools/models/sources, then train
#   crystal run tools/train_models.cr              # retrain from cached tools/models/sources/*.txt
#
# Text is licensed CC BY-SA 4.0; training articles are strictly disjoint from corpus/SOURCES.md.
require "http/client"
require "json"
require "uri"

MODELS_DIR  = File.expand_path("models", __DIR__)
SOURCES_DIR = File.join(MODELS_DIR, "sources")
MAX_LEN     = 8192
ORDER_SIZE  =   64
ALPHA       =  0.5
SCALE       = 20.0

# Training articles per Wikipedia language code — disjoint from corpus/SOURCES.md.
ARTICLES = {
  "ru" => [
    "Россия", "История", "Математика", "Физика", "Биология",
    "Астрономия", "География", "Литература", "Музыка", "Архитектура",
  ],
  "uk" => [
    "Україна", "Історія", "Математика", "Фізика", "Біологія",
    "Астрономія", "Географія", "Література", "Музика", "Архітектура",
  ],
  "be" => [
    "Беларусь", "Гісторыя", "Матэматыка", "Фізіка", "Біялогія",
    "Астраномія", "Геаграфія", "Літаратура", "Музыка", "Архітэктура",
  ],
  "fr" => ["France", "Histoire", "Mathématiques", "Physique"],
  "de" => ["Deutschland", "Geschichte", "Mathematik", "Physik"],
  "es" => ["España", "Historia", "Matemáticas", "Física"],
  "it" => ["Italia", "Storia", "Matematica", "Fisica"],
  "pt" => ["Portugal", "História", "Matemática", "Física"],
  "en" => ["History", "Mathematics", "Physics", "Biology"],
}

# Ordered lowercase alphabets (1..K, max 63; order 0 = word boundary / non-letter).
ALPHABETS = {
  "ru"      => "абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
  "uk"      => "абвгґдеєжзиіїйклмнопрстуфхцчшщьюя",
  "be"      => "абвгдеёжзійклмнопрстуўфхцчшыьэюя",
  "western" => "abcdefghijklmnopqrstuvwxyzéèêëàâäáãçíîïìñóôöòõúûüùßœÿ",
}

def fetch(lang : String, title : String) : String
  query = URI::Params.encode({
    "action"        => "query",
    "prop"          => "extracts",
    "explaintext"   => "1",
    "redirects"     => "1",
    "format"        => "json",
    "formatversion" => "2",
    "titles"        => title,
  })
  res = nil
  wait = 2
  6.times do
    sleep wait.seconds
    res = HTTP::Client.get("https://#{lang}.wikipedia.org/w/api.php?#{query}",
      headers: HTTP::Headers{"User-Agent" => "fathom-trainer/0.3"})
    break unless res.status_code == 429
    wait = res.headers["Retry-After"]?.try(&.to_i?) || wait * 2
  end
  res = res || raise "#{lang}:#{title}: no response"
  raise "#{lang}:#{title}: HTTP #{res.status_code}" unless res.success?
  extract = JSON.parse(res.body)["query"]["pages"][0]["extract"]?.try(&.as_s)
  raise "#{lang}:#{title}: no extract" unless extract

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

def count_bigrams(text : String, alphabet : String) : {Array(Float64), Float64}
  index = {} of Char => Int32
  alphabet.each_char_with_index { |ch, i| index[ch] = i + 1 }

  counts = Array(Float64).new(ORDER_SIZE * ORDER_SIZE, 0.0)
  total = 0.0
  prev = 0

  text.each_char do |ch|
    curr = index[ch.downcase]? || 0
    if prev != 0 || curr != 0
      counts[(prev << 6) | curr] += 1.0
      total += 1.0
    end
    prev = curr
  end
  if prev != 0
    counts[prev << 6] += 1.0
    total += 1.0
  end

  {counts, total}
end

def build_matrix(counts : Array(Float64), total : Float64, alphabet : String) : Array(Int32)
  k = alphabet.size
  vocab = ((k + 1) * (k + 1) - 1).to_f64
  baseline = 1.0 / vocab
  denom = total + ALPHA * vocab

  matrix = Array(Int32).new(ORDER_SIZE * ORDER_SIZE, 0)
  (0..k).each do |p|
    (0..k).each do |c|
      next if p == 0 && c == 0
      idx = (p << 6) | c
      prob = (counts[idx] + ALPHA) / denom
      llr = Math.log(prob / baseline)
      matrix[idx] = (llr * SCALE).round.clamp(-127.0, 127.0).to_i32
    end
  end
  matrix
end

def save_model(name : String, alphabet : String, matrix : Array(Int32))
  Dir.mkdir_p(MODELS_DIR)
  path = File.join(MODELS_DIR, "#{name}.json")
  File.write(path, {name: name, alphabet: alphabet, matrix: matrix}.to_json)
  puts "wrote #{path} (alphabet=#{alphabet.size})"
end

Dir.mkdir_p(SOURCES_DIR)

if ARGV.includes?("--fetch")
  sources = String.build do |md|
    md << "# Training model sources\n\n"
    md << "Text from Wikipedia, licensed [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). "
    md << "Disjoint from `corpus/SOURCES.md`. Fetched with `crystal run tools/train_models.cr -- --fetch`.\n\n"
    ARTICLES.each do |lang, titles|
      lang_dir = File.join(SOURCES_DIR, lang)
      Dir.mkdir_p(lang_dir)
      titles.each_with_index do |title, i|
        file = File.join(lang_dir, "#{i + 1}.txt")
        unless File.exists?(file)
          puts "fetching #{lang}: #{title}..."
          File.write(file, fetch(lang, title))
        end
        md << "- `#{lang}/#{i + 1}.txt`: [#{title}](https://#{lang}.wikipedia.org/wiki/#{URI.encode_path(title.tr(" ", "_"))})\n"
      end
    end
  end
  File.write(File.join(MODELS_DIR, "SOURCES.md"), sources)
end

%w[ru uk be].each do |lang|
  alphabet = ALPHABETS[lang]
  files = Dir.glob(File.join(SOURCES_DIR, lang, "*.txt")).sort
  abort "no training files in #{SOURCES_DIR}/#{lang}; run with --fetch" if files.empty?
  text = files.map { |f| File.read(f) }.join("\n")
  counts, total = count_bigrams(text, alphabet)
  save_model(lang, alphabet, build_matrix(counts, total, alphabet))
end

# Western model balances bigram probabilities equally across fr, de, es, it, pt, en.
western_langs = %w[fr de es it pt en]
western_alpha = ALPHABETS["western"]
per_lang = western_langs.map do |lang|
  files = Dir.glob(File.join(SOURCES_DIR, lang, "*.txt")).sort
  abort "no training files in #{SOURCES_DIR}/#{lang}; run with --fetch" if files.empty?
  count_bigrams(files.map { |f| File.read(f) }.join("\n"), western_alpha)
end

avg_total = per_lang.sum(&.[1]) / per_lang.size
balanced_counts = Array(Float64).new(ORDER_SIZE * ORDER_SIZE, 0.0)
per_lang.each do |counts, total|
  next if total == 0.0
  weight = avg_total / (total * per_lang.size)
  counts.each_with_index do |c, idx|
    balanced_counts[idx] += c * weight
  end
end
save_model("western", western_alpha, build_matrix(balanced_counts, avg_total, western_alpha))
