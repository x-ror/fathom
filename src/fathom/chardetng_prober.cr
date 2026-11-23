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
        hebrew_ok = detector.windows_1255_decodable?

        # Best score per supported canonical encoding, in candidate order.
        entries = StaticArray({String, Int64}, Detector::MAX_SCORES).new({"", 0_i64})
        count = 0
        ptr = entries.to_unsafe

        detector.each_score do |name, score|
          encoding = fold(name, hebrew_ok)
          next unless Encoding::SUPPORTED.includes?(encoding)

          found = false
          i = 0
          while i < count
            entry = ptr[i]
            if entry[0] == encoding
              ptr[i] = {encoding, score} if score > entry[1]
              found = true
              break
            end
            i += 1
          end
          unless found
            ptr[count] = {encoding, score}
            count += 1
          end
        end
        return if count == 0

        winner = fold(guess, hebrew_ok)
        winner_score = score_for(ptr, count, winner)
        if max > 0 && winner_score
          max = winner_score if winner_score > max
        else
          # Unsupported or non-scoring guess: fall back to the best supported candidate.
          best_idx = 0
          best = ptr[0][1]
          i = 1
          while i < count
            if ptr[i][1] > best
              best = ptr[i][1]
              best_idx = i
            end
            i += 1
          end

          if best > 0
            winner = ptr[best_idx][0]
            max = best
          else
            if (default_score = score_for(ptr, count, DEFAULT_ENCODING)) && default_score >= best
              winner = DEFAULT_ENCODING
              win_score = default_score
            else
              winner = ptr[best_idx][0]
              win_score = best
            end
            confidence = win_score == 0 ? TIE_CONFIDENCE : WEAK_CONFIDENCE
            yield Match.new(winner, confidence, language: language(winner, bytes, stats))
            return
          end
        end

        runner_up = 0_i64
        i = 0
        while i < count
          encoding, score = ptr[i]
          runner_up = score if encoding != winner && score > runner_up
          i += 1
        end
        margin = (max - runner_up).to_f64
        confidence = TIE_CONFIDENCE + (0.99 - TIE_CONFIDENCE) * margin / (margin + MARGIN_SCALE)
        yield Match.new(winner, confidence, language: language(winner, bytes, stats))

        i = 0
        while i < count
          encoding, score = ptr[i]
          if encoding != winner && score > 0
            yield Match.new(encoding, 0.49 * score / max)
          end
          i += 1
        end
      end

      # Canonical name for a chardetng guess. Visual Hebrew (`ISO-8859-8`) folds to
      # `WINDOWS-1255` only when valid `windows-1255` (`0xDF` is undefined there);
      # otherwise it stays `ISO-8859-8`, which Fathom doesn't report, and the next
      # candidate wins.
      private def fold(name : String, hebrew_ok : Bool) : String
        return (hebrew_ok ? "WINDOWS-1255" : name) if name == ISO_8859_8_DATA.encoding
        Encoding.canonical_name(name)
      end

      private def score_for(ptr : Pointer({String, Int64}), count : Int32, encoding : String) : Int64?
        i = 0
        while i < count
          return ptr[i][1] if ptr[i][0] == encoding
          i += 1
        end
        nil
      end

      # Language of the best-matching single-language bigram model for *encoding*, if any.
      private def language(encoding : String, bytes : Bytes, stats : ByteStats) : String?
        case encoding
        when "KOI8-R", "IBM866"           then return "ru"
        when "KOI8-U"                     then return "uk"
        when "WINDOWS-1253", "ISO-8859-7" then return "el"
        when "WINDOWS-1254"               then return "tr"
        when "WINDOWS-1255"               then return "he"
        when "WINDOWS-1256", "ISO-8859-6" then return "ar"
        when "WINDOWS-874"                then return "th"
        when "WINDOWS-1252", "IBM437", "IBM850", "MACINTOSH"
          return nil
        end

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
