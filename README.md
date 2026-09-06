# brouter-sync

The image keeps the segment files of a [BRouter](https://github.com/abrensch/brouter)
server current. It runs next to the upstream image `ghcr.io/abrensch/brouter`
on one shared volume, downloads the selected segments, and repeats on a
schedule. BRouter opens segment files per request, so a replaced file takes
effect without a restart of the server.

The image is 13 megabytes, holds curl and one shell script, and runs as
user 1000. It is published for amd64 and arm64 at `ghcr.io/quadrubo/brouter-sync`.

## Variables

| Variable            | Default                                | Meaning                                                                           |
| ------------------- | -------------------------------------- | --------------------------------------------------------------------------------- |
| `SEGMENTS`          | none                                   | Segment names separated by spaces, or `ALL` for every segment upstream.           |
| `SEGMENTS_BBOX`     | none                                   | `min_lon,min_lat,max_lon,max_lat`. Selects every segment that touches the box.    |
| `SEGMENTS_URL`      | `https://brouter.de/brouter/segments4` | Directory with the segment files and an index page.                               |
| `SEGMENTS_REFRESH`  | `24h`                                  | Pause between two passes, in a form `sleep` accepts. `0` runs one pass and exits. |
| `SEGMENTS_PARALLEL` | `4`                                    | Downloads that run at the same time.                                              |
| `SEGMENTS_PRUNE`    | `false`                                | `true` removes segment files the selection does not name.                         |
| `SEGMENTS_DIR`      | `/segments4`                           | Directory with the segment files.                                                 |

`SEGMENTS` and `SEGMENTS_BBOX` add up, and at least one is required. A
segment covers five degrees and takes its name from its south-west corner,
such as `E10_N50` for longitude 10 to 15 and latitude 50 to 55. Germany
fits in the box `5.8,47.2,15.1,55.1`, which selects nine segments of about
one gigabyte in total. `ALL` holds about ten gigabytes.

## Behaviour

Every pass sends a conditional request per segment, so a pass over
unchanged files costs one small round trip per file. The upstream server
regenerates the segments weekly. A download lands in a temporary file and
a rename replaces the old file, so a failed download keeps the old file
and the server never reads a partial file. A pass with one failed segment
reports failure and the next pass retries.

The health check passes after a pass in which every selected segment
landed. During the first pass the container reports `starting` for up to
one hour, so a BRouter service with `depends_on` and
`condition: service_healthy` waits for the segments. `ALL` needs more
than an hour on its first pass, so set a longer `start_period` for it in
compose. With `SEGMENTS_REFRESH=0` the exit status reports the pass, which
suits `condition: service_completed_successfully` or a cron job.

## Example

```yaml
services:
  brouter:
    image: ghcr.io/abrensch/brouter:master
    restart: unless-stopped
    ports:
      - "17777:17777"
    volumes:
      - segments:/segments4
    depends_on:
      brouter-sync:
        condition: service_healthy

  brouter-sync:
    image: ghcr.io/quadrubo/brouter-sync:latest
    restart: unless-stopped
    environment:
      SEGMENTS_BBOX: 5.8,47.2,15.1,55.1
    volumes:
      - segments:/segments4

volumes:
  segments:
```

The server answers on `http://localhost:17777/brouter`.

## Build

A git tag such as `v1.2.3` publishes the image tags `1.2.3`, `1.2` and
`latest`. A push to `main` publishes `main`. The workflow rebuilds the
newest git tag weekly, so `latest` picks up base image updates.
