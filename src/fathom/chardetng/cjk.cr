# CJK and ISO-2022-JP candidates of chardetng 1.0.0, ported to Crystal over the
# decoders in `src/fathom/whatwg/decoders.cr` (which reproduce encoding_rs one
# byte at a time, as these candidates drive them).
#
# Copyright Mozilla Foundation. Used under the MIT license (LICENSE-chardetng).
require "../whatwg/decoders"

module Fathom
  module Chardetng
    # Manually calibrated relative to windows-1256 Arabic
    private CJK_BASE_SCORE                                = 41_i64
    private CJK_SECONDARY_BASE_SCORE                      = 20_i64
    private SHIFT_JIS_SCORE_PER_KANA                      = 20_i64
    private SHIFT_JIS_SCORE_PER_LEVEL_1_KANJI             = CJK_BASE_SCORE
    private SHIFT_JIS_SCORE_PER_LEVEL_2_KANJI             = CJK_SECONDARY_BASE_SCORE
    private SHIFT_JIS_INITIAL_HALF_WIDTH_KATAKANA_PENALTY = -75_i64
    private HALF_WIDTH_KATAKANA_SCORE                     =   1_i64
    private HALF_WIDTH_KATAKANA_VOICING_SCORE             =  10_i64
    private SHIFT_JIS_PUA_PENALTY                         = -(CJK_BASE_SCORE * 10)
    private SHIFT_JIS_EXTENSION_PENALTY                   = SHIFT_JIS_PUA_PENALTY * 2
    private SHIFT_JIS_SINGLE_BYTE_EXTENSION_PENALTY       = SHIFT_JIS_EXTENSION_PENALTY
    private EUC_JP_SCORE_PER_KANA                         = CJK_BASE_SCORE + (CJK_BASE_SCORE // 3)
    private EUC_JP_SCORE_PER_NEAR_OBSOLETE_KANA           = CJK_BASE_SCORE - 1
    private EUC_JP_SCORE_PER_LEVEL_1_KANJI                = CJK_BASE_SCORE
    private EUC_JP_SCORE_PER_LEVEL_2_KANJI                = CJK_SECONDARY_BASE_SCORE
    private EUC_JP_SCORE_PER_OTHER_KANJI                  = CJK_SECONDARY_BASE_SCORE // 4
    private EUC_JP_INITIAL_KANA_PENALTY                   = -((CJK_BASE_SCORE // 3) + 1)
    private EUC_JP_EXTENSION_PENALTY                      = -(CJK_BASE_SCORE * 50)
    private BIG5_SCORE_PER_LEVEL_1_HANZI                  = CJK_BASE_SCORE
    private BIG5_SCORE_PER_OTHER_HANZI                    = CJK_SECONDARY_BASE_SCORE
    private BIG5_PUA_PENALTY                              = -(CJK_BASE_SCORE * 30)
    private BIG5_SINGLE_BYTE_EXTENSION_PENALTY            = -(CJK_BASE_SCORE * 40)
    private EUC_KR_SCORE_PER_EUC_HANGUL                   = CJK_BASE_SCORE + 1
    private EUC_KR_SCORE_PER_NON_EUC_HANGUL               = CJK_SECONDARY_BASE_SCORE // 5
    private EUC_KR_SCORE_PER_HANJA                        = CJK_SECONDARY_BASE_SCORE // 2
    private EUC_KR_HANJA_AFTER_HANGUL_PENALTY             = -(CJK_BASE_SCORE * 10)
    private EUC_KR_LONG_WORD_PENALTY                      = -6_i64
    private GBK_SCORE_PER_LEVEL_1                         = CJK_BASE_SCORE
    private GBK_SCORE_PER_LEVEL_2                         = CJK_SECONDARY_BASE_SCORE
    private GBK_SCORE_PER_NON_EUC                         = CJK_SECONDARY_BASE_SCORE // 4
    private GBK_PUA_PENALTY                               = -(CJK_BASE_SCORE * 10)
    private GBK_SINGLE_BYTE_EXTENSION_PENALTY             = GBK_PUA_PENALTY * 4
    private EUC_KR_PUA_PENALTY                            = GBK_PUA_PENALTY - 1 # Break tie in favor of GBK
    private EUC_KR_MAC_KOREAN_PENALTY                     = EUC_KR_PUA_PENALTY * 2
    private EUC_KR_SINGLE_BYTE_EXTENSION_PENALTY          = EUC_KR_MAC_KOREAN_PENALTY
    private CJK_LATIN_ADJACENCY_PENALTY                   = -CJK_BASE_SCORE
    private CJ_PUNCTUATION                                = CJK_BASE_SCORE // 2
    private CJK_OTHER                                     = CJK_SECONDARY_BASE_SCORE // 4

    # :nodoc:
    enum LatinCj
      AsciiLetter
      Cj
      Other
    end

    # :nodoc:
    enum HalfWidthKatakana
      DakutenForbidden
      DakutenAllowed
      DakutenOrHandakutenAllowed
    end

    # :nodoc:
    enum LatinKorean
      AsciiLetter
      Hangul
      Hanja
      Other
    end

    # :nodoc:
    def self.cjk_extra_score(u : UInt16, table : Bytes) : Int64
      128.times do |pos|
        return ((128 - pos) // 16).to_i64 if table.unsafe_fetch(pos * 2).to_u16 | (table.unsafe_fetch(pos * 2 + 1).to_u16 << 8) == u
      end
      0_i64
    end

    # :nodoc:
    def self.problematic_lead?(b : UInt8) : Bool
      (0x91 <= b <= 0x97) || b.in?(0x9A, 0x8A, 0x9B, 0x8B, 0x9E, 0x8E, 0xB0)
    end

    # GBK and EUC-KR
    # :nodoc:
    def self.more_problematic_lead?(b : UInt8) : Bool
      problematic_lead?(b) || b.in?(0x82, 0x84, 0x85, 0xA0)
    end

    # :nodoc:
    def self.ascii_letter?(u : UInt16) : Bool
      ('a'.ord <= u <= 'z'.ord) || ('A'.ord <= u <= 'Z'.ord)
    end

    # Shared running score: `nil` once disqualified.
    # :nodoc:
    module CjkScore
      getter score : Int64? = 0_i64

      # Fathom extension: don't treat a character cut by the end of the input as
      # an error (the input may be a prefix sample; `Fathom.decode` drops such a
      # tail), but remember it in `cut_tail?`. Upstream disqualifies the candidate.
      property? lenient_eof = false
      getter? cut_tail = false

      def guess_score : Int64?
        @score
      end

      def feed(buffer : Bytes, last : Bool) : Nil
        return unless old = @score
        @score = (delta = feed_inner(buffer, last)) ? old + delta : nil
      end
    end

    # Whether *bytes* (all 7-bit) contains an escape and decodes as ISO-2022-JP,
    # upstream's ISO-2022-JP rule. A character or escape sequence cut by the end
    # of *bytes* is dropped first (as `Fathom.decode` does), so a cut sample still
    # counts, while ASCII ending in a lone ESC doesn't.
    # :nodoc:
    def self.iso_2022_jp?(bytes : Bytes) : Bool
      return false unless bytes.includes?(0x1B_u8) # keeps the ASCII fast path fast
      bytes = bytes[0, WHATWG.complete_prefix_size("ISO-2022-JP", bytes)]
      return false unless bytes.includes?(0x1B_u8)
      decoder = WHATWG::Iso2022JpDecoder.new
      bytes.each { |b| return false if decoder.feed(b).malformed? }
      !decoder.finish.malformed?
    end

    # :nodoc:
    struct Iso2022Candidate
      include CjkScore
      @decoder = WHATWG::Iso2022JpDecoder.new

      def encoding : String
        "ISO-2022-JP"
      end

      private def feed_inner(buffer : Bytes, last : Bool) : Int64?
        buffer.each { |b| return nil if @decoder.feed(b).malformed? }
        return nil if last && @decoder.finish.malformed?
        0_i64
      end
    end

    # :nodoc:
    struct GbkCandidate
      include CjkScore
      @decoder = WHATWG::Gb18030Decoder.new
      @prev_byte = 0_u8
      @prev = LatinCj::Other
      @pending_score : Int64? = nil

      def encoding : String
        "GBK"
      end

      private def maybe_set_as_pending(s : Int64) : Int64
        if @prev.cj? || !Chardetng.more_problematic_lead?(@prev_byte)
          s
        else
          @pending_score = s
          0_i64
        end
      end

      private def take_pending : Int64
        pending = @pending_score || 0_i64
        @pending_score = nil
        pending
      end

      private def feed_inner(buffer : Bytes, last : Bool) : Int64?
        score = 0_i64
        buffer.each do |b|
          step = @decoder.feed(b)
          if step.written == 1
            u = step.u0
            if Chardetng.ascii_letter?(u)
              @pending_score = nil # Discard pending score
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.cj?
              @prev = LatinCj::AsciiLetter
            elsif u == 0x20AC
              # euro sign
              @pending_score = nil
              @prev = LatinCj::Other
            elsif 0x4E00 <= u <= 0x9FA5
              score += take_pending
              if 0xA1 <= b <= 0xFE
                case @prev_byte
                when 0xA1..0xD7
                  score += GBK_SCORE_PER_LEVEL_1
                  score += Chardetng.cjk_extra_score(u, FREQUENT_SIMPLIFIED)
                when 0xD8..0xFE
                  score += GBK_SCORE_PER_LEVEL_2
                else
                  score += GBK_SCORE_PER_NON_EUC
                end
              else
                score += maybe_set_as_pending(GBK_SCORE_PER_NON_EUC)
              end
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.ascii_letter?
              @prev = LatinCj::Cj
            elsif (0x3400 <= u < 0xA000) || (0xF900 <= u < 0xFB00)
              score += take_pending
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.ascii_letter?
              @prev = LatinCj::Cj
            elsif 0xE000 <= u < 0xF900
              score += take_pending
              # Treat the GB18030-required PUA mappings as non-EUC ideographs.
              if (0xE78D <= u <= 0xE796) || (0xE816 <= u <= 0xE818) ||
                 u.in?(0xE81E, 0xE826, 0xE82B, 0xE82C, 0xE831, 0xE832, 0xE83B, 0xE843, 0xE854, 0xE855, 0xE864)
                score += GBK_SCORE_PER_NON_EUC
                score += CJK_LATIN_ADJACENCY_PENALTY if @prev.ascii_letter?
                @prev = LatinCj::Cj
              else
                score += GBK_PUA_PENALTY
                @prev = LatinCj::Other
              end
            else
              if u.in?(0x3000, 0x3001, 0x3002, 0xFF08, 0xFF09, 0xFF01, 0xFF0C, 0xFF1B, 0xFF1F)
                score += take_pending
                score += CJ_PUNCTUATION
              elsif u <= 0x7F
                @pending_score = nil # Discard pending score
              else
                score += take_pending
                score += CJK_OTHER
              end
              @prev = LatinCj::Other
            end
          elsif step.written == 2
            score += take_pending
            u = step.u0
            if 0xDB80 <= u <= 0xDBFF
              score += GBK_PUA_PENALTY
              @prev = LatinCj::Other
            elsif 0xD480 <= u < 0xD880
              score += GBK_SCORE_PER_NON_EUC
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.ascii_letter?
              @prev = LatinCj::Cj
            else
              score += CJK_OTHER
              @prev = LatinCj::Other
            end
          end
          return nil if step.output_full?
          if step.malformed?
            if (@prev_byte == 0xA0 || @prev_byte == 0xFE || @prev_byte == 0xFD) && (b < 0x80 || b == 0xFF)
              # Mac OS Chinese Simplified single-byte that conflicts with code page
              # GBK lead byte followed by ASCII or a non-conflicting single-byte extension.
              @pending_score = nil
              score += GBK_SINGLE_BYTE_EXTENSION_PENALTY
              if ('a'.ord <= b <= 'z'.ord) || ('A'.ord <= b <= 'Z'.ord)
                @prev = LatinCj::AsciiLetter
              elsif b == 0xFF
                score += GBK_SINGLE_BYTE_EXTENSION_PENALTY
                @prev = LatinCj::Other
              else
                @prev = LatinCj::Other
              end
              # The GBK decoder has the pending ASCII concept, which is a problem
              # with this trickery, so let's reset the state.
              @decoder = WHATWG::Gb18030Decoder.new
            elsif step.malformed == 1 && b == 0xFF
              # Mac OS Chinese Simplified single-byte extension that doesn't conflict with lead bytes
              @pending_score = nil
              score += GBK_SINGLE_BYTE_EXTENSION_PENALTY
              @prev = LatinCj::Other
              @decoder = WHATWG::Gb18030Decoder.new
            else
              return nil
            end
          end
          @prev_byte = b
        end
        if last && @decoder.finish.malformed?
          return nil unless lenient_eof?
          @cut_tail = true
        end
        score
      end
    end

    # :nodoc:
    struct ShiftJisCandidate
      include CjkScore
      @decoder = WHATWG::ShiftJisDecoder.new
      @half_width_katakana_seen = false
      @half_width_katakana_state = HalfWidthKatakana::DakutenForbidden
      @prev = LatinCj::Other
      @prev_byte = 0_u8
      @pending_score : Int64? = nil

      def encoding : String
        "SHIFT_JIS"
      end

      private def maybe_set_as_pending(s : Int64) : Int64
        if @prev.cj? || !Chardetng.problematic_lead?(@prev_byte)
          s
        else
          @pending_score = s
          0_i64
        end
      end

      private def take_pending : Int64
        pending = @pending_score || 0_i64
        @pending_score = nil
        pending
      end

      private def feed_inner(buffer : Bytes, last : Bool) : Int64?
        score = 0_i64
        buffer.each do |b|
          step = @decoder.feed(b)
          if step.written > 0
            half_width_katakana_state = @half_width_katakana_state
            @half_width_katakana_state = HalfWidthKatakana::DakutenForbidden
            u = step.u0
            if Chardetng.ascii_letter?(u)
              @pending_score = nil
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.cj?
              @prev = LatinCj::AsciiLetter
            elsif 0xFF61 <= u <= 0xFF9F
              unless @half_width_katakana_seen
                @half_width_katakana_seen = true
                # To avoid misdetecting title-length inputs
                score += SHIFT_JIS_INITIAL_HALF_WIDTH_KATAKANA_PENALTY
              end
              @pending_score = nil
              score += HALF_WIDTH_KATAKANA_SCORE
              score += Chardetng.half_width_katakana(u, half_width_katakana_state) { |s| @half_width_katakana_state = s }
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.ascii_letter?
              @prev = LatinCj::Cj
            elsif 0x3040 <= u < 0x3100
              score += take_pending
              score += SHIFT_JIS_SCORE_PER_KANA
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.ascii_letter?
              @prev = LatinCj::Cj
            elsif (0x3400 <= u < 0xA000) || (0xF900 <= u < 0xFB00)
              score += take_pending
              if @prev_byte < 0x98 || (@prev_byte == 0x98 && b < 0x73)
                score += maybe_set_as_pending(SHIFT_JIS_SCORE_PER_LEVEL_1_KANJI + Chardetng.cjk_extra_score(u, FREQUENT_KANJI))
              else
                score += maybe_set_as_pending(SHIFT_JIS_SCORE_PER_LEVEL_2_KANJI)
              end
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.ascii_letter?
              @prev = LatinCj::Cj
            elsif 0xE000 <= u < 0xF900
              score += take_pending
              score += SHIFT_JIS_PUA_PENALTY
              @prev = LatinCj::Other
            else
              if u.in?(0x3000, 0x3001, 0x3002, 0xFF08, 0xFF09)
                score += take_pending
                score += CJ_PUNCTUATION
              elsif u <= 0x7F
                @pending_score = nil
              elsif u == 0x80
                # A control character that overlaps euro in windows-1252 and
                # happens to be a non-error in Shift_JIS.
                @pending_score = nil
                score += IMPLAUSIBILITY_PENALTY
              else
                score += take_pending
                score += CJK_OTHER
              end
              @prev = LatinCj::Other
            end
          end
          return nil if step.output_full?
          if step.malformed?
            pb = @prev_byte
            if (((0x81 <= pb <= 0x9F) || (0xE0 <= pb <= 0xFC)) && ((0x40 <= b <= 0x7E) || (0x80 <= b <= 0xFC))) &&
               !((pb == 0x82 && b >= 0xFA) ||
               (pb == 0x84 && ((0xDD <= b <= 0xE4) || b >= 0xFB)) ||
               (pb == 0x86 && 0xF2 <= b <= 0xFA) ||
               (pb == 0x87 && 0x77 <= b <= 0x7D) ||
               (pb == 0xFC && b >= 0xF5))
              # Shift_JIS2004 or MacJapanese
              score += take_pending
              score += SHIFT_JIS_EXTENSION_PENALTY
              # Approximate boundary
              if pb < 0x87
                @prev = LatinCj::Other
              else
                score += CJK_LATIN_ADJACENCY_PENALTY if @prev.ascii_letter?
                @prev = LatinCj::Cj
              end
            elsif step.malformed == 1 && (b == 0xA0 || b >= 0xFD)
              @pending_score = nil
              score += SHIFT_JIS_SINGLE_BYTE_EXTENSION_PENALTY
              @prev = LatinCj::Other
            else
              return nil
            end
          end
          @prev_byte = b
        end
        if last && @decoder.finish.malformed?
          return nil unless lenient_eof?
          @cut_tail = true
        end
        score
      end
    end

    # Half-width katakana voicing marks: returns the score change and reports the
    # next state through the block.
    # :nodoc:
    def self.half_width_katakana(u : UInt16, state : HalfWidthKatakana, &) : Int64
      if (0xFF76 <= u <= 0xFF84) || u == 0xFF73
        yield HalfWidthKatakana::DakutenAllowed
      elsif 0xFF8A <= u <= 0xFF8E
        yield HalfWidthKatakana::DakutenOrHandakutenAllowed
      elsif u == 0xFF9E
        return state.dakuten_forbidden? ? IMPLAUSIBILITY_PENALTY : HALF_WIDTH_KATAKANA_VOICING_SCORE
      elsif u == 0xFF9F
        return state.dakuten_or_handakuten_allowed? ? HALF_WIDTH_KATAKANA_VOICING_SCORE : IMPLAUSIBILITY_PENALTY
      end
      0_i64
    end

    # :nodoc:
    struct EucJpCandidate
      include CjkScore
      @decoder = WHATWG::EucJpDecoder.new
      @non_ascii_seen = false
      @half_width_katakana_state = HalfWidthKatakana::DakutenForbidden
      @prev = LatinCj::Other
      @prev_byte = 0_u8
      @prev_prev_byte = 0_u8

      def encoding : String
        "EUC-JP"
      end

      private def feed_inner(buffer : Bytes, last : Bool) : Int64?
        score = 0_i64
        buffer.each do |b|
          step = @decoder.feed(b)
          if step.written > 0
            half_width_katakana_state = @half_width_katakana_state
            @half_width_katakana_state = HalfWidthKatakana::DakutenForbidden
            u = step.u0
            if !@non_ascii_seen && u >= 0x80
              @non_ascii_seen = true
              # Remove the kana advantage over initial Big5 hanzi.
              score += EUC_JP_INITIAL_KANA_PENALTY if 0x3040 <= u < 0x3100
            end
            if Chardetng.ascii_letter?(u)
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.cj?
              @prev = LatinCj::AsciiLetter
            elsif 0xFF61 <= u <= 0xFF9F
              score += HALF_WIDTH_KATAKANA_SCORE
              score += Chardetng.half_width_katakana(u, half_width_katakana_state) { |s| @half_width_katakana_state = s }
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.ascii_letter?
              @prev = LatinCj::Other
            elsif (0x3041 <= u <= 0x3093) || (0x30A1 <= u <= 0x30F6)
              # hiragana/katakana wi and we: remove advantage over Big5 Hanzi
              score += u.in?(0x3090, 0x3091, 0x30F0, 0x30F1) ? EUC_JP_SCORE_PER_NEAR_OBSOLETE_KANA : EUC_JP_SCORE_PER_KANA
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.ascii_letter?
              @prev = LatinCj::Cj
            elsif (0x3400 <= u < 0xA000) || (0xF900 <= u < 0xFB00)
              if @prev_prev_byte == 0x8F
                score += EUC_JP_SCORE_PER_OTHER_KANJI
              elsif @prev_byte < 0xD0
                score += EUC_JP_SCORE_PER_LEVEL_1_KANJI
                score += Chardetng.cjk_extra_score(u, FREQUENT_KANJI)
              else
                score += EUC_JP_SCORE_PER_LEVEL_2_KANJI
              end
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.ascii_letter?
              @prev = LatinCj::Cj
            else
              if u.in?(0x3000, 0x3001, 0x3002, 0xFF08, 0xFF09)
                score += CJ_PUNCTUATION
              elsif u > 0x7F
                score += CJK_OTHER
              end
              @prev = LatinCj::Other
            end
          end
          return nil if step.output_full?
          if step.malformed?
            pb, ppb = @prev_byte, @prev_prev_byte
            if 0xA1 <= b <= 0xFE && 0xA1 <= pb <= 0xFE &&
               ((ppb != 0x8F &&
               !(pb == 0xA8 && 0xDF <= b <= 0xE6) &&
               !(pb == 0xAC && 0xF4 <= b <= 0xFC) &&
               !(pb == 0xAD && 0xD8 <= b <= 0xDE)) ||
               (ppb == 0x8F && !pb.in?(0xA2, 0xA6, 0xA7, 0xA9, 0xAA, 0xAB, 0xED) && !(pb == 0xFE && b >= 0xF7)))
              score += EUC_JP_EXTENSION_PENALTY
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.ascii_letter?
              @prev = LatinCj::Cj
            else
              return nil
            end
          end
          @prev_prev_byte = @prev_byte
          @prev_byte = b
        end
        if last && @decoder.finish.malformed?
          return nil unless lenient_eof?
          @cut_tail = true
        end
        score
      end
    end

    # :nodoc:
    struct Big5Candidate
      include CjkScore
      @decoder = WHATWG::Big5Decoder.new
      @prev = LatinCj::Other
      @prev_byte = 0_u8
      @pending_score : Int64? = nil

      def encoding : String
        "BIG5"
      end

      private def maybe_set_as_pending(s : Int64) : Int64
        if @prev.cj? || !Chardetng.problematic_lead?(@prev_byte)
          s
        else
          @pending_score = s
          0_i64
        end
      end

      private def take_pending : Int64
        pending = @pending_score || 0_i64
        @pending_score = nil
        pending
      end

      private def feed_inner(buffer : Bytes, last : Bool) : Int64?
        score = 0_i64
        buffer.each do |b|
          step = @decoder.feed(b)
          if step.written == 1
            u = step.u0
            if Chardetng.ascii_letter?(u)
              @pending_score = nil
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.cj?
              @prev = LatinCj::AsciiLetter
            elsif (0x3400 <= u < 0xA000) || (0xF900 <= u < 0xFB00)
              score += take_pending
              if 0xA4 <= @prev_byte <= 0xC6
                score += maybe_set_as_pending(BIG5_SCORE_PER_LEVEL_1_HANZI)
              else
                score += maybe_set_as_pending(BIG5_SCORE_PER_OTHER_HANZI)
              end
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.ascii_letter?
              @prev = LatinCj::Cj
            else
              if u.in?(0x3000, 0x3001, 0x3002, 0xFF08, 0xFF09, 0xFF01, 0xFF0C, 0xFF1B, 0xFF1F)
                score += take_pending
                score += CJ_PUNCTUATION
              elsif u <= 0x7F
                @pending_score = nil
              else
                score += take_pending
                score += CJK_OTHER
              end
              @prev = LatinCj::Other
            end
          elsif step.written == 2
            score += take_pending
            if step.u0 == 0xCA || step.u0 == 0xEA
              score += CJK_OTHER
              @prev = LatinCj::Other
            else
              score += maybe_set_as_pending(BIG5_SCORE_PER_OTHER_HANZI)
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.ascii_letter?
              @prev = LatinCj::Cj
            end
          end
          return nil if step.output_full?
          if step.malformed?
            if 0x81 <= @prev_byte <= 0xFE && ((0x40 <= b <= 0x7E) || (0xA1 <= b <= 0xFE))
              # The byte pair is in the Big5 range but unmapped. Treat as PUA to
              # avoid rejecting Big5-UAO, etc.
              score += take_pending
              score += BIG5_PUA_PENALTY
              # Assume Hanzi semantics
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.ascii_letter?
              @prev = LatinCj::Cj
            elsif (@prev_byte == 0xA0 || @prev_byte == 0xFD || @prev_byte == 0xFE) && (b < 0x80 || b == 0xFF)
              # Mac OS Chinese Traditional single-byte that conflicts with code page
              # Big5 lead byte followed by ASCII or a non-conflicting single-byte extension.
              @pending_score = nil
              score += BIG5_SINGLE_BYTE_EXTENSION_PENALTY
              if ('a'.ord <= b <= 'z'.ord) || ('A'.ord <= b <= 'Z'.ord)
                @prev = LatinCj::AsciiLetter
              elsif b == 0xFF
                score += BIG5_SINGLE_BYTE_EXTENSION_PENALTY
                @prev = LatinCj::Other
              else
                @prev = LatinCj::Other
              end
            elsif step.malformed == 1 && b == 0xFF
              # Mac OS Chinese Traditional single-byte extension that doesn't conflict with lead bytes
              @pending_score = nil
              score += BIG5_SINGLE_BYTE_EXTENSION_PENALTY
              @prev = LatinCj::Other
            else
              return nil
            end
          end
          @prev_byte = b
        end
        if last && @decoder.finish.malformed?
          return nil unless lenient_eof?
          @cut_tail = true
        end
        score
      end
    end

    # :nodoc:
    struct EucKrCandidate
      include CjkScore
      @decoder = WHATWG::EucKrDecoder.new
      @prev_byte = 0_u8
      @prev_was_euc_range = false
      @prev = LatinKorean::Other
      @current_word_len = 0_i64
      @pending_score : Int64? = nil

      def encoding : String
        "EUC-KR"
      end

      private def maybe_set_as_pending(s : Int64) : Int64
        if @prev.hangul? || !Chardetng.more_problematic_lead?(@prev_byte)
          s
        else
          @pending_score = s
          0_i64
        end
      end

      private def take_pending : Int64
        pending = @pending_score || 0_i64
        @pending_score = nil
        pending
      end

      private def word_letter : Int64
        @current_word_len += 1
        @current_word_len > 5 ? EUC_KR_LONG_WORD_PENALTY : 0_i64
      end

      private def feed_inner(buffer : Bytes, last : Bool) : Int64?
        score = 0_i64
        buffer.each do |b|
          in_euc_range = 0xA1 <= b <= 0xFE
          step = @decoder.feed(b)
          if step.written > 0
            u = step.u0
            if Chardetng.ascii_letter?(u)
              @pending_score = nil
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.hangul? || @prev.hanja?
              @prev = LatinKorean::AsciiLetter
              @current_word_len = 0_i64
            elsif 0xAC00 <= u <= 0xD7A3
              score += take_pending
              if @prev_was_euc_range && in_euc_range
                score += EUC_KR_SCORE_PER_EUC_HANGUL
                score += Chardetng.cjk_extra_score(u, FREQUENT_HANGUL)
              else
                score += maybe_set_as_pending(EUC_KR_SCORE_PER_NON_EUC_HANGUL)
              end
              score += CJK_LATIN_ADJACENCY_PENALTY if @prev.ascii_letter?
              @prev = LatinKorean::Hangul
              score += word_letter
            elsif (0x4E00 <= u < 0xAC00) || (0xF900 <= u <= 0xFA0B)
              score += take_pending
              score += EUC_KR_SCORE_PER_HANJA
              case @prev
              when .ascii_letter? then score += CJK_LATIN_ADJACENCY_PENALTY
              when .hangul?       then score += EUC_KR_HANJA_AFTER_HANGUL_PENALTY
              else
              end
              @prev = LatinKorean::Hanja
              score += word_letter
            else
              if u >= 0x80
                score += take_pending
                score += CJK_OTHER
              else
                @pending_score = nil
              end
              @prev = LatinKorean::Other
              @current_word_len = 0_i64
            end
          end
          return nil if step.output_full?
          if step.malformed?
            pb = @prev_byte
            if (pb == 0xC9 || pb == 0xFE) && 0xA1 <= b <= 0xFE
              score += take_pending
              # The byte pair is in code page 949 EUDC range
              score += EUC_KR_PUA_PENALTY
              # Assume Hanja semantics
              case @prev
              when .ascii_letter? then score += CJK_LATIN_ADJACENCY_PENALTY
              when .hangul?       then score += EUC_KR_HANJA_AFTER_HANGUL_PENALTY
              else
              end
              @prev = LatinKorean::Hanja
              score += word_letter
            elsif (pb == 0xA1 || (0xA3 <= pb <= 0xA8) || (0xAA <= pb <= 0xAD)) && 0x7B <= b <= 0x7D
              score += take_pending
              # MacKorean symbols in range not part of code page 949
              score += EUC_KR_MAC_KOREAN_PENALTY
              @prev = LatinKorean::Other
              @current_word_len = 0_i64
            elsif (0x81 <= pb <= 0x84) && (b <= 0x80 || b == 0xFF)
              # MacKorean single-byte that conflicts with code page 949 lead byte
              # followed by ASCII or a non-conflicting single-byte extension.
              @pending_score = nil
              score += EUC_KR_SINGLE_BYTE_EXTENSION_PENALTY
              if ('a'.ord <= b <= 'z'.ord) || ('A'.ord <= b <= 'Z'.ord)
                @prev = LatinKorean::AsciiLetter
              elsif b == 0x80 || b == 0xFF
                score += EUC_KR_SINGLE_BYTE_EXTENSION_PENALTY
                @prev = LatinKorean::Other
              else
                @prev = LatinKorean::Other
              end
              @current_word_len = 0_i64
            elsif step.malformed == 1 && (b == 0x80 || b == 0xFF)
              # MacKorean single-byte extensions that don't conflict with lead bytes
              @pending_score = nil
              score += EUC_KR_SINGLE_BYTE_EXTENSION_PENALTY
              @prev = LatinKorean::Other
              @current_word_len = 0_i64
            else
              return nil
            end
          end
          @prev_was_euc_range = in_euc_range
          @prev_byte = b
        end
        if last && @decoder.finish.malformed?
          return nil unless lenient_eof?
          @cut_tail = true
        end
        score
      end
    end
  end
end
