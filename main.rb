require 'pp'
require 'benchmark'
require 'fileutils'
require 'time'
require 'date'
require 'json'
require 'utils'
require 'metacli'

module Cmds
  ENV_PREFIX = "INFLUXBU_"
  TIMESTAMP_PAT = '\d.+T.+Z'
  BACKUP_DIR_RE = /^#{TIMESTAMP_PAT}$/
  FILE_TIME_FMT = '%Y%m%dT%H%M%SZ'
  CMD_TIME_FMT = '%Y-%m-%dT%H:%M:%SZ'
  LAST_FILENAME = "last.txt"
  RETENTION_DAYS = 30
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
    full: env("FULL", false) { |v| v == "1" },
    min_df: env("MIN_DF")
  )
    min_df = min_df&.to_f

    log = Utils::Log.new
    log.info "%s backup" % [full ? "full" : "incremental"]
    log.debug "args: #{PP.pp(
      Hash[method(__method__).parameters.map { |typ, var|
        [var, eval(var.to_s)] if typ == :key
      }.compact],
    "").strip}"

    today = Date.today
    log.info("getting backups older than %d days old" % RETENTION_DAYS) {
      JSON.parse(`rclone lsjson "#{dest}"`.tap {
        $?.success? or raise "rclone lsjson failed"
      })
    }.select { |e|
      e.fetch("IsDir") && e.fetch("Name") =~ BACKUP_DIR_RE or next false
      date = Time.strptime(e.fetch("Name")+"UTC", FILE_TIME_FMT+"%Z").getlocal.
        to_date
      today - date > RETENTION_DAYS
    }.map { |e|
      "#{dest}/#{e.fetch "Path"}"
    }.sort.each { |dir|
      log.info "deleting #{dir}" do
        system "rclone", "purge", dir or raise "rclone purge failed"
      end
    }

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
      else
        JSON.load(s).tap do |h|
          ks = %w(ts size)
          Hash === h && (h.keys & ks).size == ks.size or raise "invalid last"
        end
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
    incr_start = last.fetch("time") if !full && last
    begin
      log.info "influxd backup (start: %p)" % incr_start&.getlocal do
        system "influxd", "backup", "-portable", "-host", host,
          *(["-start", incr_start.getutc.strftime(CMD_TIME_FMT)] if incr_start),
          dir,
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

      out = "#{dest}/#{ts}"
      log.info "move #{dir} => #{out}" do
        system "rclone", "move", dir, out or raise "rclone move failed"
      end
    ensure
      log.info "rm -rf #{dir}" do
        FileUtils.rm_rf dir
      end
    end

    log.info "writing last" do
      IO.popen ["rclone", "rcat", "#{dest}/#{LAST_FILENAME}"], 'w' do |p|
        JSON.dump({"ts" => ts, "size" => size}, p)
      end
    end
  end
end

if $0 == __FILE__
  MetaCLI.new(ARGV).run Cmds
end
