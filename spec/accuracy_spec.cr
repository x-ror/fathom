require "./spec_helper"

private GATE_CORPUS_DIR  = File.expand_path("fixtures/corpus", __DIR__)
private GATE_SLICE_SIZES = [64, 256, nil]

# Floors set to the measured accuracy on the Wikipedia gate fixture
# (regenerate with tools/gen_corpus.cr). Raise them when accuracy improves; never lower them silently.
private GATE_THRESHOLDS = {
  "IBM866"       => {precision: 1.00, recall: 1.00},
  "ISO-8859-5"   => {precision: 1.00, recall: 1.00},
  "KOI8-R"       => {precision: 1.00, recall: 1.00},
  "KOI8-U"       => {precision: 1.00, recall: 1.00},
  "UTF-16BE"     => {precision: 1.00, recall: 1.00},
  "UTF-16LE"     => {precision: 1.00, recall: 1.00},
  "UTF-32BE"     => {precision: 1.00, recall: 1.00},
  "UTF-32LE"     => {precision: 1.00, recall: 1.00},
  "UTF-8"        => {precision: 1.00, recall: 1.00},
  "WINDOWS-1251" => {precision: 1.00, recall: 1.00},
  "WINDOWS-1252" => {precision: 1.00, recall: 1.00},
}

describe "Accuracy regression gate" do
  it "meets per-encoding precision and recall thresholds on the CI corpus" do
    results = [] of {expected: String, actual: String?, size_limit: Int32?}

    Dir.children(GATE_CORPUS_DIR).sort.each do |entry|
      subdir = File.join(GATE_CORPUS_DIR, entry)
      next unless File.directory?(subdir)

      expected = Fathom::Encoding.canonical_name(entry)
      Dir.children(subdir).sort.each do |filename|
        path = File.join(subdir, filename)
        next unless File.file?(path)

        bytes = File.open(path, "rb", &.getb_to_end)
        GATE_SLICE_SIZES.each do |limit|
          slice = limit ? bytes[0, Math.min(limit, bytes.size)] : bytes
          next if limit && limit >= bytes.size
          # A pure-ASCII slice of single-byte text is correctly reported as UTF-8; don't count it.
          next if !expected.starts_with?("UTF") && slice.all? { |b| b < 0x80 }
          results << {expected: expected, actual: Fathom.detect(slice), size_limit: limit}
        end
      end
    end

    results.should_not be_empty

    GATE_THRESHOLDS.each do |encoding, threshold|
      tp = results.count { |r| r[:expected] == encoding && r[:actual] == encoding }
      fp = results.count { |r| r[:expected] != encoding && r[:actual] == encoding }
      fn = results.count { |r| r[:expected] == encoding && r[:actual] != encoding }

      (tp + fn).should be > 0

      precision = tp.to_f64 / (tp + fp)
      recall = tp.to_f64 / (tp + fn)

      precision.should be >= threshold[:precision]
      recall.should be >= threshold[:recall]
    end

    # Every >=256B and full sample in the CI gate must be detected accurately.
    results.select { |r| r[:size_limit].nil? || r[:size_limit].not_nil! >= 256 }.each do |r|
      r[:actual].should eq r[:expected]
    end
  end
end
