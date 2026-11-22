module Fathom
  # Represents a detected character encoding candidate along with its confidence score.
  struct Match
    # Canonical encoding name usable with `String.new(bytes, encoding)`.
    getter encoding : String

    # Detection confidence in the range `0.0..1.0`.
    getter confidence : Float64

    # Whether the encoding was identified by a Byte Order Mark (BOM).
    getter? bom : Bool

    # Creates a new `Match` with the given *encoding*, *confidence*, and *bom* flag.
    def initialize(@encoding : String, @confidence : Float64, @bom : Bool = false)
    end

    # Platform `iconv` encoding name usable with `String.new(bytes, match.iconv_name)`.
    def iconv_name : String
      Encoding.iconv_name(@encoding)
    end
  end
end
