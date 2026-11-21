require "./fathom/tables"

# Guesses the character encoding of raw bytes.
#
# ```
# Fathom.detect(bytes) # => "WINDOWS-1251"
# ```
module Fathom
  VERSION = "0.1.0"

  # UTF-32LE must come before UTF-16LE: its BOM starts with the same two bytes.
  BOMS = {
    "UTF-32LE" => Bytes[0xFF, 0xFE, 0x00, 0x00],
    "UTF-32BE" => Bytes[0x00, 0x00, 0xFE, 0xFF],
    "UTF-8"    => Bytes[0xEF, 0xBB, 0xBF],
    "UTF-16LE" => Bytes[0xFF, 0xFE],
    "UTF-16BE" => Bytes[0xFE, 0xFF],
  }

  # Letter frequency in percent for Russian, with Ukrainian and Belarusian extras.
  # ponytail: hand-entered unigram table; replace with bigram models trained
  # from a corpus when short inputs or more languages need better accuracy.
  CYRILLIC_FREQ = {
    'о' => 10.97, 'е' => 8.45, 'а' => 8.01, 'и' => 7.35, 'н' => 6.70, 'т' => 6.26,
    'с' => 5.47, 'р' => 4.73, 'в' => 4.54, 'л' => 4.40, 'к' => 3.49, 'м' => 3.21,
    'д' => 2.98, 'п' => 2.81, 'у' => 2.62, 'я' => 2.01, 'ы' => 1.90, 'ь' => 1.74,
    'г' => 1.70, 'з' => 1.65, 'б' => 1.59, 'ч' => 1.44, 'й' => 1.21, 'х' => 0.97,
    'ж' => 0.94, 'ш' => 0.73, 'ю' => 0.64, 'ц' => 0.48, 'щ' => 0.36, 'э' => 0.32,
    'ф' => 0.26, 'ъ' => 0.04, 'ё' => 0.04,
    'і' => 5.0, 'ї' => 0.7, 'є' => 0.6, 'ґ' => 0.01, 'ў' => 1.0,
  }

  # Returns the encoding name (usable with `String.new(bytes, name)`),
  # or `nil` when the bytes look like nothing this shard knows.
  def self.detect(bytes : Bytes) : String?
    BOMS.each { |name, bom| return name if bytes[0, bom.size]? == bom }
    return "UTF-8" if utf8?(bytes)
    # Binary data or UTF-16 without a BOM: not handled yet.
    return nil if bytes.includes?(0_u8)

    # WINDOWS-1252 is first in TABLES, so it wins ties (text whose only
    # non-ASCII bytes are curly quotes and dashes, shared with WINDOWS-1251).
    name, score = TABLES.map { |name, table| {name, score(bytes, table, name != "WINDOWS-1252")} }.max_by(&.[1])
    score < 0 ? nil : name
  end

  # Valid UTF-8, allowing a multibyte character cut off at the end
  # (callers often pass only the first N bytes of a document).
  private def self.utf8?(bytes) : Bool
    return true if Unicode.valid?(bytes)
    cut = (1..3).find { |n| n <= bytes.size && bytes[-n] >= 0xC0 }
    !!cut && Unicode.valid?(bytes[0, bytes.size - cut])
  end

  # Average plausibility of the non-ASCII bytes when read through *table*.
  private def self.score(bytes, table, cyrillic) : Float64
    total = 0.0
    high = 0
    prev = ' '
    bytes.each do |byte|
      char = byte < 0x80 ? byte.unsafe_chr : table[byte - 0x80]
      if byte >= 0x80
        high += 1
        total += cyrillic ? cyrillic_weight(char, prev) : latin_weight(char, prev)
      end
      prev = char
    end
    total / high
  end

  private def self.junk?(char) : Bool
    char == '�' || char.ord < 0xA0 || (0x2500..0x259F).includes?(char.ord)
  end

  private def self.cyrillic_weight(char, prev) : Float64
    return -10.0 if junk?(char)
    return 0.0 unless char.letter?
    weight = CYRILLIC_FREQ[char.downcase]? || -5.0
    weight -= 5.0 if prev.lowercase? && char.uppercase? # "пРИВЕТ": wrong case table
    weight -= 5.0 if prev.ascii_letter?                 # Latin and Cyrillic glued in one word
    weight
  end

  # Accented Latin letters sit next to ASCII letters ("été"), not in runs ("Ïðèâåò").
  private def self.latin_weight(char, prev) : Float64
    return -10.0 if junk?(char)
    return 0.0 unless char.letter?
    prev.letter? && !prev.ascii? ? -8.0 : 2.0
  end
end
