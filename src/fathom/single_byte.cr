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

    # Quantized score penalty for `CharKind::Junk` (undefined bytes or out-of-alphabet high letters).
    JUNK_PENALTY = 180

    # Quantized score penalty for a lowercase-to-uppercase transition within a word.
    CASE_DROP_PENALTY = 80

    # Soft confidence multiplier when an input contains uppercase letters without any lowercase letters.
    ALL_CAPS_FACTOR = 0.70

    # Mild confidence discount when a Latin-script input contains no non-ASCII letters (`high_letters == 0`)
    # so decoding real non-ASCII letters is preferred over treating them as symbols.
    SYMBOL_ONLY_FACTOR = 0.85

    # Loads a `4096`-entry `Int8` bigram matrix from a raw byte slice in `.rodata`.
    def self.load_bigrams(data : Bytes) : StaticArray(Int8, 4096)
      raise ArgumentError.new("expected 4096 bigram bytes, got #{data.size}") unless data.size == 4096

      arr = uninitialized StaticArray(Int8, 4096)
      arr.to_unsafe.as(Pointer(UInt8)).copy_from(data.to_unsafe, 4096)
      arr
    end

    # Loads a `256`-entry `UInt8` byte classification table from a raw byte slice in `.rodata`.
    def self.load_byte_map(data : Bytes) : StaticArray(UInt8, 256)
      raise ArgumentError.new("expected 256 byte-map bytes, got #{data.size}") unless data.size == 256

      arr = uninitialized StaticArray(UInt8, 256)
      arr.to_unsafe.copy_from(data.to_unsafe, 256)
      arr
    end

    # Quantized `64x64` bigram log-likelihood model for a single language or language group.
    class LanguageModel
      # Model identifier (e.g. `"ru"`, `"uk"`, `"be"`, `"western"`).
      getter name : String

      # Flattened `64x64` matrix indexed as `(prev_order << 6) | curr_order`.
      getter bigrams : StaticArray(Int8, 4096)

      # Optional ISO 639-1 language code for single-language models, or `nil`.
      getter language : String?

      def initialize(@name : String, @bigrams : StaticArray(Int8, 4096), @language : String? = nil)
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

      def initialize(
        @encoding : String,
        @model : LanguageModel,
        @requires_high_letters : Bool,
        @byte_map : StaticArray(UInt8, 256),
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
        upper_letters = 0
        lower_letters = 0
        mixed_script_boundaries = 0
        junk_count = 0
        high_run = 0
        long_run_bytes = 0

        prev_order = 0_u8
        prev_kind = CharKind::Other.value
        prev_high_letter = false
        prev_ascii_letter = false

        i = 0
        while i < size
          byte = ptr[i]
          is_high = byte >= 0x80_u8
          entry = map_ptr[byte]
          kind = entry >> KIND_SHIFT
          order = entry & ORDER_MASK
          curr_high_letter = is_high && order > 0_u8
          curr_ascii_letter = (byte >= 0x41_u8 && byte <= 0x5A_u8) || (byte >= 0x61_u8 && byte <= 0x7A_u8)

          if curr_high_letter
            high_letters += 1
            mixed_script_boundaries += 1 if prev_ascii_letter
            # A letter is isolated when neither neighbour is a non-ASCII letter, so
            # symbols such as 0xAE cannot stand in as word separators ("\xE5\xAE\xE0\xAE").
            if (i == 0 || !high_letter?(map_ptr, ptr[i - 1])) && (i + 1 == size || !high_letter?(map_ptr, ptr[i + 1]))
              isolated_high += 1
            end
          elsif curr_ascii_letter && prev_high_letter
            mixed_script_boundaries += 1
          end

          if kind == CharKind::Upper.value
            upper_letters += 1
          elsif kind == CharKind::Lower.value
            lower_letters += 1
          end

          if is_high
            high_run += 1
          else
            long_run_bytes += high_run if high_run >= 3
            high_run = 0
          end

          if kind == CharKind::Junk.value
            total -= JUNK_PENALTY
            pairs += 1
            junk_count += 1
            prev_order = 0_u8
            prev_kind = CharKind::Other.value
            prev_high_letter = false
            prev_ascii_letter = false
          else
            if prev_order != 0_u8 || order != 0_u8
              w = bigrams_ptr[(prev_order.to_i32 << ROW_SHIFT) | order.to_i32].to_i32
              w -= CASE_DROP_PENALTY if prev_kind == CharKind::Lower.value && kind == CharKind::Upper.value
              if is_high && kind == CharKind::Other.value
                # Count an unexplained non-ASCII symbol so skipping a high letter cannot inflate total/pairs.
                pairs += 1
                if prev_order != 0_u8 && i + 1 < size && (map_ptr[ptr[i + 1]] & ORDER_MASK) > 0_u8
                  # A non-ASCII symbol embedded directly between word letters usually signals a misdecoded letter.
                  w -= CASE_DROP_PENALTY
                end
              end
              total += w
              pairs += 1
            elsif is_high
              pairs += 1
            end
            prev_order = order
            prev_kind = kind
            prev_high_letter = curr_high_letter
            prev_ascii_letter = curr_ascii_letter
          end

          i += 1
        end

        if prev_order != 0_u8
          total += bigrams_ptr[prev_order.to_i32 << ROW_SHIFT].to_i32
          pairs += 1
        end

        long_run_bytes += high_run if high_run >= 3

        if @requires_high_letters
          return nil if high_letters == 0 || isolated_high.to_i64 * 2 > high_letters || mixed_script_boundaries.to_i64 * 3 > high_letters
        elsif long_run_bytes.to_i64 * 2 > stats.high_bytes && mixed_script_boundaries == 0
          # NOTE: run-length heuristic, because this model also scores ASCII bigrams
          # and so outscores the Cyrillic probers on mixed English/Cyrillic text.
          return nil
        end

        # No scorable letter pairs (e.g. "100 \xA4"): symbols alone are weak evidence.
        if (size == 1 || (high_letters == 0 && total == 0) || pairs == 0) && !@requires_high_letters && junk_count == 0
          return Match.new(@encoding, 0.25, language: @model.language)
        end

        return nil if pairs == 0

        avg = total.to_f64 / (pairs * SCORE_SCALE)
        return nil if avg <= 0.0

        avg *= SYMBOL_ONLY_FACTOR if !@requires_high_letters && high_letters == 0
        avg *= ALL_CAPS_FACTOR if upper_letters >= 2 && lower_letters == 0

        confidence = 0.25 + 0.74 * (avg / (avg + 0.8))
        Match.new(@encoding, confidence, language: @model.language)
      end

      @[AlwaysInline]
      private def high_letter?(map_ptr : Pointer(UInt8), byte : UInt8) : Bool
        byte >= 0x80_u8 && (map_ptr[byte] & ORDER_MASK) > 0_u8
      end
    end
  end
end
