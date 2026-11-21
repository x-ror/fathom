require "./fathom/match"
require "./fathom/byte_stats"
require "./fathom/prober"
require "./fathom/bom"
require "./fathom/utf"
require "./fathom/single_byte"
require "./fathom/tables"
require "./fathom/detector"

# Pure-Crystal character encoding detection library.
#
# ```
# encoding = Fathom.detect(bytes) # => "WINDOWS-1251", or nil
# text = String.new(bytes, encoding) if encoding
#
# if m = Fathom.match(bytes)
#   puts "#{m.encoding} (confidence=#{m.confidence}, bom=#{m.bom?})"
# end
# ```
module Fathom
  VERSION = {{ `shards version #{__DIR__}`.chomp.stringify }}

  # Returns the best encoding name (usable with `String.new(bytes, name)`),
  # or `nil` when *bytes* looks like binary or an unknown encoding.
  def self.detect(bytes : Bytes) : String?
    Detector.default.detect(bytes)
  end

  # Reads up to *sample_size* bytes from *io* and returns the best encoding name, or `nil`.
  def self.detect(io : IO, sample_size : Int32 = Detector::DEFAULT_SAMPLE_SIZE) : String?
    detector_for(sample_size).detect(io)
  end

  # Returns the highest-confidence `Match` for *bytes*, or `nil` if unknown.
  def self.match(bytes : Bytes) : Match?
    Detector.default.match(bytes)
  end

  # Reads up to *sample_size* bytes from *io* and returns the highest-confidence `Match`, or `nil`.
  def self.match(io : IO, sample_size : Int32 = Detector::DEFAULT_SAMPLE_SIZE) : Match?
    detector_for(sample_size).match(io)
  end

  # Returns all plausible `Match` candidates for *bytes*, sorted by descending confidence.
  def self.detect_all(bytes : Bytes) : Array(Match)
    Detector.default.detect_all(bytes)
  end

  # Reads up to *sample_size* bytes from *io* and returns all plausible `Match` candidates
  # sorted by descending confidence.
  def self.detect_all(io : IO, sample_size : Int32 = Detector::DEFAULT_SAMPLE_SIZE) : Array(Match)
    detector_for(sample_size).detect_all(io)
  end

  private def self.detector_for(sample_size : Int32) : Detector
    if sample_size == Detector::DEFAULT_SAMPLE_SIZE
      Detector.default
    else
      Detector.new(sample_size: sample_size)
    end
  end
end
