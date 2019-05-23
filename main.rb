require 'benchmark'
require 'fileutils'
require 'time'
require 'date'
require 'json'

TIMESTAMP_PAT = '\d.+T.+Z'
BACKUP_DIR_RE = /^#{TIMESTAMP_PAT}$/
FILE_TIME_FMT = '%Y%m%dT%H%M%SZ'
CMD_TIME_FMT = '%Y-%m-%dT%H:%M:%SZ'
LAST_FILENAME = "last.txt"
RETENTION_DAYS = 30

def run(host, dir, out_root, full: false)
  today = Date.today
  log("getting backups older than %d days old" % RETENTION_DAYS) {
    JSON.parse(`rclone lsjson "#{out_root}"`.tap {
      $?.success? or raise "rclone lsjson failed"
    })
  }.select { |e|
    e.fetch("IsDir") && e.fetch("Name") =~ BACKUP_DIR_RE or next false
    date = Time.strptime(e.fetch("Name")+"UTC", FILE_TIME_FMT+"%Z").getlocal.
      to_date
    today - date > RETENTION_DAYS
  }.map { |e|
    "#{out_root}/#{e.fetch "Path"}"
  }.sort.each { |dir|
    log "deleting #{dir}" do
      system "rclone", "purge", dir or raise "rclone purge failed"
    end
  }

  last = if full
    log "full backup, not reading last"
    nil
  else
    log("reading last") {
      [`rclone cat "#{out_root}/#{LAST_FILENAME}"`, $?]
    }.yield_self { |s, st|
      if st.success? && s =~ /^#{TIMESTAMP_PAT}$/
        Time.strptime(s+"UTC", FILE_TIME_FMT+"%Z")
      else
        log "invalid last: %p (exit status: %s)" % [last, st]
        nil
      end
    }
  end

  start = Time.now
  log "influxd backup (last: %p)" % last&.getlocal do
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
    log "move #{dir} => #{out}" do
      system "rclone", "move", dir, out or raise "rclone move failed"
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

run \
  "localhost:8088",
  "/tmp/influxdb_backup",
  "drive:backup/influxdb",
  full: ARGV.include?("--full")
