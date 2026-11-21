module Fathom
  # Probers for single-byte encodings using precomputed lookup tables.
  module SingleByte
    # Character category for byte-level transition and validity checks.
    enum CharClass : UInt8
      Junk       = 0
      Other      = 1
      Lower      = 2
      Upper      = 3
      AsciiLower = 4
      AsciiUpper = 5
    end

    # Scoring strategy for a single-byte encoding table.
    enum Mode : UInt8
      # Unigram letter-frequency scoring with Cyrillic case/script boundary penalties.
      Frequency
      # Accented-Latin scoring penalizing runs of consecutive non-ASCII letters.
      AccentedLatin
    end

    # Zero-allocation prober for a single-byte character encoding using precomputed lookup tables.
    struct Table
      include Fathom::Prober

      # Canonical encoding name usable with `String.new(bytes, encoding)`.
      getter encoding : String

      # Scoring strategy used by this prober.
      getter mode : Mode

      # Precomputed `CharClass` values for bytes `0x80..0xFF`.
      getter classes : StaticArray(UInt8, 128)

      # Precomputed fixed-point weights (scaled by 100) for bytes `0x80..0xFF`.
      getter weights : StaticArray(Int16, 128)

      def initialize(
        @encoding : String,
        @mode : Mode,
        @classes : StaticArray(UInt8, 128),
        @weights : StaticArray(Int16, 128),
      )
      end

      # Scores *bytes* against precomputed byte class and weight tables.
      def probe(bytes : Bytes, stats : ByteStats) : Match?
        return nil if stats.high_bytes == 0

        size = bytes.size
        ptr = bytes.to_unsafe
        cls_ptr = @classes.to_unsafe
        w_ptr = @weights.to_unsafe

        total = 0_i64
        high = 0
        prev_cls = CharClass::Other.value
        i = 0

        if @mode.frequency?
          while i < size
            byte = ptr[i]
            if byte < 0x80_u8
              prev_cls = ascii_class(byte)
            else
              idx = byte &- 0x80_u8
              cls = cls_ptr[idx]
              high += 1
              w = w_ptr[idx].to_i32
              if cls == CharClass::Lower.value || cls == CharClass::Upper.value
                w -= 500 if (prev_cls == CharClass::Lower.value || prev_cls == CharClass::AsciiLower.value) && cls == CharClass::Upper.value
                w -= 500 if prev_cls == CharClass::AsciiLower.value || prev_cls == CharClass::AsciiUpper.value
              end
              total += w
              prev_cls = cls
            end
            i += 1
          end
        else
          while i < size
            byte = ptr[i]
            if byte < 0x80_u8
              prev_cls = ascii_class(byte)
            else
              idx = byte &- 0x80_u8
              cls = cls_ptr[idx]
              high += 1
              if cls == CharClass::Junk.value
                total -= 1000
              elsif cls == CharClass::Lower.value || cls == CharClass::Upper.value
                total += (prev_cls == CharClass::Lower.value || prev_cls == CharClass::Upper.value) ? -800 : 200
              end
              prev_cls = cls
            end
            i += 1
          end
        end

        avg = total.to_f64 / (high * 100.0)
        return nil if avg < 0.0

        confidence = 0.25 + 0.74 * (avg / (avg + 4.0))
        Match.new(@encoding, confidence)
      end

      @[AlwaysInline]
      private def ascii_class(byte : UInt8) : UInt8
        if byte >= 0x61_u8 && byte <= 0x7A_u8
          CharClass::AsciiLower.value
        elsif byte >= 0x41_u8 && byte <= 0x5A_u8
          CharClass::AsciiUpper.value
        else
          CharClass::Other.value
        end
      end
    end
  end
end
