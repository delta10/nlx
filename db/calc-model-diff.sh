#!/bin/bash

set -e # exit on error

tmpdir=`mktemp -d -t nlx_db_diff-XXXXXXXX`

if docker inspect $(hostname) &> /dev/null; then
    dockerNetwork="--network $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.NetworkID}}{{end}}' $(hostname))"
fi

echo "Starting postgres containers"
function cleanupDockerContainers {
  docker kill nlx_diff_migrate &> /dev/null || true
  docker rm nlx_diff_migrate &> /dev/null || true
  docker kill nlx_diff_target &> /dev/null || true
  docker rm nlx_diff_target &> /dev/null || true
}
cleanupDockerContainers
pgTargetContainer=`docker run --name nlx_diff_target ${dockerNetwork} -e POSTGRES_PASSWORD=postgres -d postgres:9.6`
pgMigrateContainer=`docker run --name nlx_diff_migrate ${dockerNetwork} -e POSTGRES_PASSWORD=postgres -d postgres:9.6`
trap cleanupDockerContainers EXIT
export PGPASSWORD=postgres

# Execute schema sql that was generated by pgmodeler and dump it again (apgdiff works best with schema migrations as generated by pg_dump).
echo "Creating database strucutre from pgmodeler generated sql"
pgTargetIP=`docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${pgTargetContainer}`
until (psql --user postgres --host ${pgTargetIP} --command '\l'&>/dev/null); do
  echo "Waiting for postgres in container nlx_diff_target"
  sleep 1
done
psql --echo-errors --variable "ON_ERROR_STOP=1" --user postgres --host ${pgTargetIP} --command "CREATE DATABASE nlx;" postgres >/dev/null
psql --echo-errors --variable "ON_ERROR_STOP=1" --user postgres --host ${pgTargetIP} --file "model/nlx.sql" nlx >/dev/null
pg_dump --user postgres --host ${pgTargetIP} --schema-only --file ${tmpdir}/target.sql nlx

# Create database and apply all migrations.
echo "Creating database structure from migration files"
pgMigrateIP=`docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' ${pgMigrateContainer}`
until (psql --user postgres --host ${pgMigrateIP} --command '\l' &>/dev/null); do
  echo "Waiting for postgres in container nlx_diff_migrate"
  sleep 1
done
psql --echo-errors --variable "ON_ERROR_STOP=1" --user postgres --host ${pgMigrateIP} --command "CREATE DATABASE nlx;" postgres >/dev/null
migrateDSN="postgres://postgres:postgres@${pgMigrateIP}:5432/nlx?sslmode=disable"
migrate --database ${migrateDSN} --path migrations/ up
migrateLastVersion=$(migrate --database ${migrateDSN} --path migrations/ version 2>&1)
# Dump schema for db with all migration files
pg_dump --user postgres --host ${pgMigrateIP} --schema-only --exclude-table schema_migrations --file ${tmpdir}/migrate.sql nlx

echo "Finding diffs"
diff=$(apgdiff --ignore-function-whitespace ${tmpdir}/migrate.sql ${tmpdir}/target.sql)
if [[ $? != 0 ]]; then
  echo "Diff up failed"
elif [[ $diff ]]; then
  echo "${diff}"
  exit 64
else
  echo "No differences found"
fi

echo "Verifying db/dbversion const LatestVersion"
if ! grep -q "^const LatestVersion = ${migrateLastVersion}\$" dbversion/version.go; then
    echo "dbversion/version.go is invalid, expected LatestVersion to equal ${migrateLastVersion}, got different value.";
    exit 64
fi
