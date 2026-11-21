module Fathom
  # Interface for pluggable character encoding probers.
  #
  # Custom probers can implement this module and be passed to `Detector.new(probers: ...)`
  # to add support for additional encodings (such as CJK or bigram-scored charsets).
  #
  # ```
  # struct MyProber
  #   include Fathom::Prober
  #
  #   def probe(bytes : Bytes, stats : Fathom::ByteStats) : Fathom::Match?
  #     # Inspect bytes/stats and return a Match or nil
  #   end
  # end
  # ```
  module Prober
    # Evaluates *bytes* (with precomputed *stats*) and returns a `Match` if this
    # encoding is plausible, or `nil` otherwise.
    abstract def probe(bytes : Bytes, stats : ByteStats) : Match?
  end
end
