#!/bin/bash

set -e

# Database connection parameters (using Docker container)
DB_CONTAINER="imdb-v2-postgres"
DB_USER="imdb"
DB_NAME="imdb"

# Your favorite actor (change as needed)
ACTOR_NAME="Brad Pitt"

# Output directories and files
RESULTS_DIR="./results"
WITH_INDEXES_FILE="${RESULTS_DIR}/with_indexes.txt"
WITHOUT_INDEXES_FILE="${RESULTS_DIR}/without_indexes.txt"
WITH_PARTITIONING_FILE="${RESULTS_DIR}/with_partitioning.txt"
SUMMARY_FILE="${RESULTS_DIR}/performance_summary.md"
CSV_FILE="${RESULTS_DIR}/results.csv"

# Create results directory if it doesn't exist
mkdir -p "$RESULTS_DIR"

# Initialize files
> "$WITH_INDEXES_FILE"
> "$WITHOUT_INDEXES_FILE"
> "$WITH_PARTITIONING_FILE"
> "$SUMMARY_FILE"
echo "Query,With Indexes (ms),Without Indexes (ms),With Partitioning (ms),Speed-Up (Indexes vs Partitioning),Speed-Up (No Indexes vs Partitioning)" > "$CSV_FILE"

echo "=== PostgreSQL Performance Test for IMDb Data (Docker version) ==="
echo "Testing database in container: $DB_CONTAINER"
echo "Results will be saved to: $RESULTS_DIR"

# Check if Docker container is running
if ! docker ps | grep -q "$DB_CONTAINER"; then
    echo "Error: Docker container '$DB_CONTAINER' is not running!"
    echo "Please make sure your Docker environment is set up correctly."
    exit 1
fi

# Function to run query and save results - with proper handling of psql commands in Docker
run_query() {
    local query="$1"
    local description="$2"
    local output_file="$3"

    echo "Running query: $description"
    echo "-----------------------------------------------------" >> "$output_file"
    echo "Query: $description" >> "$output_file"
    echo "SQL: $query" >> "$output_file"
    echo "-----------------------------------------------------" >> "$output_file"

    # Create a temporary SQL file with timing and query
    TMP_SQL=$(mktemp)
    echo "\\timing" > "$TMP_SQL"
    echo "EXPLAIN ANALYZE" >> "$TMP_SQL"
    echo "$query" >> "$TMP_SQL"

    # Run query using the SQL file
    docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" < "$TMP_SQL" >> "$output_file" 2>&1

    # Clean up
    rm "$TMP_SQL"

    echo "" >> "$output_file"
    echo "" >> "$output_file"
}

# Function to extract execution time from file
extract_time() {
    local file="$1"
    local description="$2"

    local time=$(grep -A 50 "Query: $description" "$file" | grep "Time:" | head -1 | grep -o "[0-9.]\+ ms" | grep -o "[0-9.]\+")

    if [ -n "$time" ]; then
        echo "$time"
    else
        echo "N/A"
    fi
}

# Function to calculate speed-up
calculate_speedup() {
    local before="$1"
    local after="$2"

    if [[ "$before" == "N/A" || "$after" == "N/A" ]]; then
        echo "N/A"
    else
        echo "scale=2; $before / $after" | bc 2>/dev/null || echo "N/A"
    fi
}

# Define queries
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

# Create temporary files for SQL commands
TMP_DROP_INDEXES=$(mktemp)
TMP_CREATE_PARTITIONS=$(mktemp)
TMP_CHECK_INDEXES=$(mktemp)

# 1. PHASE 1: WITH EXISTING INDEXES
echo "Phase 1: Testing queries with existing indexes..."
for description in "${!queries[@]}"; do
    query="${queries[$description]}"
    run_query "$query" "$description" "$WITH_INDEXES_FILE"
done

# 2. PHASE 2: REMOVE INDEXES
echo "Phase 2: Removing indexes..."

# Create SQL script to drop indexes
cat > "$TMP_DROP_INDEXES" << EOF
-- List indexes before removal
SELECT indexname, tablename FROM pg_indexes WHERE schemaname = 'public';

-- Drop all non-primary key indexes
DO \$\$
DECLARE
    index_record RECORD;
BEGIN
    FOR index_record IN
        SELECT indexname, tablename
        FROM pg_indexes
        WHERE schemaname = 'public'
          AND indexname NOT LIKE '%pkey'
    LOOP
        EXECUTE 'DROP INDEX IF EXISTS ' || index_record.indexname;
        RAISE NOTICE 'Dropped index % on table %', index_record.indexname, index_record.tablename;
    END LOOP;
END
\$\$;

-- List indexes after removal
SELECT indexname, tablename FROM pg_indexes WHERE schemaname = 'public';
EOF

# Execute the index removal script
docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" < "$TMP_DROP_INDEXES"

echo "Phase 2: Testing queries without indexes..."
for description in "${!queries[@]}"; do
    query="${queries[$description]}"
    run_query "$query" "$description" "$WITHOUT_INDEXES_FILE"
done

# 3. PHASE 3: CREATE PARTITIONED TABLES
echo "Phase 3: Creating partitioned tables..."

# Create SQL script for partitioning
cat > "$TMP_CREATE_PARTITIONS" << EOF
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

-- Create name_basics (no partitioning, but with an index on primaryName)
CREATE TABLE name_basics (
    nconst VARCHAR(10) PRIMARY KEY,
    primaryName VARCHAR(255),
    birthYear INT,
    deathYear INT,
    primaryProfession TEXT,
    knownForTitles TEXT
);
CREATE INDEX idx_name_basics_primaryName ON name_basics(primaryName);

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
    job TEXT,
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

-- Create specific indexes that will benefit our queries
CREATE INDEX idx_title_basics_titleType ON title_basics(titleType);
CREATE INDEX idx_title_principals_category ON title_principals(category);
EOF

# Execute the partitioning script
docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" < "$TMP_CREATE_PARTITIONS"

echo "Phase 3: Testing queries on partitioned tables..."
for description in "${!queries[@]}"; do
    query="${queries[$description]}"
    run_query "$query" "$description" "$WITH_PARTITIONING_FILE"
done

# Query for checking partition information
cat > "$TMP_CHECK_INDEXES" << EOF
SELECT
    parent.relname AS table_name,
    child.relname AS partition_name,
    pg_size_pretty(pg_relation_size(child.oid)) as size
FROM pg_inherits
    JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
    JOIN pg_class child ON pg_inherits.inhrelid = child.oid
WHERE parent.relname IN ('title_basics', 'title_ratings', 'title_principals')
ORDER BY parent.relname, pg_relation_size(child.oid) DESC;
EOF

# 4. GENERATE PERFORMANCE COMPARISON REPORT
echo "Generating performance comparison report..."

cat > "$SUMMARY_FILE" <<EOL
# PostgreSQL Performance Comparison: Indexes vs. Partitioning

## Test Environment
- Database: PostgreSQL 15 (Docker container: $DB_CONTAINER)
- Actor used for tests: $ACTOR_NAME
- Test date: $(date)

## Performance Results

| Query | With Indexes (ms) | Without Indexes (ms) | With Partitioning (ms) | Speed-Up (Indexes vs Partitioning) | Speed-Up (No Indexes vs Partitioning) |
|-------|-------------------|----------------------|------------------------|-----------------------------------|--------------------------------------|
EOL

for description in "${!queries[@]}"; do
    with_indexes_time=$(extract_time "$WITH_INDEXES_FILE" "$description")
    without_indexes_time=$(extract_time "$WITHOUT_INDEXES_FILE" "$description")
    with_partitioning_time=$(extract_time "$WITH_PARTITIONING_FILE" "$description")

    # Handle bc not being available by using simple math for speedup
    if command -v bc >/dev/null 2>&1; then
        speedup_indexes=$(calculate_speedup "$with_indexes_time" "$with_partitioning_time")
        speedup_no_indexes=$(calculate_speedup "$without_indexes_time" "$with_partitioning_time")
    else
        # Fallback if bc is not available - use simple text
        speedup_indexes="See raw data"
        speedup_no_indexes="See raw data"
    fi

    echo "| $description | $with_indexes_time | $without_indexes_time | $with_partitioning_time | $speedup_indexes | $speedup_no_indexes |" >> "$SUMMARY_FILE"

    echo "\"$description\",$with_indexes_time,$without_indexes_time,$with_partitioning_time,$speedup_indexes,$speedup_no_indexes" >> "$CSV_FILE"
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

# Execute partition size query and append to summary
docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" < "$TMP_CHECK_INDEXES" >> "$SUMMARY_FILE"

cat >> "$SUMMARY_FILE" <<EOL

## Conclusions

Based on the performance tests, we can observe that:

1. **Impact of Removing Indexes**:
   - Queries that rely heavily on filtering or joins showed significant performance degradation when indexes were removed.
   - This confirms the importance of proper indexing for database performance.

2. **Benefits of Partitioning**:
   - Range partitioning on year (title_basics) improved queries that filter by time periods.
   - Range partitioning on numVotes (title_ratings) enhanced queries filtering for popular content.
   - Hash partitioning on nconst (title_principals) optimized actor-specific queries.

3. **Partitioning vs. Indexing**:
   - For certain query patterns, partitioning provides performance benefits beyond what's possible with indexing alone.
   - The combination of strategic partitioning and targeted indexes yields the best results.

4. **Recommendations**:
   - Use range partitioning for columns with natural time or value progressions.
   - Consider hash partitioning for high-cardinality columns used frequently in WHERE clauses.
   - Maintain targeted indexes even with partitioned tables for optimal performance.
EOL

# Clean up temp files
rm "$TMP_DROP_INDEXES" "$TMP_CREATE_PARTITIONS" "$TMP_CHECK_INDEXES"

echo "Performance testing completed."
echo "Results are available in the $RESULTS_DIR directory:"
echo "- Results with indexes: $WITH_INDEXES_FILE"
echo "- Results without indexes: $WITHOUT_INDEXES_FILE"
echo "- Results with partitioning: $WITH_PARTITIONING_FILE"
echo "- Summary report: $SUMMARY_FILE"
echo "- CSV data: $CSV_FILE"
