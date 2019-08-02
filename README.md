## Docker

Environment variables:

| Variable        | Default                   | Note
| --------------- | ------------------------- | ----
| INFLUXBU_HOST   | `"localhost:8088"`        |
| INFLUXBU_DIR    | `"/tmp/influxdb_backup"`  |
| INFLUXBU_DEST   | `"drive:backup/influxdb"` |
| INFLUXBU_FULL   | `"0"`                     |
| INFLUXBU_MIN_DF | -                         | Example: `"2048"` (MB)

Volumes:

* `/home/influxbu/rclone.conf`
