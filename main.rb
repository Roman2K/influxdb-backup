require 'benchmark'
require 'fileutils'
require 'time'

TIMESTAMP_PAT = '\d.+T.+Z'
FILE_TIME_FMT = '%Y%m%dT%H%M%SZ'
CMD_TIME_FMT = '%Y-%m-%dT%H:%M:%SZ'
LAST_FILENAME = "last.txt"

def log(msg)
  print msg
  res = nil
  if block_given?
    print "... "
    time = Benchmark.realtime { res = yield }
    print "%.2fs" % time
  end
  print "\n"
  res
end

def run(host, dir, out_root)
  last = log "reading last" do
    `rclone cat #{out_root}/#{LAST_FILENAME}`.yield_self do |s|
      if $?.success? && s =~ /^#{TIMESTAMP_PAT}$/
        Time.strptime(s+"UTC", FILE_TIME_FMT+"%Z")
      else
        log "invalid last: %p (exit status: %s)" % [last, $?]
        nil
      end
    end
  end

  start = Time.now
  log "influxd backup (last: %p)" % last do
    system "influxd", "backup", "-portable", "-host", host,
      *(["-start", last.getutc.strftime(CMD_TIME_FMT)] if last),
      dir,
      out: "/dev/null" \
        or raise "influxd backup failed"
  end

  begin
    ts = Dir.glob(File.join(dir, "*")).
      map { |f| File.basename(f)[/^(#{TIMESTAMP_PAT})\./, 1] }.
      compact.max \
        || start.getutc.strftime(FILE_TIME_FMT)

    out = "#{out_root}/#{ts}"
    log "mkdir #{out}" do
      system "rclone", "mkdir", out or raise "rclone mkdir failed"
    end
    log "copy #{dir} => #{out}" do
      system "rclone", "copy", dir, out or raise "rclone copy failed"
    end
  ensure
    log "rm -rf #{dir}" do
      FileUtils.rm_rf dir
    end
  end

  log "writing last" do
    IO.popen ["rclone", "rcat", "#{out_root}/#{LAST_FILENAME}"], 'w' do |p|
      p << ts
    end
  end
end

run \
  "localhost:8088",
  "/tmp/influxdb_backup",
  "drive:backup/influxdb"
