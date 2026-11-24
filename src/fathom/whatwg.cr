require "./whatwg/indexes"

module Fathom
  # Lookups into the WHATWG Encoding Standard indexes (https://encoding.spec.whatwg.org/),
  # which the multi-byte decoders use. Each returns the code point for *pointer*,
  # or `0` when the index has no mapping for it ("null" in the standard).
  #
  # The index data is copyright WHATWG under the BSD 3-Clause License (LICENSE-whatwg).
  # :nodoc:
  module WHATWG
    private BIG5_FIRST_POINTER = 942

    def self.jis0208(pointer : Int32) : Int32
      u16(JIS0208, pointer)
    end

    def self.jis0212(pointer : Int32) : Int32
      u16(JIS0212, pointer)
    end

    def self.iso_2022_jp_katakana(pointer : Int32) : Int32
      u16(ISO_2022_JP_KATAKANA, pointer)
    end

    def self.euc_kr(pointer : Int32) : Int32
      u16(EUC_KR, pointer)
    end

    def self.gb18030(pointer : Int32) : Int32
      u16(GB18030, pointer)
    end

    def self.big5(pointer : Int32) : Int32
      i = pointer - BIG5_FIRST_POINTER
      low = u16(BIG5_LOW, i)
      return 0 if low == 0
      astral = (BIG5_ASTRAL.unsafe_fetch(i >> 3) >> (i & 7)) & 1 == 1
      astral ? low | 0x20000 : low
    end

    # The standard's "index gb18030 ranges code point" algorithm.
    def self.gb18030_ranges(pointer : Int32) : Int32
      return 0 if (pointer > 39419 && pointer < 189000) || pointer > 1237575 || pointer < 0
      return 0xE7C7 if pointer == 7457

      # Last range whose pointer is <= *pointer*.
      lo = 0
      hi = GB18030_RANGES.size // 8 - 1
      while lo < hi
        mid = (lo + hi + 1) // 2
        if u32(GB18030_RANGES, mid * 2) <= pointer
          lo = mid
        else
          hi = mid - 1
        end
      end
      u32(GB18030_RANGES, lo * 2 + 1) + pointer - u32(GB18030_RANGES, lo * 2)
    end

    @[AlwaysInline]
    private def self.u16(table : Bytes, i : Int32) : Int32
      return 0 unless 0 <= i < table.size // 2
      table.unsafe_fetch(i * 2).to_i32 | (table.unsafe_fetch(i * 2 + 1).to_i32 << 8)
    end

    @[AlwaysInline]
    private def self.u32(table : Bytes, i : Int32) : Int32
      table.unsafe_fetch(i * 4).to_i32 |
        (table.unsafe_fetch(i * 4 + 1).to_i32 << 8) |
        (table.unsafe_fetch(i * 4 + 2).to_i32 << 16) |
        (table.unsafe_fetch(i * 4 + 3).to_i32 << 24)
    end
  end
end
