#!/bin/bash
set -euo pipefail

: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD must be provided by the runtime secret store}"
: "${MYSQL_SHIPPING_PASSWORD:?MYSQL_SHIPPING_PASSWORD must be provided by the runtime secret store}"

# Escape values for a single-quoted MySQL literal.
escaped="${MYSQL_SHIPPING_PASSWORD//\\/\\\\}"
escaped="${escaped//\'/\'\'}"

mysql --protocol=socket -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
CREATE USER IF NOT EXISTS 'shipping'@'%' IDENTIFIED WITH caching_sha2_password BY '$escaped';
ALTER USER 'shipping'@'%' IDENTIFIED WITH caching_sha2_password BY '$escaped';
GRANT ALL ON cities.* TO 'shipping'@'%';
FLUSH PRIVILEGES;
SQL
