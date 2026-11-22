module Fathom
  # Configurable encoding detector supporting both in-memory `Bytes` and streaming `IO`.
  #
  # ```
  # detector = Fathom::Detector.new(sample_size: 32_768)
  # match = detector.match(bytes)
  # ```
  struct Detector
    # Default maximum number of leading bytes inspected per input (64 KiB).
    DEFAULT_SAMPLE_SIZE = 65_536

    # Default minimum confidence required for a prober match to be returned.
    DEFAULT_MIN_CONFIDENCE = 0.1

    # Stack buffer size used for small `IO` reads before falling back to heap allocation.
    private STACK_BUFFER_SIZE = 4096

    # Maximum number of leading bytes inspected from an input.
    getter sample_size : Int32

    # Minimum confidence threshold in `0.0..1.0` for returning prober matches.
    getter min_confidence : Float64

    # Probers evaluated for single-byte or custom encodings.
    getter probers : Indexable(Prober)

    # Returns a reusable default detector instance.
    def self.default : Detector
      @@default ||= new
    end

    # Creates a new detector with the specified *sample_size*, *min_confidence*, and *probers*.
    def initialize(
      @sample_size : Int32 = DEFAULT_SAMPLE_SIZE,
      @min_confidence : Float64 = DEFAULT_MIN_CONFIDENCE,
      @probers : Indexable(Prober) = SingleByte::PROBERS,
    )
      raise ArgumentError.new("sample_size must be positive") if @sample_size <= 0
      raise ArgumentError.new("min_confidence must be between 0.0 and 1.0") unless (0.0..1.0).includes?(@min_confidence)
    end

    # Returns the best encoding name for *bytes*, or `nil` if unknown.
    def detect(bytes : Bytes) : String?
      match(bytes).try(&.encoding)
    end

    # Reads up to `#sample_size` bytes from *io* and returns the best encoding name, or `nil`.
    def detect(io : IO) : String?
      match(io).try(&.encoding)
    end

    # Returns the highest-confidence `Match` for *bytes*, or `nil` if unknown.
    def match(bytes : Bytes) : Match?
      best : Match? = nil
      each_candidate(bytes) do |candidate|
        if best.nil? || candidate.confidence > best.confidence
          best = candidate
        end
      end
      best
    end

    # Reads up to `#sample_size` bytes from *io* and returns the highest-confidence `Match`, or `nil`.
    def match(io : IO) : Match?
      with_sample(io) { |sample| match(sample) }
    end

    # Returns all plausible `Match` candidates for *bytes*, sorted by descending confidence.
    def detect_all(bytes : Bytes) : Array(Match)
      matches = [] of Match
      each_candidate(bytes) do |candidate|
        matches << candidate
      end
      matches.sort! { |a, b| b.confidence <=> a.confidence }
      matches
    end

    # Reads up to `#sample_size` bytes from *io* and returns all plausible `Match` candidates
    # sorted by descending confidence.
    def detect_all(io : IO) : Array(Match)
      with_sample(io) { |sample| detect_all(sample) }
    end

    # Detects the encoding of *bytes*, strips any leading BOM, and decodes the payload
    # to a UTF-8 `String`. Returns `nil` when *bytes* looks like binary or an unknown encoding.
    #
    # The *invalid* option (`nil` or `:skip`) is passed through to `String.new` unchanged.
    def decode(bytes : Bytes, invalid : Symbol? = nil) : String?
      m = match(bytes)
      return nil unless m

      payload = if m.bom?
                  bom_len = BOM.byte_size(m.encoding)
                  bytes[bom_len, bytes.size - bom_len]
                else
                  bytes
                end

      String.new(payload, m.iconv_name, invalid: invalid)
    end

    # Reads *io*, detects its encoding from up to `#sample_size` leading bytes,
    # strips any leading BOM, and decodes the full stream to a UTF-8 `String`.
    # Returns `nil` when the stream looks like binary or an unknown encoding.
    #
    # NOTE: The whole stream is read into memory; there is no size limit.
    #
    # The *invalid* option (`nil` or `:skip`) is passed through to `String.new` unchanged.
    def decode(io : IO, invalid : Symbol? = nil) : String?
      buffer = IO::Memory.new
      IO.copy(io, buffer)
      decode(buffer.to_slice, invalid: invalid)
    end

    private def each_candidate(bytes : Bytes, & : Match ->)
      if bytes.empty?
        yield Match.new("UTF-8", 1.0)
        return
      end

      if bom_match = BOM.detect(bytes)
        yield bom_match
        return
      end

      sample = bytes.size > @sample_size ? bytes[0, @sample_size] : bytes
      stats = ByteStats.analyze(sample)

      if stats.ascii?
        yield Match.new("UTF-8", 1.0)
        return
      end

      if stats.null_bytes > 0
        if utf16 = UTF.detect_utf16(sample, stats)
          yield utf16
          return
        end
      end

      if !stats.likely_binary? && UTF.valid_utf8?(sample)
        yield Match.new("UTF-8", 1.0)
        return
      end

      return if stats.null_bytes > 0 || stats.likely_binary?

      if tolerant = UTF.probe_tolerant_utf8(sample, stats)
        yield tolerant if tolerant.confidence >= @min_confidence
      end

      @probers.each do |prober|
        if candidate = prober.probe(sample, stats)
          yield candidate if candidate.confidence >= @min_confidence
        end
      end
    end

    private def with_sample(io : IO, &)
      stack = uninitialized UInt8[STACK_BUFFER_SIZE]
      first_cap = Math.min(@sample_size, STACK_BUFFER_SIZE)
      total = read_up_to(io, stack.to_slice[0, first_cap])

      if total < first_cap || @sample_size <= first_cap
        yield stack.to_slice[0, total]
      else
        heap = Bytes.new(@sample_size)
        stack.to_slice[0, total].copy_to(heap)
        total += read_up_to(io, heap[total, @sample_size - total])
        yield heap[0, total]
      end
    end

    private def read_up_to(io : IO, dest : Bytes) : Int32
      total = 0
      while total < dest.size
        bytes_read = io.read(dest[total, dest.size - total])
        break if bytes_read == 0
        total += bytes_read
      end
      total
    end
  end
end
