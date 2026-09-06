FROM alpine:3.20

RUN apk add --no-cache curl \
    && addgroup -g 1000 brouter \
    && adduser -u 1000 -G brouter -h /app -D brouter \
    && mkdir -p /app/run /segments4 \
    && chown -R brouter:brouter /app /segments4

COPY --chmod=755 src/sync.sh src/healthcheck.sh /app/

ENV SEGMENTS_DIR=/segments4

USER brouter
WORKDIR /app

# The container is healthy after a complete pass. The start period covers
# the first pass, so a dependent server waits for it instead of failing.
HEALTHCHECK --interval=30s --timeout=5s --start-period=1h --retries=3 CMD ["/app/healthcheck.sh"]

ENTRYPOINT ["/app/sync.sh"]
