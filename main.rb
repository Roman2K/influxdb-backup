require 'pp'
require 'benchmark'
require 'fileutils'
require 'time'
require 'date'
require 'json'
require 'utils'
require 'metacli'
require 'open3'

module Cmds
  ENV_PREFIX = "INFLUXBU_"
  TIMESTAMP_PAT = '\d.+T.+Z'
  FILE_TIME_FMT = '%Y%m%dT%H%M%SZ'
  LAST_FILENAME = "last.txt"
  DF_BLOCK_SIZE = 'M'
  DF_BLOCK_BYTES = 1024 * 1024

  def self.env(key, default=nil, &transform)
    transform ||= -> v { v }
    val = ENV.fetch(ENV_PREFIX + key) { return default }
    transform[val]
  end

  def self.cmd_backup(
    host: env("HOST", "influxdb:8088"),
    dir: env("DIR", "/tmp/influxdb_backup"),
    dest: env("DEST", "drive:backup/influxdb"),
    min_df: env("MIN_DF", &:to_f),
    debug: env("DEBUG", false) { |v| v == "1" }
  )
    log = Utils::Log.new
    log.level = :debug if debug
    log.info "full backup"
    log.debug "args: #{PP.pp(
      Hash[method(__method__).parameters.map { |typ, var|
        [var, eval(var.to_s)] if typ == :key
      }.compact],
    "").strip}"

    last = log.info("reading last") {
      [`rclone cat "#{dest}/#{LAST_FILENAME}"`, $?]
    }.yield_self { |s, st|
      unless st.success?
        log[exit: $?].error "failed to read last"
        break nil
      end
      case s
      when /^#{TIMESTAMP_PAT}$/
        {"ts" => s}
      when /./
        JSON.load(s).tap do |h|
          ks = %w(ts size)
          Hash === h && (h.keys & ks).size == ks.size \
            or raise "invalid last JSON"
        end
      else
        log[last: s.inspect].warn "invalid last"
        break nil
      end.tap do |h|
        h["time"] = Time.strptime(h.fetch("ts")+"UTC", FILE_TIME_FMT+"%Z")
        log[last: h].info "read last"
      end
    }

    if min_df && last && (sz = last["size"]&./(DF_BLOCK_BYTES))
      free = Utils.df(File.dirname(dir), DF_BLOCK_SIZE)
      fmt = -> n { "%d%s" % [n, DF_BLOCK_SIZE] }
      df_log = log[free: fmt[free], min: fmt[min_df], last: fmt[sz]]
      if free - sz < min_df
        msg = "not enough disk space left"
        df_log.error msg
        raise msg
      end
      df_log.info "sufficient disk space"
    end

    start = Time.now
    begin
      log.info "influxd backup" do
        system "influxd", "backup", "-portable", "-host", host, dir,
          out: "/dev/null" \
          or raise "influxd backup failed"
      end

      # `du -k` instead of `du -b` for compatibility with BusyBox du
      size = `du -k "#{dir}"`.tap { $?.success? or raise "du failed" } \
        [/^(\d+)\s/,1].tap { |s| s or raise "unexpected du output" }.
        to_i * 1024
      log[size: Utils::Fmt.size(size)].info "local backup finished"

      ts = Dir.glob(File.join(dir, "*")).
        map { |f| File.basename(f)[/^(#{TIMESTAMP_PAT})\./, 1] }.
        compact.max \
          || start.getutc.strftime(FILE_TIME_FMT)

      out = "#{dest}/#{ts}.tar"
      log.info "tarring #{dir} => #{out}" do
        tar dir do |tar|
          IO.popen ["rclone", "rcat", out], 'w' do |rcat|
            IO.copy_stream tar, rcat
          end
          $?.success? or raise "rclone rcat failed"
        end
        $?.success? or raise "tar failed"
      end
    ensure
      log.info "rm -rf #{dir}" do
        FileUtils.rm_rf dir
      end
    end

    log.info "writing last" do
      path = "#{dest}/#{LAST_FILENAME}"
      flog = log[path]
      retry_err /\(SSH_FX_PERMISSION_DENIED\)/, flog do |attempt|
        if attempt > 1
          flog.debug "known SFTP permission error, deleting before rcat" do
            system "rclone", "delete", path
          end
        end
        err, st = Open3.popen3 "rclone", "rcat", path do |i,o,e,t|
          JSON.dump({"ts" => ts, "size" => size}, i)
          i.close_write
          [e.read, t.value]
        end
        st.success? or raise ExecError.new("rcat failed", err: err)
      end
    end
  end

  def self.tar(f, &block)
    dir = File.dirname f
    f = File.basename f
    IO.popen ["bash", "-c", "cd $1 && tar c $2", '_', dir, f], 'r', &block
  end

  class ExecError < StandardError
    def initialize(msg, out: nil, err: nil)
      super "%s stdout=%p stderr=%p" % [msg, out, err]
      @out, @err = out, err
    end
    attr_reader :out, :err
  end

  def self.retry_err(re, log)
    max = 2
    cur = 0
    loop do
      cur += 1
      curlog = log[cur: cur, max: max]
      curlog.debug "attempting"
      res = begin
        yield cur
      rescue ExecError => e
        curlog[err: e].debug "exec error"
        cur < max && [e.err, e.out].any? { |s| re === s } or raise
        next
      end
      curlog[res: res].debug "success"
      return res
    end
  end
end

if $0 == __FILE__
  MetaCLI.new(ARGV).run Cmds
end
