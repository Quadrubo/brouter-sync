#!/bin/sh
# The script syncs segment files into SEGMENTS_DIR and repeats every
# SEGMENTS_REFRESH. A conditional request skips a file the upstream server
# has not regenerated. A rename replaces a file only after the complete
# download succeeds, so a server next to this container never reads a
# partial file. BRouter opens segment files per request, so the server
# needs no restart after a replacement.
set -eu

: "${SEGMENTS:=}"
: "${SEGMENTS_BBOX:=}"
: "${SEGMENTS_URL:=https://brouter.de/brouter/segments4}"
: "${SEGMENTS_REFRESH:=24h}"
: "${SEGMENTS_PARALLEL:=4}"
: "${SEGMENTS_PRUNE:=false}"
: "${SEGMENTS_DIR:=/segments4}"

run=/app/run
state="${run}/sync.state"

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

# fetch downloads one segment when the upstream copy is newer than the
# local file. xargs runs it as a separate process per segment. curl
# retries transient errors and a refused connection, not a missing file.
fetch() {
    name=$1
    file="${SEGMENTS_DIR}/${name}.rd5"
    tmp="${file}.tmp"

    set -- --fail --silent --show-error --location --retry 3 --retry-connrefused \
        --remote-time --output "${tmp}"
    if [ -f "${file}" ]; then
        set -- "$@" --time-cond "${file}"
    fi

    rm -f "${tmp}"
    if ! curl "$@" "${SEGMENTS_URL}/${name}.rd5"; then
        rm -f "${tmp}"
        log "failed ${name}"
        return 1
    fi

    # A 304 answer leaves the temporary file empty or absent.
    if [ -s "${tmp}" ]; then
        mv "${tmp}" "${file}"
        log "updated ${name}"
    else
        rm -f "${tmp}"
    fi
}

if [ "${1:-}" = fetch ]; then
    fetch "$2"
    exit 0
fi

# index prints every segment name the upstream directory listing links.
index() {
    curl --fail --silent --show-error --location --retry 3 --retry-all-errors "${SEGMENTS_URL}/" \
        | grep -o 'href="[^"/]*\.rd5"' \
        | sed 's/^href="//; s/\.rd5"$//'
}

# bbox prints the name of every five degree cell that touches
# SEGMENTS_BBOX, given as min_lon,min_lat,max_lon,max_lat.
bbox() {
    printf '%s\n' "${SEGMENTS_BBOX}" | awk -F, '
        function floor5(x, f) { f = int(x / 5) * 5; if (x < f) f -= 5; return f }
        function name(lon, lat) {
            return (lon < 0 ? "W" (-lon) : "E" lon) "_" (lat < 0 ? "S" (-lat) : "N" lat)
        }
        NF != 4 || $1 > $3 || $2 > $4 {
            print "SEGMENTS_BBOX needs min_lon,min_lat,max_lon,max_lat" > "/dev/stderr"
            exit 1
        }
        {
            for (lon = floor5($1); lon <= floor5($3); lon += 5)
                for (lat = floor5($2); lat <= floor5($4); lat += 5)
                    print name(lon, lat)
        }'
}

# selection prints the segment names from SEGMENTS and SEGMENTS_BBOX. Only
# names the upstream index lists count for ALL and for the box.
selection() {
    if [ -n "${SEGMENTS}" ] && [ "${SEGMENTS}" != ALL ]; then
        for name in ${SEGMENTS}; do
            case "${name}" in
                *[!A-Za-z0-9_]*)
                    log "invalid segment name ${name}"
                    return 1
                    ;;
            esac
            printf '%s\n' "${name}"
        done
    fi

    if [ "${SEGMENTS}" = ALL ] || [ -n "${SEGMENTS_BBOX}" ]; then
        index > "${run}/index"
        if [ ! -s "${run}/index" ]; then
            log "the index at ${SEGMENTS_URL}/ lists no segments"
            return 1
        fi

        if [ "${SEGMENTS}" = ALL ]; then
            cat "${run}/index"
        else
            bbox > "${run}/bbox"
            grep -Fx -f "${run}/index" "${run}/bbox" || true
        fi
    fi
}

# prune removes every segment file the selection does not name.
prune() {
    for file in "${SEGMENTS_DIR}"/*.rd5; do
        [ -e "${file}" ] || continue
        name="$(basename "${file}" .rd5)"
        if ! grep -Fqx "${name}" "${run}/selection"; then
            rm -f "${file}"
            log "removed ${name}"
        fi
    done
}

sync_once() {
    selection > "${run}/selection.raw"
    sort -u "${run}/selection.raw" > "${run}/selection"
    if [ ! -s "${run}/selection" ]; then
        log "no segment selected, set SEGMENTS or SEGMENTS_BBOX"
        return 1
    fi

    log "syncing $(wc -l < "${run}/selection") segments from ${SEGMENTS_URL}, ${SEGMENTS_PARALLEL} at a time"
    xargs -P "${SEGMENTS_PARALLEL}" -n 1 "$0" fetch < "${run}/selection"

    if [ "${SEGMENTS_PRUNE}" = true ]; then
        prune
    fi
}

mkdir -p "${run}"
echo running > "${state}"

trap 'kill "${child:-}" 2>/dev/null; exit 143' TERM INT

while :; do
    sync_once &
    child=$!
    if wait "${child}"; then
        status=ok
        log "sync complete"
    else
        status=failed
        log "sync incomplete"
    fi
    echo "${status}" > "${state}"

    if [ "${SEGMENTS_REFRESH}" = 0 ]; then
        [ "${status}" = ok ] && exit 0
        exit 1
    fi

    log "next sync in ${SEGMENTS_REFRESH}"
    sleep "${SEGMENTS_REFRESH}" &
    child=$!
    wait "${child}" || {
        log "SEGMENTS_REFRESH=${SEGMENTS_REFRESH} is no duration sleep accepts"
        exit 1
    }
done
