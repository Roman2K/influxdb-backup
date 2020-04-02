## Docker

Environment variables:

| Variable            | Default                   | Note
| ------------------- | ------------------------- | ----
| INFLUXBU_HOST       | `"influxdb:8088"`         |
| INFLUXBU_DIR        | `"/tmp/influxdb_backup"`  |
| INFLUXBU_DEST       | `"drive:backup/influxdb"` |
| INFLUXBU_FULL       | `"0"`                     |
| INFLUXBU_MIN_DF     | -                         | Example: `"2048"` (MB)
| INFLUXBU_RETENTION  | `"30"`                    | Number of days
| INFLUXBU_DEBUG      | `"0"`                     |

Volumes:

* `/home/influxbu/rclone.conf`

## Restore

Example:

```sh
$ docker run \
  -v $HOME/windrive/backup/influxdb:/backups:ro \
  --network influx \
  influxdb influxd restore -portable -host influxdb:8088 \
    /backups/20200402T160031Z
```
