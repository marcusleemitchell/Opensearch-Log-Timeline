#!/usr/bin/env ruby
# frozen_string_literal: true
#
# log_timeline.rb — turns an OpenSearch/Kibana "On_demand_report" .xlsx export
# into a standalone interactive HTML timeline (status-coded, drill-down).
#
# Usage:
#   ruby log_timeline.rb report1.xlsx [report2.xlsx ...]
#   ruby log_timeline.rb --out-dir ./timelines *.xlsx
#
# Requires the `roo` gem:
#   gem install roo
#
# For each input file, writes <basename>_timeline.html next to it
# (or into --out-dir if given).

require 'roo'
require 'json'
require 'optparse'
require 'time'
require 'pathname'

TEMPLATE_PATH = File.join(__dir__, 'template.html')

COLUMN_MAP = {
  ts:            '_source.@timestamp',
  severity:      '_source.log_data.severity',
  method:        '_source.log_data.method',
  path:          '_source.log_data.path',
  status:        '_source.log_data.status',
  duration:      '_source.log_data.duration',
  event:         '_source.log_data.event',
  request_id:    '_source.log_data.request_id',
  message:       '_source.log_data.message',
  pod:           '_source.kubernetes.pod_name',
  ip:            '_source.log_data.ip',
  count:         '_source.log_data.revenue_center.count',
  check_numbers: '_source.log_data.revenue_center.check_numbers',
  started_at:    '_source.log_data.started_at',
}.freeze

# Kibana's "Jun 12, 2026 @ 13:21:39.868" display format
TIMESTAMP_FORMAT = '%b %d, %Y @ %H:%M:%S.%L'

def blank?(val)
  val.nil? || (val.is_a?(String) && val.strip.empty?)
end

def parse_kibana_timestamp(raw)
  return nil if blank?(raw)

  if raw.is_a?(Time) || raw.is_a?(DateTime)
    Time.parse(raw.to_s)
  else
    Time.strptime(raw.to_s, TIMESTAMP_FORMAT)
  end
rescue ArgumentError
  # fall back to generic parsing if the exact Kibana format doesn't match
  Time.parse(raw.to_s)
end

def parse_started_at(raw)
  return nil if blank?(raw)

  raw.is_a?(String) ? Time.parse(raw) : Time.parse(raw.to_s)
end

def classify(rec)
  return 'http' unless blank?(rec[:status])
  return 'worker' unless blank?(rec[:event])
  return 'apns' unless blank?(rec[:message])

  'other'
end

def extract_records(xlsx_path)
  sheet = Roo::Spreadsheet.open(xlsx_path).sheet(0)
  header_row = sheet.row(1)
  col_index = {}
  COLUMN_MAP.each do |key, col_name|
    idx = header_row.index(col_name)
    col_index[key] = idx
  end

  missing = col_index.select { |_, idx| idx.nil? }
  unless missing.empty?
    warn "  warning: columns not found in #{File.basename(xlsx_path)}: #{missing.keys.join(', ')}"
  end

  records = []

  (2..sheet.last_row).each do |row_num|
    row = sheet.row(row_num)
    rec = {}
    COLUMN_MAP.each_key do |key|
      idx = col_index[key]
      rec[key] = idx ? row[idx] : nil
    end

    next if blank?(rec[:ts]) # skip rows with no timestamp, nothing to plot

    ts = parse_kibana_timestamp(rec[:ts])
    next if ts.nil?

    rec[:ts_iso] = ts.utc.strftime('%Y-%m-%dT%H:%M:%S.%LZ')
    rec[:ts_epoch] = ts.to_f
    rec.delete(:ts)

    rec[:status] = rec[:status].to_i unless blank?(rec[:status])
    rec[:duration] = rec[:duration].to_f unless blank?(rec[:duration])
    rec[:count] = rec[:count].to_i unless blank?(rec[:count])

    started = parse_started_at(rec[:started_at])
    rec[:started_at] = started ? started.utc.strftime('%Y-%m-%dT%H:%M:%S') : nil

    if !blank?(rec[:check_numbers]) && rec[:check_numbers].is_a?(String)
      begin
        rec[:check_numbers] = JSON.parse(rec[:check_numbers])
      rescue JSON::ParserError
        rec[:check_numbers] = nil
      end
    end

    rec[:type] = classify(rec)
    records << rec
  end

  records.sort_by! { |r| r[:ts_epoch] }
  records
end

# Derive the app name from the common leading segment of pod names.
# e.g. "chq-master-sidekiq-worker-…" and "chq-master-647c5d55fc-…" → "chq-master"
def derive_app_name(records)
  pods = records.map { |r| r[:pod].to_s }.reject(&:empty?).uniq
  return nil if pods.empty?

  # Split each pod name on '-', accumulate the longest common prefix of segments
  parts = pods.map { |p| p.split('-') }
  common = parts.first.dup
  parts[1..].each do |segs|
    common = common.zip(segs).take_while { |a, b| a == b }.map(&:first)
  end
  # Drop trailing segments that look like k8s hash suffixes (5-10 hex/alnum chars)
  common.pop while common.last&.match?(/\A[a-f0-9]{5,10}\z/i)
  common.empty? ? nil : common.join('-')
end

def build_header_meta(records)
  return {} if records.empty?

  start_t = Time.at(records.first[:ts_epoch]).utc.strftime('%H:%M:%S')
  end_t   = Time.at(records.last[:ts_epoch]).utc.strftime('%H:%M:%S')
  date    = Time.at(records.first[:ts_epoch]).utc.strftime('%Y-%m-%d')

  # Scan path and message fields for the most-frequent identifiers
  check_numbers = Hash.new(0)
  global_ids    = Hash.new(0)
  check_ids     = Hash.new(0)

  records.each do |rec|
    [rec[:path].to_s, rec[:message].to_s].each do |text|
      text.scan(/check_number[=:](\w+)/).each   { |m| check_numbers[m[0]] += 1 }
      text.scan(/global_id[=:](\w+)/).each      { |m| global_ids[m[0]]    += 1 }
      text.scan(/check_id[=:]([\w-]+)/).each    { |m| check_ids[m[0]]     += 1 }
    end
  end

  {
    check_number: check_numbers.max_by { |_, v| v }&.first,
    global_id:    global_ids.max_by    { |_, v| v }&.first,
    check_id:     check_ids.max_by     { |_, v| v }&.first,
    app_name:     derive_app_name(records),
    start_t:      start_t,
    end_t:        end_t,
    date:         date,
    count:        records.size,
  }
end

def render_html(records, page_title)
  template = File.read(TEMPLATE_PATH)
  records_json = JSON.generate(records)
  meta = build_header_meta(records)

  template
    .gsub('%RECORDS_JSON%') { records_json }
    .gsub('%PAGE_TITLE%')   { page_title }
    .gsub('%META_JSON%')    { JSON.generate(meta) }
end

def process_file(xlsx_path, out_dir)
  puts "Processing #{xlsx_path}..."
  records = extract_records(xlsx_path)

  if records.empty?
    warn "  no usable rows found, skipping"
    return
  end

  basename = Pathname.new(xlsx_path).basename('.*').to_s
  out_path = File.join(out_dir || Pathname.new(xlsx_path).dirname, "#{basename}_timeline.html")

  html = render_html(records, basename)

  leftover = html[/%[A-Z_]+%/]
  if leftover
    warn "  error: template placeholder #{leftover} was not substituted, aborting write for this file"
    return
  end

  File.write(out_path, html)

  http_count = records.count { |r| r[:type] == 'http' }
  error_count = records.count { |r| r[:type] == 'http' && r[:status] >= 400 }
  puts "  #{records.size} entries (#{http_count} http, #{error_count} 4xx/5xx) -> #{out_path}"

  out_path
end

if __FILE__ == $PROGRAM_NAME
  options = { out_dir: nil }
  parser = OptionParser.new do |opts|
    opts.banner = 'Usage: ruby log_timeline.rb [--out-dir DIR] file1.xlsx [file2.xlsx ...]'
    opts.on('--out-dir DIR', 'Write all output HTML files into DIR instead of next to each input') do |dir|
      options[:out_dir] = dir
    end
  end
  parser.parse!

  if ARGV.empty?
    warn parser.banner
    exit 1
  end

  unless File.exist?(TEMPLATE_PATH)
    warn "template.html not found next to this script (expected at #{TEMPLATE_PATH})"
    exit 1
  end

  if options[:out_dir]
    require 'fileutils'
    FileUtils.mkdir_p(options[:out_dir])
  end

  out_paths = []

  ARGV.each do |path|
    unless File.exist?(path)
      warn "skipping #{path}: file not found"
      next
    end
    out_path = process_file(path, options[:out_dir])
    out_paths << out_path if out_path
  end

  unless out_paths.empty?
    system('open', *out_paths)
  end
end
