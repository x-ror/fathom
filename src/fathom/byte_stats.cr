module Fathom
  # Summary statistics collected in a single zero-allocation pass over a byte sample.
  #
  # Probers inspect these precomputed counts to skip irrelevant checks or quickly
  # distinguish ASCII, UTF-16, and binary payloads.
  struct ByteStats
    # Total number of bytes analyzed in the sample.
    getter size : Int32

    # Count of non-ASCII bytes (`>= 0x80`).
    getter high_bytes : Int32

    # Total count of `0x00` bytes.
    getter null_bytes : Int32

    # Count of `0x00` bytes at even byte offsets (`0, 2, 4, ...`).
    getter even_nulls : Int32

    # Count of `0x00` bytes at odd byte offsets (`1, 3, 5, ...`).
    getter odd_nulls : Int32

    # Count of binary C0/DEL control bytes (excluding common text whitespace and ESC).
    getter control_bytes : Int32

    def initialize(
      @size : Int32,
      @high_bytes : Int32,
      @null_bytes : Int32,
      @even_nulls : Int32,
      @odd_nulls : Int32,
      @control_bytes : Int32,
    )
    end

    # Returns `true` if the sample contains only printable ASCII / whitespace bytes.
    def ascii? : Bool
      @high_bytes == 0 && @null_bytes == 0 && @control_bytes == 0
    end

    # Returns `true` if more than 5% of the sample consists of binary control bytes,
    # or more than 25% are NUL bytes (a single NUL, such as a C string terminator, is allowed).
    def likely_binary? : Bool
      return false if @size == 0
      @control_bytes.to_i64 * 20 > @size || (@null_bytes > 1 && @null_bytes.to_i64 * 4 > @size)
    end

    # Analyzes *bytes* in a single tight pass without heap allocations.
    def self.analyze(bytes : Bytes) : ByteStats
      size = bytes.size
      ptr = bytes.to_unsafe
      high = 0
      nulls = 0
      even_nulls = 0
      odd_nulls = 0
      controls = 0

      i = 0
      while i < size
        b = ptr[i]
        if b >= 0x80_u8
          high += 1
        elsif b == 0x00_u8
          nulls += 1
          if (i & 1) == 0
            even_nulls += 1
          else
            odd_nulls += 1
          end
        elsif b < 0x20_u8
          # Allow \t (0x09), \n (0x0A), \v (0x0B), \f (0x0C), \r (0x0D), ESC (0x1B)
          if b < 0x09_u8 || (b > 0x0D_u8 && b != 0x1B_u8)
            controls += 1
          end
        elsif b == 0x7F_u8
          controls += 1
        end
        i += 1
      end

      new(size, high, nulls, even_nulls, odd_nulls, controls)
    end
  end
end
