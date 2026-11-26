require "./spec_helper"

private GATE_CORPUS_DIR  = File.expand_path("fixtures/corpus", __DIR__)
private GATE_SLICE_SIZES = [64, 256, nil]

# Regression gate over a subset of `corpus/` (`_1.txt` / `dos_1.txt` fixtures in `spec/fixtures/corpus/`,
# except `ISO-8859-13` which uses `lt_3.txt` + `lv_1.txt` because `lt_1.txt` contains none of its
# distinguishing quote bytes `0xA1`/`0xA5`/`0xB4`/`0xFF` and tie-breaks to `WINDOWS-1257`).
# Note: this fixture overlaps `corpus/` and is a regression guard rather than an independent held-out benchmark.
# Floors are set to measured accuracy rounded down to 2 decimals; raise when accuracy improves and document any trade-offs.
# `ISO-8859-13` recall (`0.33`) and `WINDOWS-1257` precision (`0.57`) reflect short `64B`/`256B` slices before the
# first distinguishing quote byte, which are byte-identical to `WINDOWS-1257` and resolve to `WINDOWS-1257` by tie-break order.
# Re-baselined for the chardetng-based detector: see CHANGELOG for the per-encoding trade-offs.
private GATE_THRESHOLDS = {
  "BIG5"           => {precision: 1.00, recall: 1.00},
  "EUC-JP"         => {precision: 1.00, recall: 1.00},
  "EUC-KR"         => {precision: 1.00, recall: 1.00},
  "GBK"            => {precision: 1.00, recall: 1.00},
  "IBM437"         => {precision: 1.00, recall: 1.00},
  "IBM850"         => {precision: 1.00, recall: 0.77},
  "IBM852"         => {precision: 0.90, recall: 1.00},
  "IBM866"         => {precision: 1.00, recall: 1.00},
  "ISO-2022-JP"    => {precision: 1.00, recall: 1.00},
  "ISO-8859-13"    => {precision: 1.00, recall: 0.33},
  "ISO-8859-2"     => {precision: 1.00, recall: 0.83},
  "ISO-8859-5"     => {precision: 1.00, recall: 1.00},
  "ISO-8859-6"     => {precision: 1.00, recall: 1.00},
  "ISO-8859-7"     => {precision: 1.00, recall: 1.00},
  "KOI8-R"         => {precision: 0.75, recall: 1.00},
  "KOI8-U"         => {precision: 1.00, recall: 0.66},
  "MACINTOSH"      => {precision: 1.00, recall: 0.86},
  "SHIFT_JIS"      => {precision: 1.00, recall: 1.00},
  "UTF-16BE"       => {precision: 1.00, recall: 1.00},
  "UTF-16LE"       => {precision: 1.00, recall: 1.00},
  "UTF-32BE"       => {precision: 1.00, recall: 1.00},
  "UTF-32LE"       => {precision: 1.00, recall: 1.00},
  "UTF-8"          => {precision: 1.00, recall: 1.00},
  "WINDOWS-1250"   => {precision: 0.63, recall: 0.77},
  "WINDOWS-1251"   => {precision: 1.00, recall: 1.00},
  "WINDOWS-1252"   => {precision: 0.85, recall: 1.00},
  "WINDOWS-1253"   => {precision: 1.00, recall: 1.00},
  "WINDOWS-1254"   => {precision: 1.00, recall: 1.00},
  "WINDOWS-1255"   => {precision: 1.00, recall: 1.00},
  "WINDOWS-1256"   => {precision: 1.00, recall: 1.00},
  "WINDOWS-1257"   => {precision: 0.55, recall: 0.83},
  "WINDOWS-874"    => {precision: 1.00, recall: 1.00},
  "X-MAC-CYRILLIC" => {precision: 1.00, recall: 1.00},
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
          # (Escape sequences make 7-bit ISO-2022-JP more than ASCII.)
          next if !expected.starts_with?("UTF") && slice.all? { |b| b < 0x80 } && !slice.includes?(0x1B_u8)
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

    # Every full sample in the CI gate must be detected accurately.
    results.select { |r| r[:size_limit].nil? }.each do |r|
      r[:actual].should eq r[:expected]
    end
  end
end
