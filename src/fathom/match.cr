module Fathom
  # Represents a detected character encoding candidate along with its confidence score.
  struct Match
    # Canonical encoding name usable with `String.new(bytes, encoding)`.
    getter encoding : String

    # Detection confidence in the range `0.0..1.0`.
    getter confidence : Float64

    # Whether the encoding was identified by a Byte Order Mark (BOM).
    getter? bom : Bool

    # Optional ISO 639-1 language code when the prober targets a single language, or `nil`.
    getter language : String?

    # Creates a new `Match` with the given *encoding*, *confidence*, *bom* flag, and optional *language*.
    def initialize(
      @encoding : String,
      @confidence : Float64,
      @bom : Bool = false,
      @language : String? = nil,
    )
    end

    # Platform `iconv` encoding name usable with `String.new(bytes, match.iconv_name)`.
    def iconv_name : String
      Encoding.iconv_name(@encoding)
    end
  end
end
