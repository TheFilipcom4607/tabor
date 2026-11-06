#!/bin/bash
# Phones a day and their builds, from the Worker's counter (proxy/src/stats.js).
#   scripts/app_stats.sh        the last 30 days
#   scripts/app_stats.sh 90     the last 90 (Analytics Engine keeps about three months)
#
# Needs a Cloudflare API token with Account Analytics Read in ~/.cloudflare-logs-token.
# Phones are approximate: see stats.js.
set -euo pipefail

DAYS=${1:-30}
ACCOUNT=519d65ee3bbe284f533cac8b3acb08aa
TOKEN=$(cat ~/.cloudflare-logs-token)

sql() {
  curl -sf "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT/analytics_engine/sql" \
    -H "Authorization: Bearer $TOKEN" --data-binary "$1"
}

SINCE="timestamp > NOW() - INTERVAL '$DAYS' DAY"

echo "day         phones  polls  routes  track"
sql "SELECT blob3 AS day, count(DISTINCT index1) AS phones,
       sumIf(_sample_interval, blob2 = 'feed') AS polls,
       sumIf(_sample_interval, blob2 = 'routes') AS routes,
       sumIf(_sample_interval, blob2 = 'track') AS track
     FROM tabor_stats WHERE $SINCE GROUP BY day ORDER BY day FORMAT TabSeparated" |
  awk -F'\t' '{ printf "%-10s %7s %6s %7s %6s\n", $1, $2, $3, $4, $5 }'

echo
echo "phone-days by build, last 7 days (tags change daily, so a phone counts once per day)"
sql "SELECT blob1 AS build, count(DISTINCT index1) AS phones
     FROM tabor_stats WHERE timestamp > NOW() - INTERVAL '7' DAY
     GROUP BY build ORDER BY phones DESC FORMAT TabSeparated" |
  awk -F'\t' '{ printf "  build %-4s %6s\n", $1, $2 }'
