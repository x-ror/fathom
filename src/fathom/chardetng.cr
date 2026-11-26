# Port of chardetng 1.0.0 (https://github.com/hsivonen/chardetng) to Crystal.
#
# Copyright Mozilla Foundation. chardetng is licensed under the Apache License,
# Version 2.0 or the MIT license, at your option; this port uses it under the
# MIT license, whose full text is in LICENSE-chardetng at the repository root.
# Tables in `chardetng/data.cr` are CC0.
#
# The CJK and ISO-2022-JP candidates are in `chardetng/cjk.cr`. Deliberately
# omitted relative to upstream: top-level-domain hints. `guess` behaves like
# upstream `guess(None, Utf8Detection::Allow)` with ISO-2022-JP allowed.
require "./chardetng/data"
require "./chardetng/cjk"

module Fathom
  module Chardetng
    private LATIN_ADJACENCY_PENALTY                   =  -50_i64
    private IMPLAUSIBILITY_PENALTY                    = -220_i64
    private ORDINAL_BONUS                             =  300_i64
    private COPYRIGHT_BONUS                           =  222_i64
    private IMPLAUSIBLE_LATIN_CASE_TRANSITION_PENALTY = -180_i64
    # Fathom extension: extra penalty for the rare Latin encodings when a
    # non-ASCII capital follows a lowercase letter ("aragonÉs", "bactÄrias"),
    # the signature of reading Mac Roman as CP850 or the other way round.
    private RARE_CASE_TRANSITION_PENALTY   = -220_i64
    private NON_LATIN_CAPITALIZATION_BONUS =   40_i64
    private NON_LATIN_ALL_CAPS_PENALTY     =  -40_i64
    private NON_LATIN_MIXED_CASE_PENALTY   =  -20_i64

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
    class SingleByteData
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

      @[AlwaysInline]
      def score(current_class : UInt8, previous_class : UInt8, windows_1256 : Bool) : Int64
        current = current_class.to_i32
        previous = previous_class.to_i32
        stored_boundary = @ascii + @non_ascii
        if current < stored_boundary
          if previous < stored_boundary
            # Both below
            if index = compute_index(previous, current)
              b = @probabilities.unsafe_fetch(index)
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

    private enum LatinCaseState : UInt8
      Space
      Upper
      Lower
      AllCaps
    end

    private enum NonLatinCaseState : UInt8
      Space
      Upper
      Lower
      UpperLower
      AllCaps
      Mix
    end

    private enum OrdinalState : UInt8
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

    private enum CandidateKind : UInt8
      Latin
      NonLatinCased
      ArabicFrench
      Caseless
      Logical
      Visual
    end

    # :nodoc:
    protected def self.ascii_punctuation?(byte : UInt8) : Bool
      byte.in?('.'.ord, ','.ord, ':'.ord, ';'.ord, '?'.ord, '!'.ord)
    end

    # Value-type single-byte candidate with a running score; `nil` score means disqualified.
    # :nodoc:
    struct Candidate
      getter score : Int64? = 0_i64

      # Prior against this candidate, subtracted from its final score (Fathom extension).
      property handicap : Int64

      # Non-ASCII space-like bytes other than the apostrophe 0x92 found between
      # two letters ("acci—n"). Doesn't affect the score; a twin with any of
      # these doesn't read the input plausibly (Fathom extension).
      getter glued_punctuation = 0

      getter plausible_punctuation = 0_i64

      @prev = 0_u8
      @prev_ascii = true
      @current_word_len = 0_i64
      @longest_word = 0_i64
      @non_latin_case_state = NonLatinCaseState::Space
      @prev_was_a0 = false
      @ibm866 : Bool
      @koi8_u : Bool
      @latin_case_state = LatinCaseState::Space
      @prev_non_ascii = 0_i64
      @ordinal_state = OrdinalState::Space
      @prev_high_letter = false
      @punctuation_pending = false
      @prev_punctuation = false

      def initialize(
        @kind : CandidateKind,
        @data : SingleByteData,
        @windows_1252 : Bool = false,
        @has_twins : Bool = false,
        @handicap : Int64 = 0_i64,
      )
        @ibm866 = @kind.non_latin_cased? && @data.encoding == "IBM866"
        # KOI8-R shares KOI8-U's inverted case layout (Fathom extension).
        @koi8_u = @kind.non_latin_cased? && @data.encoding.in?("KOI8-U", "KOI8-R")
      end

      def self.latin(data : SingleByteData, windows_1252 : Bool = false, has_twins : Bool = false, handicap : Int64 = 0_i64) : Candidate
        new(CandidateKind::Latin, data, windows_1252: windows_1252, has_twins: has_twins, handicap: handicap)
      end

      def self.non_latin_cased(data : SingleByteData, handicap : Int64 = 0_i64) : Candidate
        new(CandidateKind::NonLatinCased, data, handicap: handicap)
      end

      def self.arabic_french(data : SingleByteData) : Candidate
        new(CandidateKind::ArabicFrench, data)
      end

      def self.caseless(data : SingleByteData) : Candidate
        new(CandidateKind::Caseless, data)
      end

      def self.logical(data : SingleByteData) : Candidate
        new(CandidateKind::Logical, data)
      end

      def self.visual(data : SingleByteData) : Candidate
        new(CandidateKind::Visual, data)
      end

      def encoding : String
        @data.encoding
      end

      def plausible_twin? : Bool
        (score = @score) ? score >= 0 && @glued_punctuation == 0 : false
      end

      # Score as seen by `Detector#guess` (upstream `Candidate::score` with a generic TLD).
      def guess_score(latin_twin_plausible : Bool = false) : Int64?
        (score = qualified_score(latin_twin_plausible)) ? score - @handicap : nil
      end

      def qualified_score(latin_twin_plausible : Bool = false) : Int64?
        if @kind.latin?
          return nil if @has_twins && latin_twin_plausible
          @score
        else
          @longest_word < 2 ? nil : @score
        end
      end

      def feed(buffer : Bytes, last : Bool) : Nil
        return unless old = @score
        delta = feed_bytes(buffer) || begin
          @score = nil
          return
        end
        if last
          # Treat EOF as space-like
          tail = feed_bytes(SPACE) || begin
            @score = nil
            return
          end
          delta += tail
        end
        @score = old + delta
      end

      private def feed_bytes(buffer : Bytes) : Int64?
        case @kind
        in .latin?           then feed_latin(buffer)
        in .non_latin_cased? then feed_non_latin_cased(buffer)
        in .arabic_french?   then feed_arabic_french(buffer)
        in .caseless?        then feed_caseless(buffer)
        in .logical?         then feed_logical(buffer)
        in .visual?          then feed_visual(buffer)
        end
      end

      @[AlwaysInline]
      private def track_word(non_ascii_alphabetic : Bool) : Nil
        if non_ascii_alphabetic
          @current_word_len += 1
        else
          @longest_word = @current_word_len if @current_word_len > @longest_word
          @current_word_len = 0_i64
        end
      end

      @[AlwaysInline]
      private def latin_adjacency_penalty(caseless_class : UInt8, non_ascii_alphabetic : Bool, prev_non_ascii_alphabetic : Bool) : Int64
        if (@prev == LATIN_LETTER && non_ascii_alphabetic) || (caseless_class == LATIN_LETTER && prev_non_ascii_alphabetic)
          LATIN_ADJACENCY_PENALTY
        else
          0_i64
        end
      end

      @[AlwaysInline]
      private def step_latin_case(klass : UInt8, ascii_pair : Bool, ascii : Bool) : Int64
        if (klass >> 7) == 0
          penalty = @latin_case_state.all_caps? && !ascii_pair ? IMPLAUSIBLE_LATIN_CASE_TRANSITION_PENALTY : 0_i64
          @latin_case_state = LatinCaseState::Lower
          penalty
        else
          case @latin_case_state
          in .space?
            @latin_case_state = LatinCaseState::Upper
            0_i64
          in .upper?, .all_caps?
            @latin_case_state = LatinCaseState::AllCaps
            0_i64
          in .lower?
            @latin_case_state = LatinCaseState::Upper
            penalty = ascii_pair ? 0_i64 : IMPLAUSIBLE_LATIN_CASE_TRANSITION_PENALTY
            penalty += RARE_CASE_TRANSITION_PENALTY if @has_twins && !ascii
            penalty
          end
        end
      end

      # Cyrillic and Greek.
      private def feed_non_latin_cased(buffer : Bytes) : Int64?
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
            @non_latin_case_state = NonLatinCaseState::Mix
          elsif !non_ascii_alphabetic
            # Space
            case @non_latin_case_state
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
            @non_latin_case_state = NonLatinCaseState::Space
          elsif (klass >> 7) == 0
            # Lower case
            case @non_latin_case_state
            when .space?    then @non_latin_case_state = NonLatinCaseState::Lower
            when .upper?    then @non_latin_case_state = NonLatinCaseState::UpperLower
            when .all_caps? then @non_latin_case_state = NonLatinCaseState::Mix
            else
            end
          else
            # Upper case
            case @non_latin_case_state
            when .space?                then @non_latin_case_state = NonLatinCaseState::Upper
            when .upper?                then @non_latin_case_state = NonLatinCaseState::AllCaps
            when .lower?, .upper_lower? then @non_latin_case_state = NonLatinCaseState::Mix
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

            score += latin_adjacency_penalty(caseless_class, non_ascii_alphabetic, @data.non_latin_alphabetic?(@prev, false))
          end

          @prev_ascii = ascii
          @prev = caseless_class
          @prev_was_a0 = is_a0
        end
        score
      end

      private def roman?(caseless_class : UInt8) : Bool
        caseless_class == 9 || caseless_class == 22 || caseless_class == 24 # I, V, X
      end

      private def feed_latin(buffer : Bytes) : Int64?
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

          letter = @data.latin_alphabetic?(caseless_class)
          if !letter
            @latin_case_state = LatinCaseState::Space
          else
            # Penalizing lower case after two upper case is important for
            # avoiding misdetecting windows-1250 as windows-1252 (byte 0x9F).
            score += step_latin_case(klass, ascii_pair, ascii)
          end

          # Treat pairing space-like, which can be non-ASCII, with ASCII as
          # ASCIIish enough not to get a score in order to avoid giving
          # ASCII i and I in windows-1254 next to windows-125x apostrophe/quote
          # a score. This avoids detecting English I’ as Turkish.
          ascii_ish_pair = ascii_pair || (ascii && @prev == 0) || (caseless_class == 0 && @prev_non_ascii == 0)
          score += @data.score(caseless_class, @prev, false) unless ascii_ish_pair

          score += step_ordinal(b, caseless_class) if @windows_1252

          @glued_punctuation += 1 if @punctuation_pending && letter
          @punctuation_pending = !ascii && caseless_class == 0 && b != 0x92 && @data.latin_alphabetic?(@prev)

          if @has_twins
            high_letter = !ascii && letter
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

      # windows-1256: Arabic with French case handling.
      private def feed_arabic_french(buffer : Bytes) : Int64?
        score = 0_i64
        buffer.each do |b|
          klass = @data.classify(b)
          return nil if klass == 255
          caseless_class = klass & 0x7F

          ascii = b < 0x80
          ascii_pair = @prev_ascii && ascii

          if caseless_class != LATIN_LETTER
            # We compute case penalties for French only
            @latin_case_state = LatinCaseState::Space
          else
            score += step_latin_case(klass, ascii_pair, ascii)
          end

          # Count only Arabic word length and ignore French
          non_ascii_alphabetic = @data.non_latin_alphabetic?(caseless_class, true)
          track_word(non_ascii_alphabetic)

          unless ascii_pair
            score += @data.score(caseless_class, @prev, true)
            score += latin_adjacency_penalty(caseless_class, non_ascii_alphabetic, @data.non_latin_alphabetic?(@prev, true))
          end

          @prev_ascii = ascii
          @prev = caseless_class
        end
        score
      end

      # Thai and ISO-8859-6 Arabic.
      private def feed_caseless(buffer : Bytes) : Int64?
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
            score += latin_adjacency_penalty(caseless_class, non_ascii_alphabetic, @data.non_latin_alphabetic?(@prev, false))
          end

          @prev_ascii = ascii
          @prev = caseless_class
        end
        score
      end

      # Logical-order Hebrew (windows-1255).
      private def feed_logical(buffer : Bytes) : Int64?
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

            score += latin_adjacency_penalty(caseless_class, non_ascii_alphabetic, prev_non_ascii_alphabetic)
          end

          @prev_ascii = ascii
          @prev = caseless_class
        end
        score
      end

      # Visual-order Hebrew (ISO-8859-8).
      private def feed_visual(buffer : Bytes) : Int64?
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

            score += latin_adjacency_penalty(caseless_class, non_ascii_alphabetic, @data.non_latin_alphabetic?(@prev, false))
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
    struct Utf8Candidate
      getter score : Int64? = 0_i64
      @need = 0
      @lower = 0x80_u8
      @upper = 0xBF_u8

      def encoding : String
        "UTF-8"
      end

      def feed(buffer : Bytes, last : Bool) : Nil
        return unless @score
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
            else
              @score = nil
              return
            end
          else
            unless @lower <= b <= @upper
              @score = nil
              return
            end
            @lower = 0x80_u8
            @upper = 0xBF_u8
            @need -= 1
          end
        end
        @score = nil if last && @need > 0
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
    #
    # NOTE: `Detector` is a value type (so detection doesn't allocate). Keep it
    # in a local variable: a copy passed to a method or stored elsewhere has its
    # own state, and feeding the copy doesn't update the original.
    # :nodoc:
    struct Detector
      # Prior against the rare extension encodings, so short ambiguous input
      # stays with the common ones (Fathom extension).
      RARE_HANDICAP = 100_i64

      # Capacity of `@normal`: the single-byte candidates (upstream's, plus Fathom's
      # extensions). The UTF-8, ISO-2022-JP, visual Hebrew and CJK candidates are
      # separate fields.
      CAPACITY = 25

      # Most entries `#each_score` can yield: every single-byte candidate, visual
      # Hebrew and the five CJK candidates (`CAPACITY + 6`, spelled out because
      # it's used as a type argument).
      MAX_SCORES = 31

      private WIN1252_IDX  = 0
      private WIN1250_IDX  = 2
      private ISO88592_IDX = 3
      private LOGICAL_IDX  = 8

      @utf8 = Utf8Candidate.new
      @iso2022 = Iso2022Candidate.new
      @visual = Candidate.visual(ISO_8859_8_DATA)
      # CJK candidates, in upstream order (they precede the single-byte ones).
      @gbk = GbkCandidate.new
      @euc_jp = EucJpCandidate.new
      @euc_kr = EucKrCandidate.new
      @shift_jis = ShiftJisCandidate.new
      @big5 = Big5Candidate.new
      # Upstream candidate order (minus CJK); ties go to the earlier candidate.
      @normal : StaticArray(Candidate, Detector::CAPACITY)
      @normal_len : Int32
      @non_ascii_seen = 0_i64
      @esc_seen = false
      @closed = false
      # Up to two bytes of context before the first non-ASCII byte (for Spanish "n.º").
      @before = StaticArray(UInt8, 2).new(0_u8)
      @before_len = 0

      # Number of non-ASCII bytes fed so far.
      getter non_ascii_seen : Int64

      def initialize(extended : Bool = false)
        @normal = uninitialized StaticArray(Candidate, Detector::CAPACITY)
        n = @normal.to_unsafe
        n[0] = Candidate.latin(WINDOWS_1252_DATA, windows_1252: true)
        n[1] = Candidate.non_latin_cased(WINDOWS_1251_DATA)
        n[2] = Candidate.latin(WINDOWS_1250_DATA)
        n[3] = Candidate.latin(ISO_8859_2_DATA)
        n[4] = Candidate.arabic_french(WINDOWS_1256_DATA)
        n[5] = Candidate.latin(WINDOWS_1252_ICELANDIC_DATA)
        n[6] = Candidate.latin(WINDOWS_1254_DATA)
        n[7] = Candidate.caseless(WINDOWS_874_DATA)
        n[8] = Candidate.logical(WINDOWS_1255_DATA)
        n[9] = Candidate.non_latin_cased(WINDOWS_1253_DATA)
        n[10] = Candidate.non_latin_cased(ISO_8859_7_DATA)
        n[11] = Candidate.latin(WINDOWS_1257_DATA)
        n[12] = Candidate.latin(ISO_8859_13_DATA)
        if extended
          n[13] = Candidate.non_latin_cased(KOI8_R_DATA)
          n[14] = Candidate.non_latin_cased(KOI8_U_DATA)
          n[15] = Candidate.non_latin_cased(IBM866_DATA)
          n[16] = Candidate.caseless(ISO_8859_6_DATA)
          n[17] = Candidate.latin(WINDOWS_1258_DATA)
          n[18] = Candidate.latin(ISO_8859_4_DATA)
          n[19] = Candidate.non_latin_cased(ISO_8859_5_DATA)
          n[20] = Candidate.latin(MACINTOSH_DATA, has_twins: true, handicap: RARE_HANDICAP)
          n[21] = Candidate.latin(IBM850_DATA, has_twins: true, handicap: RARE_HANDICAP)
          n[22] = Candidate.latin(IBM437_DATA, has_twins: true, handicap: RARE_HANDICAP)
          n[23] = Candidate.latin(IBM852_DATA, has_twins: true, handicap: RARE_HANDICAP)
          n[24] = Candidate.non_latin_cased(X_MAC_CYRILLIC_DATA, handicap: RARE_HANDICAP)
          @normal_len = 25
        else
          n[13] = Candidate.non_latin_cased(KOI8_U_DATA)
          n[14] = Candidate.non_latin_cased(IBM866_DATA)
          n[15] = Candidate.caseless(ISO_8859_6_DATA)
          n[16] = Candidate.latin(WINDOWS_1258_DATA)
          n[17] = Candidate.latin(ISO_8859_4_DATA)
          n[18] = Candidate.non_latin_cased(ISO_8859_5_DATA)
          (n + 19).clear(6)
          @normal_len = 19
        end
        if extended
          @gbk.lenient_eof = true
          @euc_jp.lenient_eof = true
          @euc_kr.lenient_eof = true
          @shift_jis.lenient_eof = true
          @big5.lenient_eof = true
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
      # above zero and the guess is the windows-1252 default, or for UTF-8 and
      # ISO-2022-JP).
      def result : {String, Int64}
        return {@iso2022.encoding, 0_i64} if @non_ascii_seen == 0 && @esc_seen && @iso2022.score
        return {"UTF-8", 0_i64} if @utf8.score

        twin_plausible = latin_twin_plausible?
        encoding = WINDOWS_1252_DATA.encoding
        max = 0_i64
        cjk_scores.each do |(name, score)|
          if score && score > max
            max = score
            encoding = name
          end
        end
        ptr = @normal.to_unsafe
        i = 0
        while i < @normal_len
          if (score = (ptr + i).value.guess_score(twin_plausible)) && score > max
            max = score
            encoding = (ptr + i).value.encoding
          end
          i += 1
        end
        if (visual_score = @visual.guess_score(twin_plausible)) &&
           (visual_score > max || encoding == WINDOWS_1255_DATA.encoding) &&
           @visual.plausible_punctuation > (ptr + LOGICAL_IDX).value.plausible_punctuation
          encoding = ISO_8859_8_DATA.encoding
          max = visual_score
        end
        {encoding, max}
      end

      # Yields each still-qualified CJK and single-byte candidate's encoding and
      # score (windows-1252 may be yielded twice: generic and Icelandic tables).
      def each_score(& : String, Int64 ->) : Nil
        cjk_scores.each do |(name, score)|
          yield name, score if score
        end
        twin_plausible = latin_twin_plausible?
        ptr = @normal.to_unsafe
        i = 0
        while i < @normal_len
          if score = (ptr + i).value.guess_score(twin_plausible)
            yield (ptr + i).value.encoding, score
          end
          i += 1
        end
        if score = @visual.guess_score(twin_plausible)
          yield ISO_8859_8_DATA.encoding, score
        end
      end

      # CJK encodings and scores in upstream candidate order.
      # A candidate whose last character was cut by the end of the input (only
      # possible with `extended`) yields to one that decodes the whole input with
      # a positive score: 35 bytes of half-width katakana are valid Shift_JIS but
      # read as Big5 pairs with a dangling lead byte.
      private def cjk_scores : StaticArray({String, Int64?}, 5)
        complete = {@gbk, @euc_jp, @euc_kr, @shift_jis, @big5}.any? do |c|
          (score = c.guess_score) && score > 0 && !c.cut_tail?
        end
        StaticArray[
          cjk_score(@gbk, complete),
          cjk_score(@euc_jp, complete),
          cjk_score(@euc_kr, complete),
          cjk_score(@shift_jis, complete),
          cjk_score(@big5, complete),
        ]
      end

      private def cjk_score(candidate, complete : Bool) : {String, Int64?}
        {candidate.encoding, complete && candidate.cut_tail? ? nil : candidate.guess_score}
      end

      # Whether every byte fed so far is defined in windows-1255.
      def windows_1255_decodable? : Bool
        !(@normal.to_unsafe + LOGICAL_IDX).value.score.nil?
      end

      @[AlwaysInline]
      private def latin_twin_plausible? : Bool
        ptr = @normal.to_unsafe
        (ptr + WIN1252_IDX).value.plausible_twin? ||
          (ptr + WIN1250_IDX).value.plausible_twin? ||
          (ptr + ISO88592_IDX).value.plausible_twin?
      end

      private def feed_all(buffer : Bytes, last : Bool) : Nil
        @utf8.feed(buffer, last)
        @iso2022.feed(buffer, last)
        @gbk.feed(buffer, last)
        @euc_jp.feed(buffer, last)
        @euc_kr.feed(buffer, last)
        @shift_jis.feed(buffer, last)
        @big5.feed(buffer, last)
        @visual.feed(buffer, last)
        ptr = @normal.to_unsafe
        i = 0
        while i < @normal_len
          (ptr + i).value.feed(buffer, last)
          i += 1
        end

        buf_ptr = buffer.to_unsafe
        buf_size = buffer.size
        non_ascii = 0_i64
        j = 0
        while j < buf_size
          non_ascii += 1 if buf_ptr[j] >= 0x80_u8
          j += 1
        end
        @non_ascii_seen += non_ascii
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
