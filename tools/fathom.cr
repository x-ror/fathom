require "json"
require "option_parser"
require "../src/fathom"

module FathomCLI
  record EvalResult, expected : String, actual : String?, size_bucket : String

  record Metrics, tp : Int32, fp : Int32, fn : Int32 do
    def precision : Float64
      denom = tp + fp
      denom == 0 ? 0.0 : tp.to_f64 / denom
    end

    def recall : Float64
      denom = tp + fn
      denom == 0 ? 0.0 : tp.to_f64 / denom
    end

    def f1 : Float64
      p = precision
      r = recall
      (p + r) == 0.0 ? 0.0 : 2.0 * p * r / (p + r)
    end
  end

  def self.run(args = ARGV)
    show_all = false
    do_decode = false
    invalid_skip = false
    json_output = false
    corpus_mode = false
    corpus_dir = "corpus"
    sizes_arg = "64,256,1024,4096,full"
    compare_tool : String? = nil
    sample_size = Fathom::Detector::DEFAULT_SAMPLE_SIZE
    min_confidence = Fathom::Detector::DEFAULT_MIN_CONFIDENCE
    files = [] of String

    OptionParser.parse(args) do |p|
      p.banner = <<-BANNER
        Usage: crystal run tools/fathom.cr -- [options] [file...]
               crystal run tools/fathom.cr -- --corpus [dir] [options]

        Inspect file encodings with fathom or evaluate accuracy on a corpus.
        BANNER

      p.on("-a", "--all", "Show all candidate matches sorted by confidence") { show_all = true }
      p.on("-d", "--decode", "Decode input to UTF-8 and write to stdout") { do_decode = true }
      p.on("--invalid-skip", "Pass invalid: :skip to Fathom.decode") { invalid_skip = true }
      p.on("-j", "--json", "Emit JSON output") { json_output = true }
      p.on("-s N", "--sample-size=N", "Maximum bytes inspected per input (default: #{sample_size})") do |v|
        sample_size = v.to_i
      end
      p.on("-m F", "--min-confidence=F", "Minimum prober confidence threshold (default: #{min_confidence})") do |v|
        min_confidence = v.to_f64
      end
      p.on("--corpus", "Run accuracy benchmark on corpus directory") do
        corpus_mode = true
      end
      p.on("--corpus-dir=DIR", "Corpus directory for --corpus (default: #{corpus_dir})") do |v|
        corpus_dir = v
      end
      p.on("--sizes=LIST", "Comma-separated byte slice sizes for --corpus (default: #{sizes_arg})") do |v|
        sizes_arg = v
      end
      p.on("--compare=TOOL", "Compare corpus accuracy against 'icu' or 'uchardet'") do |v|
        compare_tool = v.downcase
      end
      p.on("-h", "--help", "Show this help message") do
        puts p
        exit 0
      end
      p.unknown_args do |remaining|
        files.concat(remaining)
      end
    end

    detector = Fathom::Detector.new(sample_size: sample_size, min_confidence: min_confidence)

    if corpus_mode
      if files.size == 1 && corpus_dir == "corpus"
        corpus_dir = files[0]
      elsif files.size > 1
        STDERR.puts "error: --corpus accepts at most one directory argument"
        exit 1
      end
      run_corpus(detector, corpus_dir, sizes_arg, compare_tool, json_output)
      return
    end

    if files.empty?
      inspect_bytes(detector, "<stdin>", STDIN.getb_to_end, show_all, do_decode, invalid_skip, json_output)
    else
      files.each do |path|
        if path == "-"
          inspect_bytes(detector, "<stdin>", STDIN.getb_to_end, show_all, do_decode, invalid_skip, json_output)
        else
          bytes = File.open(path, "rb", &.getb_to_end)
          inspect_bytes(detector, path, bytes, show_all, do_decode, invalid_skip, json_output)
        end
      end
    end
  end

  private def self.inspect_bytes(
    detector : Fathom::Detector,
    label : String,
    bytes : Bytes,
    show_all : Bool,
    do_decode : Bool,
    invalid_skip : Bool,
    json_output : Bool,
  )
    if do_decode
      invalid = invalid_skip ? :skip : nil
      if decoded = detector.decode(bytes, invalid: invalid)
        print decoded
      else
        STDERR.puts "#{label}: unknown or binary encoding"
        exit 1
      end
      return
    end

    if show_all
      matches = detector.detect_all(bytes)
      if json_output
        puts({
          file:    label,
          bytes:   bytes.size,
          matches: matches.map do |m|
            {
              encoding:   m.encoding,
              iconv_name: m.iconv_name,
              confidence: m.confidence.round(4),
              bom:        m.bom?,
              language:   m.language,
            }
          end,
        }.to_json)
      else
        puts "#{label} (#{bytes.size} bytes):"
        if matches.empty?
          puts "  <unknown>"
        else
          matches.each do |m|
            bom_note = m.bom? ? " [BOM]" : ""
            lang_note = m.language ? ", lang=#{m.language}" : ""
            puts "  #{m.encoding.ljust(14)} conf=#{m.confidence.round(4)}#{bom_note}#{lang_note} (iconv: #{m.iconv_name})"
          end
        end
      end
    else
      m = detector.match(bytes)
      if json_output
        puts({
          file:       label,
          bytes:      bytes.size,
          encoding:   m.try(&.encoding),
          iconv_name: m.try(&.iconv_name),
          confidence: m.try(&.confidence.round(4)),
          bom:        m.try(&.bom?),
          language:   m.try(&.language),
        }.to_json)
      else
        if m
          bom_note = m.bom? ? " [BOM]" : ""
          lang_note = m.language ? ", lang=#{m.language}" : ""
          puts "#{label}: #{m.encoding} (confidence=#{m.confidence.round(4)}#{bom_note}#{lang_note}, iconv=#{m.iconv_name})"
        else
          puts "#{label}: <unknown>"
        end
      end
    end
  end

  private def self.parse_sizes(spec : String) : Array(Int32?)
    spec.split(',').map do |part|
      s = part.strip.downcase
      s == "full" ? nil : s.to_i
    end
  end

  private def self.run_corpus(
    detector : Fathom::Detector,
    corpus_dir : String,
    sizes_arg : String,
    compare_tool : String?,
    json_output : Bool,
  )
    unless Dir.exists?(corpus_dir)
      STDERR.puts "error: corpus directory not found: #{corpus_dir}"
      exit 1
    end

    sizes = parse_sizes(sizes_arg)
    samples = collect_samples(corpus_dir, sizes)
    if samples.empty?
      STDERR.puts "error: no corpus samples found under #{corpus_dir}/<ENCODING>/*"
      exit 1
    end

    fathom_results = samples.map do |expected, bucket, slice|
      actual = detector.detect(slice)
      EvalResult.new(expected, actual, bucket)
    end

    compare_results = case compare_tool
                      when "uchardet"
                        evaluate_uchardet(samples)
                      when "icu"
                        evaluate_icu(samples)
                      when nil
                        nil
                      else
                        STDERR.puts "error: unsupported --compare tool '#{compare_tool}' (expected 'icu' or 'uchardet')"
                        exit 1
                      end

    if json_output
      emit_corpus_json(fathom_results, compare_tool, compare_results)
    else
      print_corpus_report("Fathom", fathom_results)
      if compare_results && compare_tool
        puts
        print_corpus_report(compare_tool.upcase, compare_results)
        supported = compare_results.compact_map(&.actual).to_set
        shared_fathom = fathom_results.select { |r| supported.includes?(r.expected) }
        shared_compare = compare_results.select { |r| supported.includes?(r.expected) }
        unless shared_fathom.empty?
          shared_count = shared_fathom.map(&.expected).uniq!.size
          puts
          puts "=== Shared Encodings Only (#{shared_count} corpus encodings output by #{compare_tool.upcase}) ==="
          print_summary_line("Fathom", shared_fathom)
          print_summary_line(compare_tool.upcase, shared_compare)
        end
      end
    end
  end

  private def self.collect_samples(corpus_dir : String, sizes : Array(Int32?)) : Array({String, String, Bytes})
    samples = [] of {String, String, Bytes}
    Dir.children(corpus_dir).sort.each do |entry|
      subdir = File.join(corpus_dir, entry)
      next unless File.directory?(subdir)

      expected = Fathom::Encoding.canonical_name(entry)
      Dir.children(subdir).sort.each do |filename|
        path = File.join(subdir, filename)
        next unless File.file?(path)

        bytes = File.open(path, "rb", &.getb_to_end)
        sizes.each do |limit|
          next if limit && limit >= bytes.size
          slice = limit ? bytes[0, limit] : bytes
          # A pure-ASCII slice of single-byte text is correctly reported as UTF-8; don't count it.
          next if !expected.starts_with?("UTF") && slice.all? { |b| b < 0x80 }
          samples << {expected, limit ? "#{limit}B" : "full", slice}
        end
      end
    end
    samples
  end

  private def self.compute_metrics(results : Array(EvalResult)) : {Hash(String, Metrics), Array({String, Int32, Int32})}
    encodings = results.map(&.expected).uniq!.sort!
    by_enc = {} of String => Metrics

    encodings.each do |enc|
      tp = results.count { |r| r.expected == enc && r.actual == enc }
      fp = results.count { |r| r.expected != enc && r.actual == enc }
      fn = results.count { |r| r.expected == enc && r.actual != enc }
      by_enc[enc] = Metrics.new(tp, fp, fn)
    end

    buckets = results.map(&.size_bucket).uniq!
    by_size = buckets.map do |bucket|
      subset = results.select { |r| r.size_bucket == bucket }
      correct = subset.count { |r| r.expected == r.actual }
      {bucket, correct, subset.size}
    end

    {by_enc, by_size}
  end

  private def self.print_summary_line(label : String, results : Array(EvalResult))
    correct = results.count { |r| r.expected == r.actual }
    acc = results.empty? ? 0.0 : (correct.to_f64 / results.size) * 100.0
    sb = results.reject(&.expected.starts_with?("UTF"))
    sb_note = if !sb.empty? && sb.size < results.size
                sb_ok = sb.count { |r| r.expected == r.actual }
                sb_acc = (sb_ok.to_f64 / sb.size) * 100.0
                " (single-byte: #{sb_ok}/#{sb.size} = #{sb_acc.round(2)}%)"
              else
                ""
              end
    puts "#{label}: #{correct}/#{results.size} = #{acc.round(2)}%#{sb_note}"
  end

  private def self.print_corpus_report(name : String, results : Array(EvalResult))
    by_enc, by_size = compute_metrics(results)
    total_correct = results.count { |r| r.expected == r.actual }
    total_acc = results.empty? ? 0.0 : (total_correct.to_f64 / results.size) * 100.0

    puts "=== #{name} Corpus Accuracy (#{total_correct}/#{results.size} = #{total_acc.round(2)}%) ==="
    sb = results.reject(&.expected.starts_with?("UTF"))
    if !sb.empty? && sb.size < results.size
      sb_correct = sb.count { |r| r.expected == r.actual }
      sb_acc = (sb_correct.to_f64 / sb.size) * 100.0
      puts "Single-byte only: #{sb_correct}/#{sb.size} = #{sb_acc.round(2)}%"
    end
    puts
    puts "| Encoding | Support | Precision | Recall | F1 |"
    puts "| --- | ---: | ---: | ---: | ---: |"
    by_enc.each do |enc, m|
      support = m.tp + m.fn
      puts "| #{enc} | #{support} | #{(m.precision * 100).round(2)}% | #{(m.recall * 100).round(2)}% | #{(m.f1 * 100).round(2)}% |"
    end

    puts
    puts "| Input Size | Correct | Total | Accuracy |"
    puts "| --- | ---: | ---: | ---: |"
    by_size.each do |bucket, correct, total|
      acc = total == 0 ? 0.0 : (correct.to_f64 / total) * 100.0
      puts "| #{bucket} | #{correct} | #{total} | #{acc.round(2)}% |"
    end

    mismatches = results.select { |r| r.expected != r.actual }
    unless mismatches.empty?
      puts
      puts "Mismatches (#{mismatches.size}):"
      grouped = mismatches.group_by { |r| {r.expected, r.actual || "<nil>", r.size_bucket} }
      grouped.each do |(exp, act, bucket), items|
        puts "  #{exp} -> #{act} @ #{bucket} (x#{items.size})"
      end
    end
  end

  private def self.emit_corpus_json(
    fathom_results : Array(EvalResult),
    compare_tool : String?,
    compare_results : Array(EvalResult)?,
  )
    payload = {
      fathom:  metrics_json(fathom_results),
      compare: compare_tool && compare_results ? {tool: compare_tool, results: metrics_json(compare_results)} : nil,
    }
    puts payload.to_json
  end

  private def self.metrics_json(results : Array(EvalResult))
    by_enc, by_size = compute_metrics(results)
    total_correct = results.count { |r| r.expected == r.actual }
    {
      total:     results.size,
      correct:   total_correct,
      accuracy:  results.empty? ? 0.0 : total_correct.to_f64 / results.size,
      encodings: by_enc.transform_values { |m| # ameba:disable Style/MultilineCurlyBlock
 {tp: m.tp, fp: m.fp, fn: m.fn, precision: m.precision.round(4), recall: m.recall.round(4), f1: m.f1.round(4)} },
      sizes: by_size.map { |bucket, correct, total| # ameba:disable Style/MultilineCurlyBlock
 {size: bucket, correct: correct, total: total, accuracy: total == 0 ? 0.0 : (correct.to_f64 / total).round(4)} },
    }
  end

  # Fathom reports pure ASCII as UTF-8, so count other tools' ASCII answers the same way
  # (WHATWG would map the label to WINDOWS-1252).
  private def self.normalize_label(raw : String) : String
    {"ASCII", "US-ASCII"}.includes?(raw.upcase) ? "UTF-8" : Fathom::Encoding.canonical_name(raw)
  end

  private def self.evaluate_uchardet(samples : Array({String, String, Bytes})) : Array(EvalResult)
    exe = Process.find_executable("uchardet")
    unless exe
      STDERR.puts "error: 'uchardet' executable not found in PATH"
      exit 1
    end

    samples.map do |expected, bucket, slice|
      stdout = IO::Memory.new
      Process.run(exe, input: IO::Memory.new(slice), output: stdout)
      raw = stdout.to_s.strip
      actual = (raw.empty? || raw == "unknown") ? nil : normalize_label(raw)
      EvalResult.new(expected, actual, bucket)
    end
  end

  private def self.evaluate_icu(samples : Array({String, String, Bytes})) : Array(EvalResult)
    icu_config = Process.find_executable("icu-config") ||
                 ["/opt/homebrew/opt/icu4c/bin/icu-config", "/usr/local/opt/icu4c/bin/icu-config"]
                   .find { |p| File.exists?(p) && File::Info.executable?(p) } ||
                 ""
    if icu_config.empty?
      STDERR.puts "error: 'icu-config' not found; install icu4c to run ICU comparison"
      exit 1
    end

    cflags = `#{icu_config} --cppflags`.strip
    ldflags = `#{icu_config} --ldflags --ldflags-icuio`.strip.gsub("-licuio", "")

    c_src = <<-C
      #include <stdio.h>
      #include <stdlib.h>
      #include <unicode/ucsdet.h>

      int main(void) {
        size_t cap = 65536, len = 0;
        char *buf = malloc(cap);
        size_t n;
        while ((n = fread(buf + len, 1, cap - len, stdin)) > 0) {
          len += n;
          if (len == cap) {
            cap *= 2;
            buf = realloc(buf, cap);
          }
        }
        UErrorCode status = U_ZERO_ERROR;
        UCharsetDetector *det = ucsdet_open(&status);
        ucsdet_setText(det, buf, (int32_t)len, &status);
        const UCharsetMatch *match = ucsdet_detect(det, &status);
        if (match && U_SUCCESS(status)) {
          const char *name = ucsdet_getName(match, &status);
          if (name) puts(name);
        }
        ucsdet_close(det);
        free(buf);
        return 0;
      }
      C

    c_path = File.join(Dir.tempdir, "fathom_icu_detect.c")
    bin_path = File.join(Dir.tempdir, "fathom_icu_detect")
    File.write(c_path, c_src)
    compile_status = Process.run("cc #{c_path} #{cflags} #{ldflags} -o #{bin_path}", shell: true)
    unless compile_status.success?
      STDERR.puts "error: failed to compile ICU helper"
      exit 1
    end

    samples.map do |expected, bucket, slice|
      stdout = IO::Memory.new
      Process.run(bin_path, input: IO::Memory.new(slice), output: stdout)
      raw = stdout.to_s.strip
      actual = raw.empty? ? nil : normalize_label(raw)
      EvalResult.new(expected, actual, bucket)
    end
  ensure
    File.delete(c_path) if c_path && File.exists?(c_path)
    File.delete(bin_path) if bin_path && File.exists?(bin_path)
  end
end

FathomCLI.run
