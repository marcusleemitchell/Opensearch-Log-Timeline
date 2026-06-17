# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'
require 'tempfile'
require 'json'
require 'time'

# ---------------------------------------------------------------------------
# Minimal fake sheet — defined before the library load so it's available
# whether or not the real roo gem is present.
# ---------------------------------------------------------------------------
module Roo
  class FakeSheet
    attr_reader :rows

    def initialize(rows)
      @rows = rows
    end

    def row(n)
      @rows[n - 1]
    end

    def last_row
      @rows.size
    end
  end
end

# Intercept require 'roo' so the library load below doesn't blow up when the
# gem isn't installed.  When the gem IS already loaded we still need our own
# Spreadsheet stub, so we (re)define it unconditionally after the load.
$LOADED_FEATURES << 'roo' unless $LOADED_FEATURES.include?('roo')
module Roo
  class Spreadsheet
    class << self
      attr_accessor :_fake_sheet
      def open(_path) = new
    end
    def sheet(_index) = self.class._fake_sheet
  end
end

load File.join(__dir__, 'log_timeline.rb')

# Re-apply the stub in case the real gem's load redefined Roo::Spreadsheet.
module Roo
  class Spreadsheet
    class << self
      attr_accessor :_fake_sheet unless method_defined?(:_fake_sheet)
      def open(_path) = new
    end
    def sheet(_index) = self.class._fake_sheet
  end
end

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
HEADERS = COLUMN_MAP.values.freeze

def make_sheet(data_rows)
  Roo::FakeSheet.new([HEADERS] + data_rows)
end

def install_sheet(data_rows)
  Roo::Spreadsheet._fake_sheet = make_sheet(data_rows)
end

# Build a data row whose columns align with HEADERS.
# Keyword args match COLUMN_MAP keys; everything else is nil.
def row_for(ts: nil, severity: nil, method: nil, path: nil, status: nil,
            duration: nil, event: nil, request_id: nil, message: nil,
            pod: nil, ip: nil, count: nil, check_numbers: nil, started_at: nil)
  values = {
    '_source.@timestamp'                        => ts,
    '_source.log_data.severity'                 => severity,
    '_source.log_data.method'                   => method,
    '_source.log_data.path'                     => path,
    '_source.log_data.status'                   => status,
    '_source.log_data.duration'                 => duration,
    '_source.log_data.event'                    => event,
    '_source.log_data.request_id'               => request_id,
    '_source.log_data.message'                  => message,
    '_source.kubernetes.pod_name'               => pod,
    '_source.log_data.ip'                       => ip,
    '_source.log_data.revenue_center.count'     => count,
    '_source.log_data.revenue_center.check_numbers' => check_numbers,
    '_source.log_data.started_at'               => started_at,
  }
  HEADERS.map { |h| values[h] }
end

KIBANA_TS  = 'Jun 12, 2026 @ 13:21:39.868'
KIBANA_TS2 = 'Jun 12, 2026 @ 14:00:00.000'

MINIMAL_TEMPLATE = '<html>%PAGE_TITLE% %RECORDS_JSON% %META_JSON%</html>'

# Point TEMPLATE_PATH at a temp file containing MINIMAL_TEMPLATE for the
# duration of a block.
def with_template
  tf = Tempfile.new(['template', '.html'])
  tf.write(MINIMAL_TEMPLATE)
  tf.flush
  old = Object.send(:remove_const, :TEMPLATE_PATH)
  Object.const_set(:TEMPLATE_PATH, tf.path)
  yield
ensure
  Object.send(:remove_const, :TEMPLATE_PATH)
  Object.const_set(:TEMPLATE_PATH, old)
  tf.close
  tf.unlink
end

# ===========================================================================
# Test classes
# ===========================================================================

class TestBlank < Minitest::Test
  def test_nil_is_blank
    assert blank?(nil)
  end

  def test_empty_string_is_blank
    assert blank?('')
  end

  def test_whitespace_string_is_blank
    assert blank?("  \t\n  ")
  end

  def test_non_blank_string
    refute blank?('hello')
  end

  def test_string_with_leading_trailing_spaces_not_blank
    refute blank?('  hello  ')
  end

  def test_integer_is_not_blank
    refute blank?(0)
  end

  def test_false_is_not_blank
    refute blank?(false)
  end

  def test_array_is_not_blank
    refute blank?([])
  end
end

class TestParseKibanaTimestamp < Minitest::Test
  def test_parses_kibana_format_string
    t = parse_kibana_timestamp('Jun 12, 2026 @ 13:21:39.868')
    assert_instance_of Time, t
    assert_equal 2026,  t.year
    assert_equal 6,     t.month
    assert_equal 12,    t.day
    assert_equal 13,    t.hour
    assert_equal 21,    t.min
    assert_equal 39,    t.sec
  end

  def test_returns_nil_for_nil
    assert_nil parse_kibana_timestamp(nil)
  end

  def test_returns_nil_for_empty_string
    assert_nil parse_kibana_timestamp('')
  end

  def test_returns_nil_for_blank_string
    assert_nil parse_kibana_timestamp('   ')
  end

  def test_passes_through_time_object
    now = Time.now
    result = parse_kibana_timestamp(now)
    # Round-trips through Time#to_s which has 1-second resolution on some platforms
    assert_in_delta now.to_f, result.to_f, 1.0
  end

  def test_passes_through_datetime_object
    dt = DateTime.new(2026, 6, 12, 13, 21, 39)
    result = parse_kibana_timestamp(dt)
    assert_instance_of Time, result
    assert_equal 2026, result.year
    assert_equal 6,    result.month
    assert_equal 12,   result.day
  end

  def test_falls_back_to_generic_parse_for_iso_string
    result = parse_kibana_timestamp('2026-06-12T13:21:39Z')
    assert_instance_of Time, result
    assert_equal 2026, result.year
    assert_equal 6,    result.month
    assert_equal 12,   result.day
  end
end

class TestParseStartedAt < Minitest::Test
  def test_parses_iso_string
    t = parse_started_at('2026-06-12T10:00:00Z')
    assert_instance_of Time, t
    assert_equal 2026, t.year
    assert_equal 6,    t.month
    assert_equal 12,   t.day
    assert_equal 10,   t.utc.hour
  end

  def test_returns_nil_for_nil
    assert_nil parse_started_at(nil)
  end

  def test_returns_nil_for_empty_string
    assert_nil parse_started_at('')
  end

  def test_returns_nil_for_blank_string
    assert_nil parse_started_at('   ')
  end

  def test_accepts_non_string_via_to_s
    t = Time.utc(2026, 1, 15, 9, 30, 0)
    result = parse_started_at(t)
    assert_instance_of Time, result
    assert_equal 2026, result.year
    assert_equal 1,    result.month
    assert_equal 15,   result.day
  end
end

class TestClassify < Minitest::Test
  def test_http_when_status_present
    assert_equal 'http', classify({ status: 200 })
  end

  def test_worker_when_event_present_no_status
    assert_equal 'worker', classify({ status: nil, event: 'job.completed' })
  end

  def test_apns_when_message_present_no_status_or_event
    assert_equal 'apns', classify({ status: nil, event: nil, message: 'push sent' })
  end

  def test_other_when_nothing_present
    assert_equal 'other', classify({ status: nil, event: nil, message: nil })
  end

  def test_http_takes_priority_over_event_and_message
    assert_equal 'http', classify({ status: 404, event: 'something', message: 'oops' })
  end

  def test_worker_takes_priority_over_message
    assert_equal 'worker', classify({ status: nil, event: 'job.start', message: 'hello' })
  end

  def test_blank_string_status_yields_worker
    assert_equal 'worker', classify({ status: '', event: 'job.start', message: nil })
  end

  def test_blank_string_event_and_status_yields_apns
    assert_equal 'apns', classify({ status: '', event: '  ', message: 'push' })
  end
end

class TestDeriveAppName < Minitest::Test
  def test_empty_records_returns_nil
    assert_nil derive_app_name([])
  end

  def test_records_with_no_pod_returns_nil
    records = [{ pod: nil }, { pod: '' }]
    assert_nil derive_app_name(records)
  end

  def test_single_pod_no_hash_suffix
    records = [{ pod: 'myapp-web' }]
    assert_equal 'myapp-web', derive_app_name(records)
  end

  def test_single_pod_strips_k8s_hex_suffix
    # '647c5d55fc' (10 hex chars) and 'ab1cd' (5 hex chars) both match the regex
    records = [{ pod: 'myapp-web-647c5d55fc-ab1cd' }]
    assert_equal 'myapp-web', derive_app_name(records)
  end

  def test_multiple_pods_common_prefix
    # Trailing segments are pure hex so they'll be stripped; 'sidekiq' and 'web'
    # differ after the common 'chq-master' prefix, leaving 'chq-master'.
    records = [
      { pod: 'chq-master-sidekiq-abc12-def34' },
      { pod: 'chq-master-web-abc12-def34' },
    ]
    result = derive_app_name(records)
    assert_equal 'chq-master', result
  end

  def test_no_common_prefix_returns_nil
    records = [
      { pod: 'aaaaa-foo' },
      { pod: 'bbbbb-bar' },
    ]
    assert_nil derive_app_name(records)
  end

  def test_strips_multiple_trailing_hex_segments
    # Both '647c5d55fc' and 'ab12e' are pure hex and get stripped one by one.
    records = [{ pod: 'app-svc-647c5d55fc-ab12e' }]
    assert_equal 'app-svc', derive_app_name(records)
  end

  def test_deduplicates_identical_pods
    # 'abc12' is 5 hex chars and gets stripped; duplicates collapse to one pod.
    records = [
      { pod: 'app-web-abc12' },
      { pod: 'app-web-abc12' },
    ]
    assert_equal 'app-web', derive_app_name(records)
  end

  def test_hex_suffix_exactly_5_chars_stripped
    records = [{ pod: 'app-abc12' }]
    assert_equal 'app', derive_app_name(records)
  end

  def test_segment_longer_than_10_chars_not_stripped
    records = [{ pod: 'app-averylongword' }]
    assert_equal 'app-averylongword', derive_app_name(records)
  end
end

class TestBuildHeaderMeta < Minitest::Test
  def test_empty_records_returns_empty_hash
    assert_equal({}, build_header_meta([]))
  end

  def test_date_derived_from_first_record_epoch
    t = Time.utc(2026, 6, 12, 13, 21, 39)
    records = [
      { ts_epoch: t.to_f, pod: nil, path: nil, message: nil },
    ]
    meta = build_header_meta(records)
    assert_equal '2026-06-12', meta[:date]
  end

  def test_start_and_end_time_from_first_and_last_record
    t1 = Time.utc(2026, 6, 12, 10, 0, 0)
    t2 = Time.utc(2026, 6, 12, 11, 30, 45)
    records = [
      { ts_epoch: t1.to_f, pod: nil, path: nil, message: nil },
      { ts_epoch: t2.to_f, pod: nil, path: nil, message: nil },
    ]
    meta = build_header_meta(records)
    assert_equal '10:00:00', meta[:start_t]
    assert_equal '11:30:45', meta[:end_t]
  end

  def test_count_equals_number_of_records
    t = Time.utc(2026, 6, 12, 8, 0, 0)
    records = Array.new(5) { { ts_epoch: t.to_f, pod: nil, path: nil, message: nil } }
    assert_equal 5, build_header_meta(records)[:count]
  end

  def test_extracts_check_number_from_path
    t = Time.utc(2026, 6, 12, 8, 0, 0)
    records = [
      { ts_epoch: t.to_f, pod: nil, path: '/api?check_number=ABC', message: nil },
      { ts_epoch: t.to_f, pod: nil, path: '/api?check_number=ABC', message: nil },
      { ts_epoch: t.to_f, pod: nil, path: '/api?check_number=XYZ', message: nil },
    ]
    meta = build_header_meta(records)
    assert_equal 'ABC', meta[:check_number]
  end

  def test_extracts_global_id_from_message
    t = Time.utc(2026, 6, 12, 8, 0, 0)
    records = [
      { ts_epoch: t.to_f, pod: nil, path: nil, message: 'global_id=GID001 processed' },
      { ts_epoch: t.to_f, pod: nil, path: nil, message: 'global_id=GID001 retried' },
    ]
    meta = build_header_meta(records)
    assert_equal 'GID001', meta[:global_id]
  end

  def test_extracts_check_id_from_path
    t = Time.utc(2026, 6, 12, 8, 0, 0)
    records = [
      { ts_epoch: t.to_f, pod: nil, path: '/checks/check_id:CK-001', message: nil },
    ]
    meta = build_header_meta(records)
    assert_equal 'CK-001', meta[:check_id]
  end

  def test_most_frequent_identifier_wins
    t = Time.utc(2026, 6, 12, 8, 0, 0)
    records = [
      { ts_epoch: t.to_f, pod: nil, path: '/a?check_number=RARE', message: nil },
      { ts_epoch: t.to_f, pod: nil, path: '/b?check_number=FREQ', message: nil },
      { ts_epoch: t.to_f, pod: nil, path: '/c?check_number=FREQ', message: nil },
    ]
    assert_equal 'FREQ', build_header_meta(records)[:check_number]
  end

  def test_nil_when_no_identifiers_found
    t = Time.utc(2026, 6, 12, 8, 0, 0)
    records = [{ ts_epoch: t.to_f, pod: nil, path: '/plain', message: 'nothing special' }]
    meta = build_header_meta(records)
    assert_nil meta[:check_number]
    assert_nil meta[:global_id]
    assert_nil meta[:check_id]
  end

  def test_app_name_derived_from_pods
    t = Time.utc(2026, 6, 12, 8, 0, 0)
    records = [
      { ts_epoch: t.to_f, pod: 'myapp-web-abc12-zzz', path: nil, message: nil },
      { ts_epoch: t.to_f, pod: 'myapp-worker-def34-yyy', path: nil, message: nil },
    ]
    assert_equal 'myapp', build_header_meta(records)[:app_name]
  end
end

class TestRenderHtml < Minitest::Test
  def setup
    @records = [
      {
        ts_iso:     '2026-06-12T13:21:39.868Z',
        ts_epoch:   Time.utc(2026, 6, 12, 13, 21, 39).to_f,
        status:     200,
        duration:   0.123,
        method:     'GET',
        path:       '/api/health',
        pod:        'app-web-abc12',
        type:       'http',
      },
    ]
  end

  def test_all_placeholders_replaced
    with_template do
      html = render_html(@records, 'My Report')
      refute_match(/%[A-Z_]+%/, html)
    end
  end

  def test_page_title_embedded
    with_template do
      html = render_html(@records, 'My Report')
      assert_includes html, 'My Report'
    end
  end

  def test_records_json_embedded
    with_template do
      html = render_html(@records, 'My Report')
      assert_includes html, '/api/health'
    end
  end

  def test_meta_json_embedded
    with_template do
      html = render_html(@records, 'My Report')
      parsed = JSON.parse(html.scan(/>(\{.*?\})</).flatten.first || '{}') rescue nil
      # At minimum the output is valid HTML containing JSON-serialised meta
      assert_includes html, '2026-06-12'
    end
  end

  def test_records_json_is_valid_json
    with_template do
      html = render_html(@records, 'My Report')
      # Extract the JSON array that was substituted for %RECORDS_JSON%
      json_str = html[/\[.*\]/m]
      assert json_str, 'expected a JSON array in the output'
      parsed = JSON.parse(json_str)
      assert_equal 1, parsed.size
    end
  end
end

class TestExtractRecords < Minitest::Test
  def test_skips_rows_with_blank_timestamp
    install_sheet([
      row_for(ts: nil,       status: '200'),
      row_for(ts: '',        status: '201'),
      row_for(ts: KIBANA_TS, status: '202'),
    ])
    records = nil
    capture_io { records = extract_records('fake.xlsx') }
    assert_equal 1, records.size
  end

  def test_parses_kibana_timestamp_into_iso_and_epoch
    install_sheet([row_for(ts: KIBANA_TS)])
    records = nil
    capture_io { records = extract_records('fake.xlsx') }
    r = records.first
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/, r[:ts_iso])
    assert_kind_of Float, r[:ts_epoch]
    refute r.key?(:ts), ':ts key should be deleted after parsing'
  end

  def test_records_sorted_by_ts_epoch
    install_sheet([
      row_for(ts: KIBANA_TS2),
      row_for(ts: KIBANA_TS),
    ])
    records = nil
    capture_io { records = extract_records('fake.xlsx') }
    assert_equal 2, records.size
    assert records[0][:ts_epoch] <= records[1][:ts_epoch],
           'records should be sorted ascending by ts_epoch'
  end

  def test_status_coerced_to_integer
    install_sheet([row_for(ts: KIBANA_TS, status: '404')])
    records = nil
    capture_io { records = extract_records('fake.xlsx') }
    assert_equal 404, records.first[:status]
    assert_kind_of Integer, records.first[:status]
  end

  def test_duration_coerced_to_float
    install_sheet([row_for(ts: KIBANA_TS, duration: '1.23')])
    records = nil
    capture_io { records = extract_records('fake.xlsx') }
    assert_equal 1.23, records.first[:duration]
    assert_kind_of Float, records.first[:duration]
  end

  def test_count_coerced_to_integer
    install_sheet([row_for(ts: KIBANA_TS, count: '7')])
    records = nil
    capture_io { records = extract_records('fake.xlsx') }
    assert_equal 7, records.first[:count]
    assert_kind_of Integer, records.first[:count]
  end

  def test_check_numbers_json_string_parsed
    install_sheet([row_for(ts: KIBANA_TS, check_numbers: '["A1","B2"]')])
    records = nil
    capture_io { records = extract_records('fake.xlsx') }
    assert_equal ['A1', 'B2'], records.first[:check_numbers]
  end

  def test_invalid_check_numbers_json_becomes_nil
    install_sheet([row_for(ts: KIBANA_TS, check_numbers: 'not-json{')])
    records = nil
    capture_io { records = extract_records('fake.xlsx') }
    assert_nil records.first[:check_numbers]
  end

  def test_started_at_formatted_as_utc_datetime
    install_sheet([row_for(ts: KIBANA_TS, started_at: '2026-06-12T10:00:00Z')])
    records = nil
    capture_io { records = extract_records('fake.xlsx') }
    assert_equal '2026-06-12T10:00:00', records.first[:started_at]
  end

  def test_blank_started_at_becomes_nil
    install_sheet([row_for(ts: KIBANA_TS, started_at: nil)])
    records = nil
    capture_io { records = extract_records('fake.xlsx') }
    assert_nil records.first[:started_at]
  end

  def test_type_set_to_http_when_status_present
    install_sheet([row_for(ts: KIBANA_TS, status: '200')])
    records = nil
    capture_io { records = extract_records('fake.xlsx') }
    assert_equal 'http', records.first[:type]
  end

  def test_type_set_to_worker_when_event_present
    install_sheet([row_for(ts: KIBANA_TS, event: 'job.done')])
    records = nil
    capture_io { records = extract_records('fake.xlsx') }
    assert_equal 'worker', records.first[:type]
  end

  def test_type_set_to_apns_when_message_present
    install_sheet([row_for(ts: KIBANA_TS, message: 'push sent')])
    records = nil
    capture_io { records = extract_records('fake.xlsx') }
    assert_equal 'apns', records.first[:type]
  end

  def test_type_set_to_other_when_nothing_present
    install_sheet([row_for(ts: KIBANA_TS)])
    records = nil
    capture_io { records = extract_records('fake.xlsx') }
    assert_equal 'other', records.first[:type]
  end

  def test_warns_about_missing_columns
    # Use a sheet whose header row has only one known column — all others missing
    partial_headers = ['_source.@timestamp'] + (['unknown_col'] * (HEADERS.size - 1))
    sheet = Roo::FakeSheet.new([partial_headers, row_for(ts: KIBANA_TS)])
    Roo::Spreadsheet._fake_sheet = sheet
    _out, err = capture_io { extract_records('fake.xlsx') }
    assert_match(/warning: columns not found/, err)
  end

  def test_empty_sheet_returns_empty_array
    install_sheet([])
    records = nil
    capture_io { records = extract_records('fake.xlsx') }
    assert_empty records
  end
end

class TestProcessFile < Minitest::Test
  def setup
    # Give every test a fresh temp directory and a valid template
    @tmpdir = Dir.mktmpdir
    @template_path_backup = Object.send(:remove_const, :TEMPLATE_PATH)
    tf = File.join(@tmpdir, 'template.html')
    File.write(tf, MINIMAL_TEMPLATE)
    Object.const_set(:TEMPLATE_PATH, tf)
  end

  def teardown
    Object.send(:remove_const, :TEMPLATE_PATH)
    Object.const_set(:TEMPLATE_PATH, @template_path_backup)
    FileUtils.remove_entry(@tmpdir)
  end

  def fake_xlsx(dir = @tmpdir)
    path = File.join(dir, 'report.xlsx')
    File.write(path, '')
    path
  end

  def test_returns_nil_and_warns_when_no_records
    install_sheet([])
    xlsx = fake_xlsx
    result = nil
    _out, err = capture_io { result = process_file(xlsx, @tmpdir) }
    assert_nil result
    assert_match(/no usable rows found/, err)
  end

  def test_writes_html_file_to_out_dir
    install_sheet([row_for(ts: KIBANA_TS, status: '200')])
    xlsx = fake_xlsx
    out_dir = Dir.mktmpdir
    begin
      capture_io { process_file(xlsx, out_dir) }
      assert File.exist?(File.join(out_dir, 'report_timeline.html'))
    ensure
      FileUtils.remove_entry(out_dir)
    end
  end

  def test_writes_html_next_to_xlsx_when_no_out_dir
    install_sheet([row_for(ts: KIBANA_TS, status: '200')])
    xlsx_dir = Dir.mktmpdir
    begin
      xlsx = File.join(xlsx_dir, 'myreport.xlsx')
      File.write(xlsx, '')
      capture_io { process_file(xlsx, nil) }
      assert File.exist?(File.join(xlsx_dir, 'myreport_timeline.html'))
    ensure
      FileUtils.remove_entry(xlsx_dir)
    end
  end

  def test_returns_output_path
    install_sheet([row_for(ts: KIBANA_TS, status: '200')])
    xlsx = fake_xlsx
    result = nil
    capture_io { result = process_file(xlsx, @tmpdir) }
    assert_equal File.join(@tmpdir, 'report_timeline.html'), result
  end

  def test_html_file_contains_records_json
    install_sheet([row_for(ts: KIBANA_TS, status: '200', path: '/api/test')])
    xlsx = fake_xlsx
    out_path = nil
    capture_io { out_path = process_file(xlsx, @tmpdir) }
    html = File.read(out_path)
    assert_includes html, '/api/test'
  end

  def test_html_has_no_leftover_placeholders
    install_sheet([row_for(ts: KIBANA_TS, status: '200')])
    xlsx = fake_xlsx
    out_path = nil
    capture_io { out_path = process_file(xlsx, @tmpdir) }
    html = File.read(out_path)
    refute_match(/%[A-Z_]+%/, html)
  end

  def test_leftover_placeholder_aborts_write
    # Template with an extra unknown placeholder
    bad_template = MINIMAL_TEMPLATE + ' %UNKNOWN%'
    tf_path = Object.send(:remove_const, :TEMPLATE_PATH)
    bad_tf = File.join(@tmpdir, 'bad_template.html')
    File.write(bad_tf, bad_template)
    Object.const_set(:TEMPLATE_PATH, bad_tf)

    install_sheet([row_for(ts: KIBANA_TS, status: '200')])
    xlsx = fake_xlsx
    result = nil
    _out, err = capture_io { result = process_file(xlsx, @tmpdir) }
    assert_nil result
    assert_match(/error.*placeholder.*was not substituted/, err)
    refute File.exist?(File.join(@tmpdir, 'report_timeline.html'))
  ensure
    Object.send(:remove_const, :TEMPLATE_PATH)
    Object.const_set(:TEMPLATE_PATH, tf_path)
  end

  def test_prints_summary_with_entry_counts
    install_sheet([
      row_for(ts: KIBANA_TS,  status: '200'),
      row_for(ts: KIBANA_TS2, status: '500'),
    ])
    xlsx = fake_xlsx
    out, _err = capture_io { process_file(xlsx, @tmpdir) }
    assert_match(/2 entries/, out)
    assert_match(/2 http/, out)
    assert_match(/1 4xx\/5xx/, out)
  end
end
