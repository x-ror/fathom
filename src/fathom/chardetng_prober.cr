require "./chardetng"

module Fathom
  module Chardetng
    # Built-in single-byte prober backed by the chardetng port (with Fathom's
    # DOS, Mac and KOI8-R extensions).
    #
    # Confidence comes from the margin between the best and the runner-up
    # encoding's score: on the evaluation corpora a margin of 400+ was right
    # ~100% of the time, a tie ~2/3 of the time. When no candidate scores above
    # zero the guess falls back to windows-1252 when it can decode the input.
    struct Prober
      include Fathom::Prober

      # Confidence when no candidate reads the input plausibly (all scores negative).
      WEAK_CONFIDENCE = 0.25

      # Confidence for a tie, including a neutral guess (score 0: the non-ASCII
      # bytes are punctuation in the guessed encoding). Ties were right ~2/3 of
      # the time on the evaluation corpora.
      TIE_CONFIDENCE = 0.6

      # Score margin at which confidence is halfway between `TIE_CONFIDENCE` and 0.99.
      MARGIN_SCALE = 200.0

      private DEFAULT_ENCODING = "WINDOWS-1252"

      # Returns the best `Match` for *bytes*, or `nil` when every candidate is disqualified.
      def probe(bytes : Bytes, stats : ByteStats) : Match?
        each_match(bytes, stats) { |match| return match }
        nil
      end

      # Yields the best `Match` first, then every other positively scored encoding.
      def each_match(bytes : Bytes, stats : ByteStats, & : Match ->) : Nil
        return if stats.high_bytes == 0

        detector = Detector.new(extended: true)
        detector.feed(bytes, last: true)
        guess, max = detector.result

        # Best score per supported canonical encoding, in candidate order.
        scores = {} of String => Int64
        detector.each_score do |name, score|
          encoding = Encoding.canonical_name(name)
          next unless Encoding::SUPPORTED.includes?(encoding)
          scores[encoding] = score if !scores.has_key?(encoding) || score > scores[encoding]
        end
        return if scores.empty?

        winner = Encoding.canonical_name(guess)
        unless max > 0 && scores[winner]? == max
          # Unsupported or non-scoring guess: fall back to the best supported candidate.
          best = scores.max_of { |_, score| score }
          if best > 0
            winner = scores.find! { |_, score| score == best }[0]
            max = best
          else
            winner = scores.has_key?(DEFAULT_ENCODING) ? DEFAULT_ENCODING : scores.find! { |_, score| score == best }[0]
            confidence = scores[winner] == 0 ? TIE_CONFIDENCE : WEAK_CONFIDENCE
            yield Match.new(winner, confidence, language: language(winner, bytes, stats))
            return
          end
        end

        runner_up = 0_i64
        scores.each { |encoding, score| runner_up = score if encoding != winner && score > runner_up }
        margin = (max - runner_up).to_f64
        confidence = TIE_CONFIDENCE + (0.99 - TIE_CONFIDENCE) * margin / (margin + MARGIN_SCALE)
        yield Match.new(winner, confidence, language: language(winner, bytes, stats))

        scores.each do |encoding, score|
          next if encoding == winner || score <= 0
          yield Match.new(encoding, 0.49 * score / max)
        end
      end

      # Language of the best-matching single-language bigram model for *encoding*, if any.
      private def language(encoding : String, bytes : Bytes, stats : ByteStats) : String?
        best : Match? = nil
        SingleByte::PROBERS.each do |table|
          next unless table.is_a?(SingleByte::Table) && table.encoding == encoding && table.model.language
          if (match = table.probe(bytes, stats)) && (best.nil? || match.confidence > best.confidence)
            best = match
          end
        end
        best.try(&.language)
      end
    end
  end
end
