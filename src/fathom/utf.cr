module Fathom
  # Validation and heuristic detection for UTF-8 and BOM-less UTF-16 encodings.
  module UTF
    # Returns `true` if *bytes* is valid UTF-8, allowing an incomplete multi-byte
    # sequence cut off at the end of a truncated sample.
    def self.valid_utf8?(bytes : Bytes) : Bool
      return true if Unicode.valid?(bytes)

      size = bytes.size
      ptr = bytes.to_unsafe

      # Check whether the trailing 1..3 bytes form a valid truncated UTF-8 sequence.
      tail_len = 1
      while tail_len <= 3 && tail_len <= size
        lead_idx = size - tail_len
        lead = ptr[lead_idx]

        expected_len = utf8_sequence_length(lead)
        if expected_len > tail_len && valid_utf8_tail?(ptr, lead_idx, tail_len, lead)
          prefix = bytes[0, lead_idx]
          # Avoid false positives when a single trailing non-ASCII byte (like
          # WINDOWS-1252 "caf\xE9") happens to fall in the UTF-8 lead-byte range.
          if tail_len > 1 || has_high_byte?(prefix)
            return Unicode.valid?(prefix)
          end
        end

        tail_len += 1
      end

      false
    end

    # Detects BOM-less UTF-16LE or UTF-16BE from null-byte parity and code-unit validation.
    def self.detect_utf16(bytes : Bytes, stats : ByteStats) : Match?
      return nil if bytes.size < 4 || stats.null_bytes == 0

      pairs = bytes.size // 2
      le = if stats.odd_nulls >= 2 && stats.odd_nulls.to_i64 * 2 >= pairs && stats.even_nulls.to_i64 * 20 <= pairs
             true
           elsif stats.even_nulls >= 2 && stats.even_nulls.to_i64 * 2 >= pairs && stats.odd_nulls.to_i64 * 20 <= pairs
             false
           else
             return nil
           end

      ptr = bytes.to_unsafe
      expect_low = false
      i = 0
      while i < pairs
        lo = ptr[i * 2]
        hi = ptr[i * 2 + 1]
        unit = le ? (lo.to_u16 | (hi.to_u16 << 8)) : ((lo.to_u16 << 8) | hi.to_u16)

        if expect_low
          return nil unless (0xDC00_u16..0xDFFF_u16).includes?(unit)
          expect_low = false
        else
          return nil if unit == 0x0000_u16
          return nil if unit <= 0x0008_u16 || (unit >= 0x000E_u16 && unit <= 0x001F_u16) || unit == 0x007F_u16
          if (0xD800_u16..0xDBFF_u16).includes?(unit)
            expect_low = true
          elsif (0xDC00_u16..0xDFFF_u16).includes?(unit)
            return nil
          end
        end

        i += 1
      end

      Match.new(le ? "UTF-16LE" : "UTF-16BE", 0.95)
    end

    private def self.utf8_sequence_length(lead : UInt8) : Int32
      case lead
      when 0xC2_u8..0xDF_u8 then 2
      when 0xE0_u8..0xEF_u8 then 3
      when 0xF0_u8..0xF4_u8 then 4
      else                       0
      end
    end

    private def self.valid_utf8_tail?(ptr : Pointer(UInt8), lead_idx : Int32, tail_len : Int32, lead : UInt8) : Bool
      if tail_len >= 2
        b1 = ptr[lead_idx + 1]
        return false unless (0x80_u8..0xBF_u8).includes?(b1)
        return false if lead == 0xE0_u8 && b1 < 0xA0_u8
        return false if lead == 0xED_u8 && b1 > 0x9F_u8
        return false if lead == 0xF0_u8 && b1 < 0x90_u8
        return false if lead == 0xF4_u8 && b1 > 0x8F_u8
      end

      if tail_len == 3
        b2 = ptr[lead_idx + 2]
        return false unless (0x80_u8..0xBF_u8).includes?(b2)
      end

      true
    end

    private def self.has_high_byte?(bytes : Bytes) : Bool
      size = bytes.size
      ptr = bytes.to_unsafe
      i = 0
      while i < size
        return true if ptr[i] >= 0x80_u8
        i += 1
      end
      false
    end
  end
end
