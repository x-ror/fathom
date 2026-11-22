module Fathom
  # Probers for single-byte encodings using language-level bigram models
  # projected through precomputed per-encoding byte lookup maps.
  module SingleByte
    # Character category packed into the top 2 bits of each `byte_map` entry.
    enum CharKind : UInt8
      Other = 0
      Lower = 1
      Upper = 2
      Junk  = 3
    end

    # Bit mask extracting the 6-bit letter order (`0..63`) from a `byte_map` entry.
    ORDER_MASK = 0x3F_u8

    # Bit shift for `CharKind` inside a `byte_map` entry.
    KIND_SHIFT = 6

    # Bit shift for row indexing into the `64x64` bigram matrix.
    ROW_SHIFT = 6

    # Side length of the flattened `64x64` bigram score matrix.
    ORDER_SIZE = 64

    # Fixed-point scaling factor used to quantize bigram log-likelihood ratios into `Int8`.
    SCORE_SCALE = 20.0

    # Quantized `64x64` bigram log-likelihood model for a single language or language group.
    class LanguageModel
      # Model identifier (e.g. `"ru"`, `"uk"`, `"be"`, `"western"`).
      getter name : String

      # Flattened `64x64` matrix indexed as `(prev_order << 6) | curr_order`.
      getter bigrams : StaticArray(Int8, 4096)

      def initialize(@name : String, @bigrams : StaticArray(Int8, 4096))
      end
    end

    # Zero-allocation prober for a single-byte `(encoding, language)` pair.
    struct Table
      include Fathom::Prober

      # Canonical encoding name usable with `String.new(bytes, encoding)`.
      getter encoding : String

      # Language-level bigram model backing this prober.
      getter model : LanguageModel

      # When `true`, rejects inputs that lack runs of non-ASCII letters
      # (such as Latin text with isolated accented vowels). When `false`, rejects
      # inputs whose non-ASCII bytes mostly sit in runs of three or more
      # (such as Cyrillic words embedded in ASCII text).
      getter? requires_high_letters : Bool

      # Bit-packed `(CharKind << 6) | order` lookup table for bytes `0x00..0xFF`.
      getter byte_map : StaticArray(UInt8, 256)

      # Score handicap (in quantized bigram units) subtracted once per input.
      # It acts as a prior against this prober that fades as the input grows,
      # so short text without Ukrainian-only letters reads as KOI8-R, not KOI8-U.
      getter handicap : Int32

      def initialize(
        @encoding : String,
        @model : LanguageModel,
        @requires_high_letters : Bool,
        @byte_map : StaticArray(UInt8, 256),
        @handicap : Int32 = 0,
      )
      end

      # Scores *bytes* using the projected bigram matrix and byte-transition penalties.
      def probe(bytes : Bytes, stats : ByteStats) : Match?
        return nil if stats.high_bytes == 0

        size = bytes.size
        ptr = bytes.to_unsafe
        map_ptr = @byte_map.to_unsafe
        bigrams_ptr = @model.bigrams.to_unsafe

        total = 0_i64
        pairs = 0_i64
        high_letters = 0
        isolated_high = 0
        junk_count = 0
        high_run = 0
        long_run_bytes = 0

        prev_order = 0_u8
        prev_kind = CharKind::Other.value

        i = 0
        while i < size
          byte = ptr[i]
          entry = map_ptr[byte]
          kind = entry >> KIND_SHIFT
          order = entry & ORDER_MASK

          if byte >= 0x80_u8 && order > 0_u8
            high_letters += 1
            # A letter is isolated when neither neighbour is a non-ASCII letter, so
            # symbols such as 0xAE cannot stand in as word separators ("\xE5\xAE\xE0\xAE").
            if (i == 0 || !high_letter?(map_ptr, ptr[i - 1])) && (i + 1 == size || !high_letter?(map_ptr, ptr[i + 1]))
              isolated_high += 1
            end
          end

          if byte >= 0x80_u8
            high_run += 1
          else
            long_run_bytes += high_run if high_run >= 3
            high_run = 0
          end

          if kind == CharKind::Junk.value
            total -= 120
            pairs += 1
            junk_count += 1
            prev_order = 0_u8
            prev_kind = CharKind::Other.value
          else
            if prev_order != 0_u8 || order != 0_u8
              total += bigrams_ptr[(prev_order.to_i32 << ROW_SHIFT) | order.to_i32].to_i32
              pairs += 1
              total -= 80 if prev_kind == CharKind::Lower.value && kind == CharKind::Upper.value
            end
            prev_order = order
            prev_kind = kind
          end

          i += 1
        end

        if prev_order != 0_u8
          total += bigrams_ptr[prev_order.to_i32 << ROW_SHIFT].to_i32
          pairs += 1
        end

        long_run_bytes += high_run if high_run >= 3

        if @requires_high_letters
          return nil if high_letters == 0 || isolated_high.to_i64 * 2 > high_letters
        elsif long_run_bytes.to_i64 * 2 > stats.high_bytes
          # NOTE: run-length heuristic, because this model also scores ASCII bigrams
          # and so outscores the Cyrillic probers on mixed English/Cyrillic text.
          # Score both families over the same pairs (needs a retrain) if this misfires.
          return nil
        end

        # No scorable letter pairs (e.g. "100 \xA4"): symbols alone are weak evidence.
        if (size == 1 || pairs == 0) && !@requires_high_letters && junk_count == 0
          return Match.new(@encoding, 0.25)
        end

        return nil if pairs == 0

        total -= @handicap
        avg = total.to_f64 / (pairs * SCORE_SCALE)
        return nil if avg <= 0.0

        confidence = 0.25 + 0.74 * (avg / (avg + 0.8))
        Match.new(@encoding, confidence)
      end

      @[AlwaysInline]
      private def high_letter?(map_ptr : Pointer(UInt8), byte : UInt8) : Bool
        byte >= 0x80_u8 && (map_ptr[byte] & ORDER_MASK) > 0_u8
      end
    end
  end
end
