#!/bin/bash

set -e

DB_HOST="localhost"
DB_PORT="5432"
DB_NAME="imdb"
DB_USER="imdb"
DB_PASS="imdbpass"
ACTOR_NAME="Brad Pitt"

RESULTS_DIR="./results"
BEFORE_FILE="${RESULTS_DIR}/before_partitioning.txt"
AFTER_FILE="${RESULTS_DIR}/after_partitioning.txt"
SUMMARY_FILE="${RESULTS_DIR}/performance_summary.md"
CSV_FILE="${RESULTS_DIR}/results.csv"

mkdir -p "$RESULTS_DIR"

> "$BEFORE_FILE"
> "$AFTER_FILE"
> "$SUMMARY_FILE"
echo "Query,Before Partitioning (ms),After Partitioning (ms),Speed-Up" > "$CSV_FILE"

echo "=== PostgreSQL Partitioning Performance Test ==="
echo "Testing database: $DB_NAME on $DB_HOST:$DB_PORT"
echo "Results will be saved to: $RESULTS_DIR"

run_query() {
    local query="$1"
    local description="$2"
    local output_file="$3"

    echo "Running query: $description"
    echo "-----------------------------------------------------" >> "$output_file"
    echo "Query: $description" >> "$output_file"
    echo "SQL: $query" >> "$output_file"
    echo "-----------------------------------------------------" >> "$output_file"

    PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "
    \\timing on
    EXPLAIN ANALYZE
    $query
    " >> "$output_file" 2>&1

    echo "" >> "$output_file"
    echo "" >> "$output_file"
}

extract_time() {
    local file="$1"
    local description="$2"

    local time=$(grep -A 50 "Query: $description" "$file" | grep "Execution Time:" | head -1 | awk '{print $3}')

    if [ -n "$time" ]; then
        echo "$time"
    else
        echo "N/A"
    fi
}

calculate_speedup() {
    local before="$1"
    local after="$2"

    if [[ "$before" == "N/A" || "$after" == "N/A" ]]; then
        echo "N/A"
    else
        echo "scale=2; $before / $after" | bc
    fi
}

declare -A queries
queries["Query 1: Total productions"]="SELECT COUNT(*) as total_productions FROM title_basics;"
queries["Query 2: Total persons"]="SELECT COUNT(*) as total_persons FROM name_basics;"
queries["Query 3: Task categories"]="SELECT DISTINCT category FROM title_principals ORDER BY category;"
queries["Query 4: High-rated productions"]="SELECT COUNT(*) as high_rated_productions FROM title_ratings WHERE numVotes > 100000;"
queries["Query 5: Top 10 productions"]="SELECT tb.primaryTitle, tb.startYear, tr.averageRating, tr.numVotes FROM title_basics tb JOIN title_ratings tr ON tb.tconst = tr.tconst WHERE tr.numVotes > 100000 ORDER BY tr.averageRating DESC LIMIT 10;"
queries["Query 6: Top 10 movies with year analysis"]="WITH top_movies AS (SELECT tb.primaryTitle, tb.startYear, tr.averageRating, tr.numVotes FROM title_basics tb JOIN title_ratings tr ON tb.tconst = tr.tconst WHERE tr.numVotes > 100000 AND tb.titleType = 'movie' ORDER BY tr.averageRating DESC LIMIT 10) SELECT *, CASE WHEN startYear > 2000 THEN 'After 2000' ELSE 'Before 2000' END as era FROM top_movies;"
queries["Query 7: Find actor by name"]="SELECT * FROM name_basics WHERE primaryName = '${ACTOR_NAME}';"
queries["Query 8: Productions with roles"]="SELECT nb.primaryName, tb.primaryTitle, tb.startYear, tp.category, tp.characters FROM name_basics nb JOIN title_principals tp ON nb.nconst = tp.nconst JOIN title_basics tb ON tp.tconst = tb.tconst WHERE nb.primaryName = '${ACTOR_NAME}' ORDER BY tb.startYear;"
queries["Query 9: Movies and TV"]="SELECT tb.primaryTitle, tb.titleType, tb.startYear, tb.runtimeMinutes FROM name_basics nb JOIN title_principals tp ON nb.nconst = tp.nconst JOIN title_basics tb ON tp.tconst = tb.tconst WHERE nb.primaryName = '${ACTOR_NAME}' AND tb.titleType IN ('movie', 'short', 'tvSeries', 'tvEpisode') ORDER BY tb.startYear;"
queries["Query 10: Productivity by year"]="SELECT tb.startYear, COUNT(DISTINCT tb.tconst) as number_of_titles, SUM(COALESCE(tb.runtimeMinutes, 0)) as total_minutes FROM name_basics nb JOIN title_principals tp ON nb.nconst = tp.nconst JOIN title_basics tb ON tp.tconst = tb.tconst WHERE nb.primaryName = '${ACTOR_NAME}' AND tp.category = 'actor' GROUP BY tb.startYear ORDER BY tb.startYear;"
queries["Query 11: Role categories"]="SELECT tp.category, COUNT(*) as number_of_roles FROM name_basics nb JOIN title_principals tp ON nb.nconst = tp.nconst WHERE nb.primaryName = '${ACTOR_NAME}' GROUP BY tp.category ORDER BY number_of_roles DESC;"

echo "Testing queries on non-partitioned tables..."
for description in "${!queries[@]}"; do
    query="${queries[$description]}"
    run_query "$query" "$description" "$BEFORE_FILE"
done

echo "Creating partitioned tables..."
PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "
-- First backup existing data
CREATE TABLE temp_name_basics AS SELECT * FROM name_basics;
CREATE TABLE temp_title_basics AS SELECT * FROM title_basics;
CREATE TABLE temp_title_ratings AS SELECT * FROM title_ratings;
CREATE TABLE temp_title_principals AS SELECT * FROM title_principals;

-- Drop existing tables
DROP TABLE IF EXISTS title_principals CASCADE;
DROP TABLE IF EXISTS title_ratings CASCADE;
DROP TABLE IF EXISTS title_basics CASCADE;
DROP TABLE IF EXISTS name_basics CASCADE;

-- Create name_basics (no partitioning)
CREATE TABLE name_basics (
    nconst VARCHAR(10) PRIMARY KEY,
    primaryName VARCHAR(255),
    birthYear INT,
    deathYear INT,
    primaryProfession TEXT,
    knownForTitles TEXT
);

-- Create title_basics with range partitioning on startYear
CREATE TABLE title_basics (
    tconst VARCHAR(10) NOT NULL,
    titleType VARCHAR(20),
    primaryTitle VARCHAR(500),
    originalTitle VARCHAR(500),
    isAdult BOOLEAN,
    startYear INT,
    endYear INT,
    runtimeMinutes INT,
    genres TEXT,
    PRIMARY KEY (tconst, startYear)
) PARTITION BY RANGE (startYear);

-- Create partitions for title_basics
CREATE TABLE title_basics_before_1950 PARTITION OF title_basics
    FOR VALUES FROM (MINVALUE) TO (1950);

CREATE TABLE title_basics_1950_1970 PARTITION OF title_basics
    FOR VALUES FROM (1950) TO (1970);

CREATE TABLE title_basics_1970_1990 PARTITION OF title_basics
    FOR VALUES FROM (1970) TO (1990);

CREATE TABLE title_basics_1990_2010 PARTITION OF title_basics
    FOR VALUES FROM (1990) TO (2010);

CREATE TABLE title_basics_2010_present PARTITION OF title_basics
    FOR VALUES FROM (2010) TO (MAXVALUE);

-- Create title_ratings with partition by range on numVotes
CREATE TABLE title_ratings (
    tconst VARCHAR(10) NOT NULL,
    averageRating DECIMAL(3,1),
    numVotes INT,
    PRIMARY KEY (tconst, numVotes)
) PARTITION BY RANGE (numVotes);

-- Create partitions for title_ratings
CREATE TABLE title_ratings_low PARTITION OF title_ratings
    FOR VALUES FROM (MINVALUE) TO (1000);

CREATE TABLE title_ratings_medium PARTITION OF title_ratings
    FOR VALUES FROM (1000) TO (10000);

CREATE TABLE title_ratings_high PARTITION OF title_ratings
    FOR VALUES FROM (10000) TO (100000);

CREATE TABLE title_ratings_very_high PARTITION OF title_ratings
    FOR VALUES FROM (100000) TO (MAXVALUE);

-- Create title_principals with hash partitioning
CREATE TABLE title_principals (
    tconst VARCHAR(10),
    ordering INT,
    nconst VARCHAR(10),
    category VARCHAR(50),
    job TEXT,  -- Changed to TEXT to match the schema
    characters TEXT,
    PRIMARY KEY (tconst, ordering, nconst)
) PARTITION BY HASH (nconst);

-- Create hash partitions for title_principals
CREATE TABLE title_principals_p0 PARTITION OF title_principals
    FOR VALUES WITH (MODULUS 8, REMAINDER 0);

CREATE TABLE title_principals_p1 PARTITION OF title_principals
    FOR VALUES WITH (MODULUS 8, REMAINDER 1);

CREATE TABLE title_principals_p2 PARTITION OF title_principals
    FOR VALUES WITH (MODULUS 8, REMAINDER 2);

CREATE TABLE title_principals_p3 PARTITION OF title_principals
    FOR VALUES WITH (MODULUS 8, REMAINDER 3);

CREATE TABLE title_principals_p4 PARTITION OF title_principals
    FOR VALUES WITH (MODULUS 8, REMAINDER 4);

CREATE TABLE title_principals_p5 PARTITION OF title_principals
    FOR VALUES WITH (MODULUS 8, REMAINDER 5);

CREATE TABLE title_principals_p6 PARTITION OF title_principals
    FOR VALUES WITH (MODULUS 8, REMAINDER 6);

CREATE TABLE title_principals_p7 PARTITION OF title_principals
    FOR VALUES WITH (MODULUS 8, REMAINDER 7);

-- Restore data to partitioned tables
INSERT INTO name_basics SELECT * FROM temp_name_basics;
INSERT INTO title_basics SELECT * FROM temp_title_basics;
INSERT INTO title_ratings SELECT * FROM temp_title_ratings;
INSERT INTO title_principals SELECT * FROM temp_title_principals;

-- Drop temp tables
DROP TABLE temp_name_basics;
DROP TABLE temp_title_basics;
DROP TABLE temp_title_ratings;
DROP TABLE temp_title_principals;
"

echo "Testing queries on partitioned tables..."
for description in "${!queries[@]}"; do
    query="${queries[$description]}"
    run_query "$query" "$description" "$AFTER_FILE"
done

echo "Generating performance comparison report..."

cat > "$SUMMARY_FILE" <<EOL
# PostgreSQL Partitioning Performance Comparison

## Test Environment
- Database: PostgreSQL 15
- Actor used for tests: $ACTOR_NAME
- Test date: $(date)

## Performance Results

| Query | Before Partitioning (ms) | After Partitioning (ms) | Speed-Up |
|-------|--------------------------|-------------------------|----------|
EOL

for description in "${!queries[@]}"; do
    before_time=$(extract_time "$BEFORE_FILE" "$description")
    after_time=$(extract_time "$AFTER_FILE" "$description")
    speedup=$(calculate_speedup "$before_time" "$after_time")

    echo "| $description | $before_time | $after_time | $speedup |" >> "$SUMMARY_FILE"

    echo "\"$description\",$before_time,$after_time,$speedup" >> "$CSV_FILE"
done

cat >> "$SUMMARY_FILE" <<EOL

## Partitioning Strategy

1. **title_basics**: Range partitioning by startYear
   - Before 1950
   - 1950-1970
   - 1970-1990
   - 1990-2010
   - 2010 and newer

2. **title_ratings**: Range partitioning by numVotes
   - Low: < 1,000 votes
   - Medium: 1,000-10,000 votes
   - High: 10,000-100,000 votes
   - Very High: > 100,000 votes

3. **title_principals**: Hash partitioning by nconst (actor ID)
   - 8 hash partitions

## Partition Sizes

EOL

PGPASSWORD=$DB_PASS psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c "
SELECT
    parent.relname AS table_name,
    child.relname AS partition_name,
    pg_size_pretty(pg_relation_size(child.oid)) as size
FROM pg_inherits
    JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
    JOIN pg_class child ON pg_inherits.inhrelid = child.oid
WHERE parent.relname IN ('title_basics', 'title_ratings', 'title_principals')
ORDER BY parent.relname, pg_relation_size(child.oid) DESC;
" --tuples-only >> "$SUMMARY_FILE"

echo "Performance testing completed."
echo "Results are available in the $RESULTS_DIR directory:"
echo "- Raw results before partitioning: $BEFORE_FILE"
echo "- Raw results after partitioning: $AFTER_FILE"
echo "- Summary report: $SUMMARY_FILE"
echo "- CSV data: $CSV_FILE"
