# Multi-byte decoders that reproduce encoding_rs 0.8.44
# (https://github.com/hsivonen/encoding_rs) step by step when fed one byte per
# call, as chardetng drives them: which bytes are consumed, malformed lengths,
# the gb18030 pending ASCII and output-buffer checks follow encoding_rs's code.
#
# Copyright Mozilla Foundation. encoding_rs is licensed under the Apache License,
# Version 2.0 or the MIT license, at your option; this port uses it under the MIT
# license, whose full text is in LICENSE-encoding_rs at the repository root. The
# code point indexes come from the WHATWG Encoding Standard (LICENSE-whatwg).
require "../whatwg"

module Fathom
  module WHATWG
    # What one `feed`/`finish` call did, as encoding_rs reports it when a single
    # byte is decoded into a two-unit UTF-16 buffer (the way chardetng drives its
    # decoders): `InputEmpty` or `Malformed(malformed, good)` (or `OutputFull`),
    # plus up to two UTF-16 code units written.
    # :nodoc:
    struct Step
      getter malformed : UInt8
      getter good : UInt8
      getter? output_full : Bool
      getter written : Int32
      getter u0 : UInt16
      getter u1 : UInt16

      def initialize(@malformed = 0_u8, @good = 0_u8, @output_full = false, @written = 0, @u0 = 0_u16, @u1 = 0_u16)
      end

      def malformed? : Bool
        @malformed != 0
      end
    end

    # Accumulates the UTF-16 output of one call into a two-unit buffer.
    private struct Out
      getter written = 0
      @u0 = 0_u16
      @u1 = 0_u16

      def space?(units : Int32) : Bool
        @written + units <= 2
      end

      def write(cp : Int32) : Nil
        if cp > 0xFFFF
          cp -= 0x10000
          put((0xD800 | (cp >> 10)).to_u16)
          put((0xDC00 | (cp & 0x3FF)).to_u16)
        else
          put(cp.to_u16)
        end
      end

      private def put(unit : UInt16) : Nil
        if @written == 0
          @u0 = unit
        else
          @u1 = unit
        end
        @written += 1
      end

      def empty : Step
        Step.new(written: @written, u0: @u0, u1: @u1)
      end

      def malformed(len : Int, good : Int = 0) : Step
        Step.new(malformed: len.to_u8, good: good.to_u8, written: @written, u0: @u0, u1: @u1)
      end

      def full : Step
        Step.new(output_full: true, written: @written, u0: @u0, u1: @u1)
      end
    end

    # :nodoc:
    @[AlwaysInline]
    def self.ascii?(b : UInt8) : Bool
      b < 0x80
    end

    # Shift_JIS (windows-31j) decoder.
    # :nodoc:
    struct ShiftJisDecoder
      @lead = 0_u8

      def feed(b : UInt8) : Step
        buf = Out.new
        if (lead = @lead) != 0
          @lead = 0_u8
          offset = b < 0x7F ? 0x40 : 0x41
          lead_offset = lead < 0xA0 ? 0x81 : 0xC1
          cp = 0
          if (0x40 <= b <= 0x7E) || (0x80 <= b <= 0xFC)
            pointer = (lead.to_i32 - lead_offset) * 188 + b.to_i32 - offset
            cp = (8836 <= pointer <= 10715) ? 0xE000 - 8836 + pointer : WHATWG.jis0208(pointer)
          end
          return WHATWG.ascii?(b) ? buf.malformed(1) : buf.malformed(2) if cp == 0
          buf.write(cp)
          return buf.empty
        end
        if b <= 0x80
          buf.write(b.to_i32)
        elsif 0xA1 <= b <= 0xDF
          buf.write(0xFF61 - 0xA1 + b.to_i32)
        elsif (0x81 <= b <= 0x9F) || (0xE0 <= b <= 0xFC)
          @lead = b
        else
          return buf.malformed(1)
        end
        buf.empty
      end

      def finish : Step
        return Step.new if @lead == 0
        @lead = 0_u8
        Step.new(malformed: 1_u8)
      end
    end

    # EUC-KR (windows-949) decoder.
    # :nodoc:
    struct EucKrDecoder
      @lead = 0_u8

      def feed(b : UInt8) : Step
        buf = Out.new
        if (lead = @lead) != 0
          @lead = 0_u8
          cp = 0x41 <= b <= 0xFE ? WHATWG.euc_kr((lead.to_i32 - 0x81) * 190 + b.to_i32 - 0x41) : 0
          return WHATWG.ascii?(b) ? buf.malformed(1) : buf.malformed(2) if cp == 0
          buf.write(cp)
          return buf.empty
        end
        if b < 0x80
          buf.write(b.to_i32)
        elsif 0x81 <= b <= 0xFE
          @lead = b
        else
          return buf.malformed(1)
        end
        buf.empty
      end

      def finish : Step
        return Step.new if @lead == 0
        @lead = 0_u8
        Step.new(malformed: 1_u8)
      end
    end

    # Big5 (Big5-HKSCS) decoder.
    # :nodoc:
    struct Big5Decoder
      @lead = 0_u8

      def feed(b : UInt8) : Step
        buf = Out.new
        if (lead = @lead) != 0
          @lead = 0_u8
          pointer = -1
          if (0x40 <= b <= 0x7E) || (0xA1 <= b <= 0xFE)
            pointer = (lead.to_i32 - 0x81) * 157 + b.to_i32 - (b < 0x7F ? 0x40 : 0x62)
          end
          case pointer
          when 1133 then buf.write(0x00CA); buf.write(0x0304); return buf.empty
          when 1135 then buf.write(0x00CA); buf.write(0x030C); return buf.empty
          when 1164 then buf.write(0x00EA); buf.write(0x0304); return buf.empty
          when 1166 then buf.write(0x00EA); buf.write(0x030C); return buf.empty
          end
          cp = pointer < 0 ? 0 : WHATWG.big5(pointer)
          return WHATWG.ascii?(b) ? buf.malformed(1) : buf.malformed(2) if cp == 0
          buf.write(cp)
          return buf.empty
        end
        if b < 0x80
          buf.write(b.to_i32)
        elsif 0x81 <= b <= 0xFE
          @lead = b
        else
          return buf.malformed(1)
        end
        buf.empty
      end

      def finish : Step
        return Step.new if @lead == 0
        @lead = 0_u8
        Step.new(malformed: 1_u8)
      end
    end

    # EUC-JP decoder.
    # :nodoc:
    struct EucJpDecoder
      @lead = 0_u8         # 0x8E, 0x8F or a JIS X 0208 lead (0xA1..0xFE)
      @jis0212_lead = 0_u8 # second byte after 0x8F

      def feed(b : UInt8) : Step
        buf = Out.new
        if (lead = @jis0212_lead) != 0
          # 0x8F, lead, trail
          @jis0212_lead = 0_u8
          return WHATWG.ascii?(b) ? buf.malformed(2) : buf.malformed(3) unless 0xA1 <= b <= 0xFE
          cp = WHATWG.jis0212((lead.to_i32 - 0xA1) * 94 + b.to_i32 - 0xA1)
          return buf.malformed(3) if cp == 0
          buf.write(cp)
          return buf.empty
        end
        if (lead = @lead) != 0
          @lead = 0_u8
          case lead
          when 0x8E
            return WHATWG.ascii?(b) ? buf.malformed(1) : buf.malformed(2) unless 0xA1 <= b <= 0xDF
            buf.write(0xFF61 - 0xA1 + b.to_i32)
          when 0x8F
            return WHATWG.ascii?(b) ? buf.malformed(1) : buf.malformed(2) unless 0xA1 <= b <= 0xFE
            @jis0212_lead = b
          else
            return WHATWG.ascii?(b) ? buf.malformed(1) : buf.malformed(2) unless 0xA1 <= b <= 0xFE
            cp = WHATWG.jis0208((lead.to_i32 - 0xA1) * 94 + b.to_i32 - 0xA1)
            return buf.malformed(2) if cp == 0
            buf.write(cp)
          end
          return buf.empty
        end
        if b < 0x80
          buf.write(b.to_i32)
        elsif b == 0x8E || b == 0x8F || (0xA1 <= b <= 0xFE)
          @lead = b
        else
          return buf.malformed(1)
        end
        buf.empty
      end

      def finish : Step
        if @jis0212_lead != 0
          @jis0212_lead = 0_u8
          return Step.new(malformed: 2_u8)
        end
        return Step.new if @lead == 0
        @lead = 0_u8
        Step.new(malformed: 1_u8)
      end
    end

    # gb18030 decoder (WHATWG decodes GBK with it too), including encoding_rs's
    # "pending ASCII" for a second byte that turned buf not to start a four-byte
    # sequence.
    # :nodoc:
    struct Gb18030Decoder
      # Bytes of an unfinished sequence, as offsets: first - 0x81, second - 0x30, third - 0x81.
      @pending = 0 # 0..3 bytes
      @first = 0
      @second = 0
      @third = 0
      @pending_ascii = -1

      def feed(b : UInt8) : Step
        buf = Out.new
        if @pending_ascii >= 0
          buf.write(@pending_ascii)
          @pending_ascii = -1
        end
        if @pending > 0
          return buf.full unless buf.space?(2)
          case @pending
          when 1
            @pending = 0
            second = b.to_i32 - 0x30
            if 0 <= second <= 9
              @second = second
              @pending = 2
              return buf.empty
            end
            return two_byte(buf, @first, b)
          when 2
            @pending = 0
            third = b.to_i32 - 0x81
            unless 0 <= third <= 0xFE - 0x81
              @pending_ascii = @second + 0x30
              return buf.malformed(1, 1)
            end
            @third = third
            @pending = 3
            return buf.empty
          else
            @pending = 0
            return four_byte(buf, b)
          end
        end
        if b < 0x80
          buf.write(b.to_i32)
          return buf.empty
        end
        return buf.full unless buf.space?(2)
        if b == 0x80
          buf.write(0x20AC)
          return buf.empty
        end
        return buf.malformed(1) if b == 0xFF
        @first = b.to_i32 - 0x81
        @pending = 1
        buf.empty
      end

      private def two_byte(buf : Out, first : Int32, b : UInt8) : Step
        trail = if 0x40 <= b <= 0x7E
                  b.to_i32 - 0x40
                elsif 0x80 <= b <= 0xFE
                  b.to_i32 - 0x41
                else
                  return WHATWG.ascii?(b) ? buf.malformed(1) : buf.malformed(2)
                end
        buf.write(WHATWG.gb18030(first * 190 + trail))
        buf.empty
      end

      private def four_byte(buf : Out, b : UInt8) : Step
        fourth = b.to_i32 - 0x30
        unless 0 <= fourth <= 9
          @pending_ascii = @second + 0x30
          @first = @third
          @pending = 1
          return buf.malformed(1, 2)
        end
        pointer = @first * (10 * 126 * 10) + @second * (10 * 126) + @third * 10 + fourth
        cp = if pointer <= 39419 || (189_000 <= pointer <= 1_237_575)
               WHATWG.gb18030_ranges(pointer)
             else
               0
             end
        return buf.malformed(4) if cp == 0
        buf.write(cp)
        buf.empty
      end

      def finish : Step
        buf = Out.new
        if @pending_ascii >= 0
          buf.write(@pending_ascii)
          @pending_ascii = -1
        end
        return buf.empty if @pending == 0
        count = @pending
        @pending = 0
        buf.malformed(count)
      end
    end

    # ISO-2022-JP decoder.
    # :nodoc:
    struct Iso2022JpDecoder
      private enum State
        Ascii
        Roman
        Katakana
        LeadByte
        TrailByte
        EscapeStart
        Escape
      end

      @state = State::Ascii
      @output_state = State::Ascii
      @lead = 0_u8
      @output_flag = false
      @pending_prepended = false

      def feed(b : UInt8) : Step
        buf = Out.new
        prepend
        buf.write(@prepended) if @prepended >= 0
        return buf.full unless buf.space?(1)
        case @state
        in .ascii?, .roman?
          return escape_start(buf) if b == 0x1B
          @output_flag = false
          return buf.malformed(1) if b > 0x7F || b == 0x0E || b == 0x0F
          if @state.roman? && b == 0x5C
            buf.write(0x00A5)
          elsif @state.roman? && b == 0x7E
            buf.write(0x203E)
          else
            buf.write(b.to_i32)
          end
        in .katakana?
          return escape_start(buf) if b == 0x1B
          @output_flag = false
          return buf.malformed(1) unless 0x21 <= b <= 0x5F
          buf.write(0xFF61 - 0x21 + b.to_i32)
        in .lead_byte?
          return escape_start(buf) if b == 0x1B
          @output_flag = false
          return buf.malformed(1) unless 0x21 <= b <= 0x7E
          @lead = b
          @state = State::TrailByte
        in .trail_byte?
          if b == 0x1B
            @state = State::EscapeStart
            return buf.malformed(1, 1)
          end
          @state = State::LeadByte
          return buf.malformed(2) unless 0x21 <= b <= 0x7E
          cp = WHATWG.jis0208((@lead.to_i32 - 0x21) * 94 + b.to_i32 - 0x21)
          return buf.malformed(2) if cp == 0
          buf.write(cp)
        in .escape_start?
          if b == 0x24 || b == 0x28
            @lead = b
            @state = State::Escape
            return buf.empty
          end
          @output_flag = false
          @state = @output_state
          return buf.malformed(1)
        in .escape?
          state = if @lead == 0x28 && b == 0x42
                    State::Ascii
                  elsif @lead == 0x28 && b == 0x4A
                    State::Roman
                  elsif @lead == 0x28 && b == 0x49
                    State::Katakana
                  elsif @lead == 0x24 && (b == 0x40 || b == 0x42)
                    State::LeadByte
                  end
          if state
            @lead = 0_u8
            @state = state
            @output_state = state
            flag = @output_flag
            @output_flag = true
            return buf.malformed(3, 3) if flag
          else
            @pending_prepended = true
            @output_flag = false
            @state = @output_state
            return buf.malformed(1, 1)
          end
        end
        buf.empty
      end

      def finish : Step
        buf = Out.new
        prepend
        buf.write(@prepended) if @prepended >= 0
        case @state
        when .trail_byte?, .escape_start?
          return buf.full unless buf.space?(1)
          @state = @output_state
          return buf.malformed(1)
        when .escape?
          return buf.full unless buf.space?(1)
          @pending_prepended = true
          @state = @output_state
          return buf.malformed(1, 1)
        end
        buf.empty
      end

      # Code point the "prepended" escape lead decodes to at the start of a call, or -1.
      @prepended = -1

      private def prepend : Nil
        @prepended = -1
        return unless @pending_prepended
        @pending_prepended = false
        @output_flag = false
        case @state
        when .ascii?, .roman?
          @prepended = @lead.to_i32
          @lead = 0_u8
        when .katakana?
          @prepended = @lead.to_i32 - 0x21 + 0xFF61
          @lead = 0_u8
        when .lead_byte?
          @state = State::TrailByte
        end
      end

      private def escape_start(buf : Out) : Step
        @state = State::EscapeStart
        buf.empty
      end
    end
  end
end
