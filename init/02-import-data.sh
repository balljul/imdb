#!/bin/bash
set -e

echo "Starting IMDb data import process..."

echo "PostgreSQL connection parameters:"
echo "PGHOST: $PGHOST"
echo "PGUSER: $PGUSER"
echo "PGDATABASE: $PGDATABASE"
echo "Path check:"
echo "Checking /imdb-v2-data directory..."
ls -la /imdb-v2-data

MAX_TRIES=30
WAIT_SECS=10

for i in $(seq 1 $MAX_TRIES); do
    if pg_isready -h "$PGHOST" -U "$PGUSER" > /dev/null 2>&1; then
        echo "Database is ready!"
        break
    fi

    echo "Attempt $i/$MAX_TRIES: Database is not ready yet. Waiting $WAIT_SECS seconds..."
    sleep $WAIT_SECS

    if [ $i -eq $MAX_TRIES ]; then
        echo "Error: Could not connect to database after $MAX_TRIES attempts"
        exit 1
    fi
done

check_file() {
    local file="$1"

    if [ ! -f "$file" ]; then
        echo "Error: File $file not found!"
        echo "Contents of $(dirname "$file"):"
        ls -la $(dirname "$file")
        return 1
    fi
    if [ ! -s "$file" ]; then
        echo "Error: File $file is empty!"
        return 1
    fi
    echo "File $file exists and is not empty"
    return 0
}

import_dataset() {
    local file="/imdb-v2-data/$1"
    local table="$2"

    echo "Checking $file..."
    if ! check_file "$file"; then
        return 1
    fi

    echo "Importing $file into $table..."
    psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -c "\
        COPY $table FROM '$file' \
        WITH (FORMAT csv, DELIMITER E'\t', QUOTE E'\b', HEADER, NULL '\\N');"

    if [ $? -eq 0 ]; then
        echo "Successfully imported $file into $table"
        COUNT=$(psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -t -c "SELECT COUNT(*) FROM $table")
        echo "Records in $table: $COUNT"
    else
        echo "Error importing $file into $table"
        return 1
    fi
}

echo "Starting imports..."

import_dataset "name.basics.tsv" "name_basics" || exit 1
import_dataset "title.basics.tsv" "title_basics" || exit 1
import_dataset "title.ratings.tsv" "title_ratings" || exit 1
import_dataset "title.principals.tsv" "title_principals" || exit 1

echo "All imports completed successfully!"

echo "Final record counts:"
psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -c "
SELECT 'name_basics' as table_name, COUNT(*) as count FROM name_basics
UNION ALL
SELECT 'title_basics', COUNT(*) FROM title_basics
UNION ALL
SELECT 'title_ratings', COUNT(*) FROM title_ratings
UNION ALL
SELECT 'title_principals', COUNT(*) FROM title_principals;
"

exit 0
