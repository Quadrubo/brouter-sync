#!/bin/sh
# The container is healthy after a pass in which every selected segment
# landed. A pass with a failed segment makes it unhealthy until the next
# complete pass.
[ "$(cat /app/run/sync.state 2>/dev/null)" = ok ]
