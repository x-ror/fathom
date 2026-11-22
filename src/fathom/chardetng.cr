# Port of the single-byte and UTF-8 parts of chardetng 1.0.0
# (https://github.com/hsivonen/chardetng) to Crystal.
#
# Copyright Mozilla Foundation. Licensed under the Apache License, Version 2.0
# or the MIT license, at your option. Tables in `chardetng/data.cr` are CC0.
#
# Deliberately omitted relative to upstream: the CJK candidates (GBK, EUC-JP,
# EUC-KR, Shift_JIS, Big5), ISO-2022-JP, and top-level-domain hints. `guess`
# behaves like upstream `guess(None, Utf8Detection::Allow)` with those
# candidates disqualified.
require "./chardetng/data"

module Fathom
  module Chardetng
    private LATIN_ADJACENCY_PENALTY                   =  -50_i64
    private IMPLAUSIBILITY_PENALTY                    = -220_i64
    private ORDINAL_BONUS                             =  300_i64
    private COPYRIGHT_BONUS                           =  222_i64
    private IMPLAUSIBLE_LATIN_CASE_TRANSITION_PENALTY = -180_i64
    private NON_LATIN_CAPITALIZATION_BONUS            =   40_i64
    private NON_LATIN_ALL_CAPS_PENALTY                =  -40_i64
    private NON_LATIN_MIXED_CASE_PENALTY              =  -20_i64

    # Latin letter caseless class
    private LATIN_LETTER =   1_u8
    private ASCII_DIGIT  = 100_u8

    private PLAUSIBLE_NEXT_TO_ALPHABETIC_ON_EITHER_SIDE           = 0
    private IMPLAUSIBLE_NEXT_TO_ALPHABETIC_ON_EITHER_SIDE         = 1
    private IMPLAUSIBLE_BEFORE_ALPHABETIC                         = 2
    private IMPLAUSIBLE_AFTER_ALPHABETIC                          = 3
    private PLAUSIBLE_NEXT_TO_NON_ASCII_ALPHABETIC_ON_EITHER_SIDE = 4
    private PLAUSIBLE_NEXT_TO_ASCII_ALPHABETIC_ON_EITHER_SIDE     = 5
    private WINDOWS_1256_ZWNJ                                     = 2

    private SPACE = " ".to_slice

    # Byte classes and pairwise class scores for one single-byte encoding.
    # :nodoc:
    struct SingleByteData
      getter encoding : String

      def initialize(@encoding : String, @lower : Bytes, @upper : Bytes, @probabilities : Bytes, @ascii : Int32, @non_ascii : Int32)
      end

      @[AlwaysInline]
      def classify(byte : UInt8) : UInt8
        byte < 0x80 ? @lower.unsafe_fetch(byte) : @upper.unsafe_fetch(byte & 0x7F)
      end

      @[AlwaysInline]
      def latin_alphabetic?(caseless_class : UInt8) : Bool
        caseless_class > 0 && caseless_class < @ascii + @non_ascii
      end

      @[AlwaysInline]
      def non_latin_alphabetic?(caseless_class : UInt8, windows_1256 : Bool) : Bool
        lower_bound = windows_1256 ? WINDOWS_1256_ZWNJ : 1
        caseless_class > lower_bound && caseless_class < @ascii + @non_ascii
      end

      def score(current_class : UInt8, previous_class : UInt8, windows_1256 : Bool) : Int64
        current = current_class.to_i32
        previous = previous_class.to_i32
        stored_boundary = @ascii + @non_ascii
        if current < stored_boundary
          if previous < stored_boundary
            # Both below
            if index = compute_index(previous, current)
              b = @probabilities[index]
              b == 255 ? IMPLAUSIBILITY_PENALTY : b.to_i64
            else
              0_i64
            end
          elsif current == 0 || current == ASCII_DIGIT || (windows_1256 && current == WINDOWS_1256_ZWNJ)
            # Current is space-like
            0_i64
          else
            # Current is alphabetic, previous is unstored
            case previous - stored_boundary
            when PLAUSIBLE_NEXT_TO_ALPHABETIC_ON_EITHER_SIDE           then 0_i64
            when IMPLAUSIBLE_NEXT_TO_ALPHABETIC_ON_EITHER_SIDE         then IMPLAUSIBILITY_PENALTY
            when IMPLAUSIBLE_BEFORE_ALPHABETIC                         then IMPLAUSIBILITY_PENALTY
            when IMPLAUSIBLE_AFTER_ALPHABETIC                          then 0_i64
            when PLAUSIBLE_NEXT_TO_NON_ASCII_ALPHABETIC_ON_EITHER_SIDE then current < @ascii ? IMPLAUSIBILITY_PENALTY : 0_i64
            when PLAUSIBLE_NEXT_TO_ASCII_ALPHABETIC_ON_EITHER_SIDE     then current < @ascii ? 0_i64 : IMPLAUSIBILITY_PENALTY
            else                                                            0_i64 # previous is ASCII_DIGIT
            end
          end
        elsif previous < stored_boundary
          if previous == 0 || previous == ASCII_DIGIT || (windows_1256 && previous == WINDOWS_1256_ZWNJ)
            # Previous is space-like
            0_i64
          else
            # Previous is alphabetic, current is unstored
            case current - stored_boundary
            when PLAUSIBLE_NEXT_TO_ALPHABETIC_ON_EITHER_SIDE           then 0_i64
            when IMPLAUSIBLE_NEXT_TO_ALPHABETIC_ON_EITHER_SIDE         then IMPLAUSIBILITY_PENALTY
            when IMPLAUSIBLE_BEFORE_ALPHABETIC                         then 0_i64
            when IMPLAUSIBLE_AFTER_ALPHABETIC                          then IMPLAUSIBILITY_PENALTY
            when PLAUSIBLE_NEXT_TO_NON_ASCII_ALPHABETIC_ON_EITHER_SIDE then previous < @ascii ? IMPLAUSIBILITY_PENALTY : 0_i64
            when PLAUSIBLE_NEXT_TO_ASCII_ALPHABETIC_ON_EITHER_SIDE     then previous < @ascii ? 0_i64 : IMPLAUSIBILITY_PENALTY
            else                                                            0_i64 # current is ASCII_DIGIT
            end
          end
        elsif current == ASCII_DIGIT || previous == ASCII_DIGIT
          0_i64
        else
          # Both above
          IMPLAUSIBILITY_PENALTY
        end
      end

      @[AlwaysInline]
      private def compute_index(x : Int32, y : Int32) : Int32?
        return nil if x == 0 && y == 0
        return nil if x < @ascii && y < @ascii
        if y >= @ascii
          return @ascii * @non_ascii + (@ascii + @non_ascii) * (y - @ascii) + x
        end
        y * @non_ascii + x - @ascii
      end
    end

    # :nodoc:
    WINDOWS_1258_DATA = SingleByteData.new("WINDOWS-1258", LATIN_ASCII, WINDOWS_1258, VIETNAMESE, 27, 25)
    # :nodoc:
    WINDOWS_1250_DATA = SingleByteData.new("WINDOWS-1250", LATIN_ASCII, WINDOWS_1250, CENTRAL, 27, 41)
    # :nodoc:
    ISO_8859_2_DATA = SingleByteData.new("ISO-8859-2", LATIN_ASCII, ISO_8859_2, CENTRAL, 27, 41)
    # :nodoc:
    WINDOWS_1251_DATA = SingleByteData.new("WINDOWS-1251", NON_LATIN_ASCII, WINDOWS_1251, CYRILLIC, 2, 44)
    # :nodoc:
    KOI8_U_DATA = SingleByteData.new("KOI8-U", NON_LATIN_ASCII, KOI8_U, CYRILLIC, 2, 44)
    # :nodoc:
    ISO_8859_5_DATA = SingleByteData.new("ISO-8859-5", NON_LATIN_ASCII, ISO_8859_5, CYRILLIC, 2, 44)
    # :nodoc:
    IBM866_DATA = SingleByteData.new("IBM866", NON_LATIN_ASCII, IBM866, CYRILLIC, 2, 44)
    # :nodoc:
    WINDOWS_1252_DATA = SingleByteData.new("WINDOWS-1252", LATIN_ASCII, WINDOWS_1252, WESTERN, 27, 32)
    # :nodoc:
    WINDOWS_1252_ICELANDIC_DATA = SingleByteData.new("WINDOWS-1252", LATIN_ASCII, WINDOWS_1252_ICELANDIC, ICELANDIC, 27, 13)
    # :nodoc:
    WINDOWS_1253_DATA = SingleByteData.new("WINDOWS-1253", NON_LATIN_ASCII, WINDOWS_1253, GREEK, 2, 35)
    # :nodoc:
    ISO_8859_7_DATA = SingleByteData.new("ISO-8859-7", NON_LATIN_ASCII, ISO_8859_7, GREEK, 2, 35)
    # :nodoc:
    WINDOWS_1254_DATA = SingleByteData.new("WINDOWS-1254", TURKISH_ASCII, WINDOWS_1254, TURKISH, 26, 13)
    # :nodoc:
    WINDOWS_1255_DATA = SingleByteData.new("WINDOWS-1255", NON_LATIN_ASCII, WINDOWS_1255, HEBREW, 2, 34)
    # :nodoc:
    ISO_8859_8_DATA = SingleByteData.new("ISO-8859-8", NON_LATIN_ASCII, ISO_8859_8, HEBREW, 2, 34)
    # :nodoc:
    WINDOWS_1256_DATA = SingleByteData.new("WINDOWS-1256", NON_LATIN_ASCII, WINDOWS_1256, ARABIC, 2, 51)
    # :nodoc:
    ISO_8859_6_DATA = SingleByteData.new("ISO-8859-6", NON_LATIN_ASCII, ISO_8859_6, ARABIC, 2, 51)
    # :nodoc:
    WINDOWS_1257_DATA = SingleByteData.new("WINDOWS-1257", LATIN_ASCII, WINDOWS_1257, BALTIC, 27, 19)
    # :nodoc:
    ISO_8859_13_DATA = SingleByteData.new("ISO-8859-13", LATIN_ASCII, ISO_8859_13, BALTIC, 27, 19)
    # :nodoc:
    ISO_8859_4_DATA = SingleByteData.new("ISO-8859-4", LATIN_ASCII, ISO_8859_4, BALTIC, 27, 19)
    # :nodoc:
    WINDOWS_874_DATA = SingleByteData.new("WINDOWS-874", NON_LATIN_ASCII, WINDOWS_874, THAI, 2, 70)

    # Fathom extensions: derived class tables over the upstream probability matrices.
    # :nodoc:
    IBM437_DATA = SingleByteData.new("IBM437", LATIN_ASCII, IBM437, WESTERN, 27, 32)
    # :nodoc:
    IBM850_DATA = SingleByteData.new("IBM850", LATIN_ASCII, IBM850, WESTERN, 27, 32)
    # :nodoc:
    MACINTOSH_DATA = SingleByteData.new("MACINTOSH", LATIN_ASCII, MACINTOSH, WESTERN, 27, 32)
    # :nodoc:
    IBM852_DATA = SingleByteData.new("IBM852", LATIN_ASCII, IBM852, CENTRAL, 27, 41)
    # :nodoc:
    KOI8_R_DATA = SingleByteData.new("KOI8-R", NON_LATIN_ASCII, KOI8_R, CYRILLIC, 2, 44)
    # :nodoc:
    X_MAC_CYRILLIC_DATA = SingleByteData.new("X-MAC-CYRILLIC", NON_LATIN_ASCII, X_MAC_CYRILLIC, CYRILLIC, 2, 44)

    # A candidate encoding with a running score; `nil` score means disqualified.
    # :nodoc:
    abstract class Candidate
      getter score : Int64? = 0_i64

      # Prior against this candidate, subtracted from its final score (Fathom extension).
      property handicap = 0_i64

      abstract def encoding : String

      # Score as seen by `Detector#guess` (upstream `Candidate::score` with a generic TLD).
      def guess_score : Int64?
        (score = qualified_score) ? score - @handicap : nil
      end

      protected def qualified_score : Int64?
        @score
      end

      def feed(buffer : Bytes, last : Bool) : Nil
        return unless old = @score
        @score = (delta = feed_inner(buffer, last)) ? old + delta : nil
      end

      protected abstract def feed_inner(buffer : Bytes, last : Bool) : Int64?
    end

    # :nodoc:
    abstract class SingleByteCandidate < Candidate
      @prev = 0_u8

      def initialize(@data : SingleByteData)
      end

      def encoding : String
        @data.encoding
      end

      protected def feed_inner(buffer : Bytes, last : Bool) : Int64?
        score = feed_bytes(buffer) || return nil
        return score unless last
        # Treat EOF as space-like
        tail = feed_bytes(SPACE) || return nil
        score + tail
      end

      protected abstract def feed_bytes(buffer : Bytes) : Int64?
    end

    # :nodoc:
    abstract class WordTrackingCandidate < SingleByteCandidate
      @prev_ascii = true
      @current_word_len = 0_i64
      @longest_word = 0_i64

      protected def qualified_score : Int64?
        @longest_word < 2 ? nil : @score
      end

      @[AlwaysInline]
      protected def track_word(non_ascii_alphabetic : Bool) : Nil
        if non_ascii_alphabetic
          @current_word_len += 1
        else
          @longest_word = @current_word_len if @current_word_len > @longest_word
          @current_word_len = 0_i64
        end
      end
    end

    private enum LatinCaseState
      Space
      Upper
      Lower
      AllCaps
    end

    private enum NonLatinCaseState
      Space
      Upper
      Lower
      UpperLower
      AllCaps
      Mix
    end

    # Cyrillic and Greek.
    # :nodoc:
    class NonLatinCasedCandidate < WordTrackingCandidate
      @case_state = NonLatinCaseState::Space
      @prev_was_a0 = false
      @ibm866 : Bool
      @koi8_u : Bool

      def initialize(@data : SingleByteData)
        @ibm866 = data.encoding == "IBM866"
        # KOI8-R shares KOI8-U's inverted case layout (Fathom extension).
        @koi8_u = data.encoding.in?("KOI8-U", "KOI8-R")
      end

      protected def feed_bytes(buffer : Bytes) : Int64?
        score = 0_i64
        buffer.each do |b|
          klass = @data.classify(b)
          return nil if klass == 255
          caseless_class = klass & 0x7F

          ascii = b < 0x80
          ascii_pair = @prev_ascii && ascii

          non_ascii_alphabetic = @data.non_latin_alphabetic?(caseless_class, false)

          # ASCII doesn't participate in non-Latin casing.
          if caseless_class == LATIN_LETTER
            # Latin: mark this word as a mess.
            @case_state = NonLatinCaseState::Mix
          elsif !non_ascii_alphabetic
            # Space
            case @case_state
            when .upper_lower?
              # Intentionally applied only once per word.
              score += NON_LATIN_CAPITALIZATION_BONUS
            when .all_caps?
              # Intentionally applied only once per word, and only to KOI8-U.
              score += NON_LATIN_ALL_CAPS_PENALTY if @koi8_u
            when .mix?
              # Per letter
              score += NON_LATIN_MIXED_CASE_PENALTY * @current_word_len
            else
            end
            @case_state = NonLatinCaseState::Space
          elsif (klass >> 7) == 0
            # Lower case
            case @case_state
            when .space?    then @case_state = NonLatinCaseState::Lower
            when .upper?    then @case_state = NonLatinCaseState::UpperLower
            when .all_caps? then @case_state = NonLatinCaseState::Mix
            else
            end
          else
            # Upper case
            case @case_state
            when .space?                then @case_state = NonLatinCaseState::Upper
            when .upper?                then @case_state = NonLatinCaseState::AllCaps
            when .lower?, .upper_lower? then @case_state = NonLatinCaseState::Mix
            else
            end
          end

          track_word(non_ascii_alphabetic)

          is_a0 = b == 0xA0
          unless ascii_pair
            # 0xA0 is no-break space in many other encodings, so avoid
            # assigning score to IBM866 when 0xA0 occurs next to itself
            # or a space-like byte.
            unless @ibm866 && ((is_a0 && (@prev_was_a0 || @prev == 0)) || (caseless_class == 0 && @prev_was_a0))
              score += @data.score(caseless_class, @prev, false)
            end

            if @prev == LATIN_LETTER && non_ascii_alphabetic
              score += LATIN_ADJACENCY_PENALTY
            elsif caseless_class == LATIN_LETTER && @data.non_latin_alphabetic?(@prev, false)
              score += LATIN_ADJACENCY_PENALTY
            end
          end

          @prev_ascii = ascii
          @prev = caseless_class
          @prev_was_a0 = is_a0
        end
        score
      end
    end

    private enum OrdinalState
      Other
      Space
      PeriodAfterN
      OrdinalExpectingSpace
      OrdinalExpectingSpaceUndoImplausibility
      OrdinalExpectingSpaceOrDigit
      OrdinalExpectingSpaceOrDigitUndoImplausibility
      UpperN
      LowerN
      FeminineAbbreviationStartLetter
      Digit
      Roman
      Copyright
    end

    # :nodoc:
    class LatinCandidate < SingleByteCandidate
      @case_state = LatinCaseState::Space
      @prev_non_ascii = 0_i64
      @ordinal_state = OrdinalState::Space # Used only when `@windows_1252`
      @prev_high_letter = false            # Used only with `@twins`
      @punctuation_pending = false

      # Non-ASCII space-like bytes other than the apostrophe 0x92 found between
      # two letters ("acci—n"). Doesn't affect the score; a twin with any of
      # these doesn't read the input plausibly (Fathom extension).
      getter glued_punctuation = 0

      # *twins* (Fathom extension): common Latin encodings that this rarer one
      # may not outscore while any of them reads the input plausibly: a score of
      # zero or more (its non-ASCII bytes are at worst neutral punctuation) and
      # no `glued_punctuation`.
      # Such candidates are also penalized for non-ASCII letters glued to ASCII
      # digits ("50ø" for CP437 "50¢"), which upstream scores as neutral.
      def initialize(@data : SingleByteData, @windows_1252 : Bool = false, @twins : Array(LatinCandidate)? = nil)
      end

      protected def qualified_score : Int64?
        if twins = @twins
          return nil if twins.any? { |twin| (score = twin.score) && score >= 0 && twin.glued_punctuation == 0 }
        end
        @score
      end

      private def roman?(caseless_class : UInt8) : Bool
        caseless_class == 9 || caseless_class == 22 || caseless_class == 24 # I, V, X
      end

      protected def feed_bytes(buffer : Bytes) : Int64?
        score = 0_i64
        buffer.each do |b|
          klass = @data.classify(b)
          return nil if klass == 255
          caseless_class = klass & 0x7F

          ascii = b < 0x80
          ascii_pair = @prev_non_ascii == 0 && ascii

          score += case @prev_non_ascii
                   when 0, 1, 2 then 0_i64
                   when 3       then -5_i64
                   when 4       then -20_i64
                   else              -200_i64
                   end

          if !@data.latin_alphabetic?(caseless_class)
            @case_state = LatinCaseState::Space
          elsif (klass >> 7) == 0
            # Penalizing lower case after two upper case is important for
            # avoiding misdetecting windows-1250 as windows-1252 (byte 0x9F).
            score += IMPLAUSIBLE_LATIN_CASE_TRANSITION_PENALTY if @case_state.all_caps? && !ascii_pair
            @case_state = LatinCaseState::Lower
          else
            case @case_state
            when .space?
              @case_state = LatinCaseState::Upper
            when .upper?, .all_caps?
              @case_state = LatinCaseState::AllCaps
            when .lower?
              score += IMPLAUSIBLE_LATIN_CASE_TRANSITION_PENALTY unless ascii_pair
              @case_state = LatinCaseState::Upper
            end
          end

          # Treat pairing space-like, which can be non-ASCII, with ASCII as
          # ASCIIish enough not to get a score in order to avoid giving
          # ASCII i and I in windows-1254 next to windows-125x apostrophe/quote
          # a score. This avoids detecting English I’ as Turkish.
          ascii_ish_pair = ascii_pair || (ascii && @prev == 0) || (caseless_class == 0 && @prev_non_ascii == 0)
          score += @data.score(caseless_class, @prev, false) unless ascii_ish_pair

          score += step_ordinal(b, caseless_class) if @windows_1252

          letter = @data.latin_alphabetic?(caseless_class)
          @glued_punctuation += 1 if @punctuation_pending && letter
          @punctuation_pending = !ascii && caseless_class == 0 && b != 0x92 && @data.latin_alphabetic?(@prev)

          if @twins
            high_letter = !ascii && @data.latin_alphabetic?(caseless_class)
            if (high_letter && @prev == ASCII_DIGIT) || (@prev_high_letter && caseless_class == ASCII_DIGIT)
              score += IMPLAUSIBILITY_PENALTY
            end
            @prev_high_letter = high_letter
          end

          if ascii
            @prev_non_ascii = 0_i64
          else
            @prev_non_ascii += 1
          end
          @prev = caseless_class
        end
        score
      end

      # Scores Spanish/Italian ordinals (" º ", "n.º1", " 3ª ", " Xº ", ...)
      # and " © ", which pairwise scoring can't handle without hurting Romanian.
      private def step_ordinal(b : UInt8, caseless_class : UInt8) : Int64
        space = caseless_class == 0
        digit = caseless_class == ASCII_DIGIT
        case @ordinal_state
        in .other?
          @ordinal_state = OrdinalState::Space if space
        in .space?
          if space
            # pass
          elsif b == 0xAA || b == 0xBA
            @ordinal_state = OrdinalState::OrdinalExpectingSpace
          elsif b == 'M'.ord || b == 'D'.ord || b == 'S'.ord
            @ordinal_state = OrdinalState::FeminineAbbreviationStartLetter
          elsif b == 'N'.ord
            # numero or Nuestra
            @ordinal_state = OrdinalState::UpperN
          elsif b == 'n'.ord
            # numero
            @ordinal_state = OrdinalState::LowerN
          elsif digit
            @ordinal_state = OrdinalState::Digit
          elsif roman?(caseless_class)
            @ordinal_state = OrdinalState::Roman
          elsif b == 0xA9
            @ordinal_state = OrdinalState::Copyright
          else
            @ordinal_state = OrdinalState::Other
          end
        in .ordinal_expecting_space?
          @ordinal_state = space ? OrdinalState::Space : OrdinalState::Other
          return ORDINAL_BONUS if space
        in .ordinal_expecting_space_undo_implausibility?
          @ordinal_state = space ? OrdinalState::Space : OrdinalState::Other
          return ORDINAL_BONUS - IMPLAUSIBILITY_PENALTY if space
        in .ordinal_expecting_space_or_digit?
          # Deliberately `Other` after a digit
          @ordinal_state = space ? OrdinalState::Space : OrdinalState::Other
          return ORDINAL_BONUS if space || digit
        in .ordinal_expecting_space_or_digit_undo_implausibility?
          @ordinal_state = space ? OrdinalState::Space : OrdinalState::Other
          return ORDINAL_BONUS - IMPLAUSIBILITY_PENALTY if space || digit
        in .upper_n?
          @ordinal_state = if b == 0xAA
                             OrdinalState::OrdinalExpectingSpaceUndoImplausibility
                           elsif b == 0xBA
                             OrdinalState::OrdinalExpectingSpaceOrDigitUndoImplausibility
                           elsif b == '.'.ord
                             OrdinalState::PeriodAfterN
                           elsif space
                             OrdinalState::Space
                           else
                             OrdinalState::Other
                           end
        in .lower_n?
          @ordinal_state = if b == 0xBA
                             OrdinalState::OrdinalExpectingSpaceOrDigitUndoImplausibility
                           elsif b == '.'.ord
                             OrdinalState::PeriodAfterN
                           elsif space
                             OrdinalState::Space
                           else
                             OrdinalState::Other
                           end
        in .feminine_abbreviation_start_letter?
          @ordinal_state = if b == 0xAA
                             OrdinalState::OrdinalExpectingSpaceUndoImplausibility
                           elsif space
                             OrdinalState::Space
                           else
                             OrdinalState::Other
                           end
        in .digit?
          if b == 0xAA || b == 0xBA
            @ordinal_state = OrdinalState::OrdinalExpectingSpace
          elsif space
            @ordinal_state = OrdinalState::Space
          elsif !digit
            @ordinal_state = OrdinalState::Other
          end
        in .roman?
          if b == 0xAA || b == 0xBA
            @ordinal_state = OrdinalState::OrdinalExpectingSpaceUndoImplausibility
          elsif space
            @ordinal_state = OrdinalState::Space
          elsif !roman?(caseless_class)
            @ordinal_state = OrdinalState::Other
          end
        in .period_after_n?
          @ordinal_state = if b == 0xBA
                             OrdinalState::OrdinalExpectingSpaceOrDigit
                           elsif space
                             OrdinalState::Space
                           else
                             OrdinalState::Other
                           end
        in .copyright?
          @ordinal_state = space ? OrdinalState::Space : OrdinalState::Other
          return COPYRIGHT_BONUS if space
        end
        0_i64
      end
    end

    # windows-1256: Arabic with French case handling.
    # :nodoc:
    class ArabicFrenchCandidate < WordTrackingCandidate
      @case_state = LatinCaseState::Space

      protected def feed_bytes(buffer : Bytes) : Int64?
        score = 0_i64
        buffer.each do |b|
          klass = @data.classify(b)
          return nil if klass == 255
          caseless_class = klass & 0x7F

          ascii = b < 0x80
          ascii_pair = @prev_ascii && ascii

          if caseless_class != LATIN_LETTER
            # We compute case penalties for French only
            @case_state = LatinCaseState::Space
          elsif (klass >> 7) == 0
            score += IMPLAUSIBLE_LATIN_CASE_TRANSITION_PENALTY if @case_state.all_caps? && !ascii_pair
            @case_state = LatinCaseState::Lower
          else
            case @case_state
            when .space?
              @case_state = LatinCaseState::Upper
            when .upper?, .all_caps?
              @case_state = LatinCaseState::AllCaps
            when .lower?
              score += IMPLAUSIBLE_LATIN_CASE_TRANSITION_PENALTY unless ascii_pair
              @case_state = LatinCaseState::Upper
            end
          end

          # Count only Arabic word length and ignore French
          non_ascii_alphabetic = @data.non_latin_alphabetic?(caseless_class, true)
          track_word(non_ascii_alphabetic)

          unless ascii_pair
            score += @data.score(caseless_class, @prev, true)

            if @prev == LATIN_LETTER && non_ascii_alphabetic
              score += LATIN_ADJACENCY_PENALTY
            elsif caseless_class == LATIN_LETTER && @data.non_latin_alphabetic?(@prev, true)
              score += LATIN_ADJACENCY_PENALTY
            end
          end

          @prev_ascii = ascii
          @prev = caseless_class
        end
        score
      end
    end

    # Thai and ISO-8859-6 Arabic.
    # :nodoc:
    class CaselessCandidate < WordTrackingCandidate
      protected def feed_bytes(buffer : Bytes) : Int64?
        score = 0_i64
        buffer.each do |b|
          klass = @data.classify(b)
          return nil if klass == 255
          caseless_class = klass & 0x7F

          ascii = b < 0x80
          ascii_pair = @prev_ascii && ascii

          non_ascii_alphabetic = @data.non_latin_alphabetic?(caseless_class, false)
          track_word(non_ascii_alphabetic)

          unless ascii_pair
            score += @data.score(caseless_class, @prev, false)

            if @prev == LATIN_LETTER && non_ascii_alphabetic
              score += LATIN_ADJACENCY_PENALTY
            elsif caseless_class == LATIN_LETTER && @data.non_latin_alphabetic?(@prev, false)
              score += LATIN_ADJACENCY_PENALTY
            end
          end

          @prev_ascii = ascii
          @prev = caseless_class
        end
        score
      end
    end

    # :nodoc:
    def self.ascii_punctuation?(byte : UInt8) : Bool
      byte.in?('.'.ord, ','.ord, ':'.ord, ';'.ord, '?'.ord, '!'.ord)
    end

    # Logical-order Hebrew (windows-1255).
    # :nodoc:
    class LogicalCandidate < WordTrackingCandidate
      getter plausible_punctuation = 0_i64

      protected def feed_bytes(buffer : Bytes) : Int64?
        score = 0_i64
        buffer.each do |b|
          klass = @data.classify(b)
          return nil if klass == 255
          caseless_class = klass & 0x7F

          ascii = b < 0x80
          ascii_pair = @prev_ascii && ascii

          non_ascii_alphabetic = @data.non_latin_alphabetic?(caseless_class, false)
          track_word(non_ascii_alphabetic)

          unless ascii_pair
            score += @data.score(caseless_class, @prev, false)

            prev_non_ascii_alphabetic = @data.non_latin_alphabetic?(@prev, false)
            if caseless_class == 0 && prev_non_ascii_alphabetic && Chardetng.ascii_punctuation?(b)
              @plausible_punctuation += 1
            end

            if @prev == LATIN_LETTER && non_ascii_alphabetic
              score += LATIN_ADJACENCY_PENALTY
            elsif caseless_class == LATIN_LETTER && prev_non_ascii_alphabetic
              score += LATIN_ADJACENCY_PENALTY
            end
          end

          @prev_ascii = ascii
          @prev = caseless_class
        end
        score
      end
    end

    # Visual-order Hebrew (ISO-8859-8).
    # :nodoc:
    class VisualCandidate < WordTrackingCandidate
      getter plausible_punctuation = 0_i64
      @prev_punctuation = false

      protected def feed_bytes(buffer : Bytes) : Int64?
        score = 0_i64
        buffer.each do |b|
          klass = @data.classify(b)
          return nil if klass == 255
          caseless_class = klass & 0x7F

          ascii = b < 0x80
          ascii_pair = @prev_ascii && ascii

          non_ascii_alphabetic = @data.non_latin_alphabetic?(caseless_class, false)
          track_word(non_ascii_alphabetic)

          unless ascii_pair
            score += @data.score(caseless_class, @prev, false)

            @plausible_punctuation += 1 if non_ascii_alphabetic && @prev_punctuation

            if @prev == LATIN_LETTER && non_ascii_alphabetic
              score += LATIN_ADJACENCY_PENALTY
            elsif caseless_class == LATIN_LETTER && @data.non_latin_alphabetic?(@prev, false)
              score += LATIN_ADJACENCY_PENALTY
            end
          end

          @prev_ascii = ascii
          @prev = caseless_class
          @prev_punctuation = caseless_class == 0 && Chardetng.ascii_punctuation?(b)
        end
        score
      end
    end

    # Incremental UTF-8 validator (WHATWG / encoding_rs rules: no overlongs,
    # surrogates or code points above U+10FFFF; truncation at EOF is malformed).
    # :nodoc:
    class Utf8Candidate < Candidate
      @need = 0
      @lower = 0x80_u8
      @upper = 0xBF_u8

      def encoding : String
        "UTF-8"
      end

      protected def feed_inner(buffer : Bytes, last : Bool) : Int64?
        buffer.each do |b|
          if @need == 0
            next if b < 0x80
            case b
            when 0xC2..0xDF             then @need = 1
            when 0xE0                   then @need = 2; @lower = 0xA0_u8
            when 0xE1..0xEC, 0xEE..0xEF then @need = 2
            when 0xED                   then @need = 2; @upper = 0x9F_u8
            when 0xF0                   then @need = 3; @lower = 0x90_u8
            when 0xF1..0xF3             then @need = 3
            when 0xF4                   then @need = 3; @upper = 0x8F_u8
            else                             return nil
            end
          else
            return nil unless @lower <= b <= @upper
            @lower = 0x80_u8
            @upper = 0xBF_u8
            @need -= 1
          end
        end
        last && @need > 0 ? nil : 0_i64
      end
    end

    # Streaming detector: call `#feed` with consecutive chunks (the final one
    # with `last: true`), then `#guess`.
    #
    # With `extended: true`, Fathom's derived candidates join the upstream ones:
    # KOI8-R right before KOI8-U (so plain Russian ties go to KOI8-R), and
    # MACINTOSH, IBM850, IBM437, IBM852 and X-MAC-CYRILLIC last (so they never
    # win a tie against an upstream encoding). The Latin ones also yield whenever
    # windows-1252, windows-1250 or ISO-8859-2 scores zero or more, and all of
    # them start `RARE_HANDICAP` behind.
    #
    # ```
    # detector = Fathom::Chardetng::Detector.new
    # detector.feed(bytes, last: true)
    # detector.guess # => "WINDOWS-1252"
    # ```
    class Detector
      # Prior against the rare extension encodings, so short ambiguous input
      # stays with the common ones (Fathom extension).
      RARE_HANDICAP = 100_i64

      @utf8 = Utf8Candidate.new
      @visual = VisualCandidate.new(ISO_8859_8_DATA)
      @logical = LogicalCandidate.new(WINDOWS_1255_DATA)
      # Upstream candidate order (minus CJK); ties go to the earlier candidate.
      @normal : Array(Candidate)
      @non_ascii_seen = 0_i64
      @esc_seen = false
      @closed = false
      # Up to two bytes of context before the first non-ASCII byte (for Spanish "n.º").
      @before = StaticArray(UInt8, 2).new(0_u8)
      @before_len = 0

      # Number of non-ASCII bytes fed so far.
      getter non_ascii_seen : Int64

      def initialize(extended : Bool = false)
        @normal = [
          LatinCandidate.new(WINDOWS_1252_DATA, windows_1252: true),
          NonLatinCasedCandidate.new(WINDOWS_1251_DATA),
          LatinCandidate.new(WINDOWS_1250_DATA),
          LatinCandidate.new(ISO_8859_2_DATA),
          ArabicFrenchCandidate.new(WINDOWS_1256_DATA),
          LatinCandidate.new(WINDOWS_1252_ICELANDIC_DATA),
          LatinCandidate.new(WINDOWS_1254_DATA),
          CaselessCandidate.new(WINDOWS_874_DATA),
          @logical,
          NonLatinCasedCandidate.new(WINDOWS_1253_DATA),
          NonLatinCasedCandidate.new(ISO_8859_7_DATA),
          LatinCandidate.new(WINDOWS_1257_DATA),
          LatinCandidate.new(ISO_8859_13_DATA),
          NonLatinCasedCandidate.new(KOI8_U_DATA),
          NonLatinCasedCandidate.new(IBM866_DATA),
          CaselessCandidate.new(ISO_8859_6_DATA),
          LatinCandidate.new(WINDOWS_1258_DATA),
          LatinCandidate.new(ISO_8859_4_DATA),
          NonLatinCasedCandidate.new(ISO_8859_5_DATA),
        ] of Candidate
        if extended
          latin = [@normal[0], @normal[2], @normal[3]].map(&.as(LatinCandidate)) # windows-1252, windows-1250, ISO-8859-2
          @normal.insert(@normal.index!(&.encoding.==("KOI8-U")), NonLatinCasedCandidate.new(KOI8_R_DATA))
          rare = [
            LatinCandidate.new(MACINTOSH_DATA, twins: latin),
            LatinCandidate.new(IBM850_DATA, twins: latin),
            LatinCandidate.new(IBM437_DATA, twins: latin),
            LatinCandidate.new(IBM852_DATA, twins: latin),
            NonLatinCasedCandidate.new(X_MAC_CYRILLIC_DATA),
          ] of Candidate
          rare.each(&.handicap=(RARE_HANDICAP))
          @normal.concat(rare)
        end
      end

      # Feeds the next chunk of the stream. Returns `true` once any non-ASCII
      # byte has been seen. Must not be called again after `last: true`.
      def feed(buffer : Bytes, last : Bool) : Bool
        raise ArgumentError.new("Must not feed again after feeding with last equaling true.") if @closed
        @closed = true if last

        start = 0
        if @non_ascii_seen == 0 && !@esc_seen
          up_to = buffer.index { |b| b >= 0x80 } || buffer.size
          if escape = buffer[0, up_to].index(0x1B_u8)
            @esc_seen = true
            start = escape
          else
            start = up_to
          end
          if start == buffer.size
            push_before(buffer)
            return @non_ascii_seen != 0
          end
          if start <= 1
            before = @before
            before_len = @before_len
            @before_len = 0
            feed_all(before.to_slice[0, before_len], false)
            start = 0
          else
            start -= 2
          end
        end
        feed_all(buffer[start..], last)
        @non_ascii_seen != 0
      end

      # Returns the guessed encoding name for the bytes fed so far.
      def guess : String
        result[0]
      end

      # Returns the guessed encoding and its score (`0` when no candidate scored
      # above zero and the guess is the windows-1252 default, or for UTF-8).
      def result : {String, Int64}
        return {"UTF-8", 0_i64} if @utf8.score

        encoding = WINDOWS_1252_DATA.encoding
        max = 0_i64
        @normal.each do |candidate|
          if (score = candidate.guess_score) && score > max
            max = score
            encoding = candidate.encoding
          end
        end
        if (visual_score = @visual.guess_score) &&
           (visual_score > max || encoding == WINDOWS_1255_DATA.encoding) &&
           @visual.plausible_punctuation > @logical.plausible_punctuation
          encoding = ISO_8859_8_DATA.encoding
          max = visual_score
        end
        {encoding, max}
      end

      # Yields each still-qualified single-byte candidate's encoding and score
      # (windows-1252 may be yielded twice: generic and Icelandic tables).
      def each_score(& : String, Int64 ->) : Nil
        @normal.each do |candidate|
          if score = candidate.guess_score
            yield candidate.encoding, score
          end
        end
        if score = @visual.guess_score
          yield ISO_8859_8_DATA.encoding, score
        end
      end

      private def feed_all(buffer : Bytes, last : Bool) : Nil
        @utf8.feed(buffer, last)
        @visual.feed(buffer, last)
        @normal.each(&.feed(buffer, last))
        @non_ascii_seen += buffer.count { |b| b >= 0x80 }
      end

      private def push_before(buffer : Bytes) : Nil
        if buffer.size >= 2
          @before[0] = buffer[-2]
          @before[1] = buffer[-1]
          @before_len = 2
        elsif buffer.size == 1
          case @before_len
          when 0
            @before[0] = buffer[0]
            @before_len = 1
          when 1
            @before[1] = buffer[0]
            @before_len = 2
          else
            @before[0] = @before[1]
            @before[1] = buffer[0]
          end
        end
      end
    end

    # Guesses the encoding of a complete byte sequence.
    def self.guess(bytes : Bytes) : String
      detector = Detector.new
      detector.feed(bytes, last: true)
      detector.guess
    end
  end
end
