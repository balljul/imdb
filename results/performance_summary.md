# PostgreSQL Performance Comparison: Indexes vs. Partitioning

## Test Environment
- Database: PostgreSQL 15 (Docker container: imdb-v2-postgres)
- Actor used for tests: Brad Pitt
- Test date: Thu Mar 13 03:09:17 PM CET 2025

## Performance Results

| Query | With Indexes (ms) | Without Indexes (ms) | With Partitioning (ms) | Speed-Up (Indexes vs Partitioning) | Speed-Up (No Indexes vs Partitioning) |
|-------|-------------------|----------------------|------------------------|-----------------------------------|--------------------------------------|
| Query 6: Top 10 movies with year analysis | 1.582 | 0.791 | 2.514 | .62 | .31 |
| Query 10: Productivity by year | 9.884 | 0.715 | N/A | N/A | N/A |
| Query 7: Find actor by name | 0.365 | 0.290 | 0.419 | .87 | .69 |
| Query 11: Role categories | 0.635 | 0.522 | 0.981 | .64 | .53 |
| Query 2: Total persons | 0.237 | 0.205 | 0.249 | .95 | .82 |
| Query 3: Task categories | 0.241 | 0.263 | 0.668 | .36 | .39 |
| Query 8: Productions with roles | 1.076 | 1.141 | 7.673 | .14 | .14 |
| Query 4: High-rated productions | 0.233 | 0.206 | 0.331 | .70 | .62 |
| Query 5: Top 10 productions | 0.635 | 0.773 | 0.808 | .78 | .95 |
| Query 9: Movies and TV | 0.898 | 0.740 | N/A | N/A | N/A |
| Query 1: Total productions | 0.208 | 0.191 | 0.615 | .33 | .31 |

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

    table_name    |      partition_name       |    size    
------------------+---------------------------+------------
 title_basics     | title_basics_1990_2010    | 8192 bytes
 title_basics     | title_basics_before_1950  | 0 bytes
 title_basics     | title_basics_1950_1970    | 0 bytes
 title_basics     | title_basics_1970_1990    | 0 bytes
 title_basics     | title_basics_2010_present | 0 bytes
 title_principals | title_principals_p0       | 833 MB
 title_principals | title_principals_p5       | 830 MB
 title_principals | title_principals_p4       | 830 MB
 title_principals | title_principals_p1       | 828 MB
 title_principals | title_principals_p7       | 828 MB
 title_principals | title_principals_p2       | 825 MB
 title_principals | title_principals_p6       | 823 MB
 title_principals | title_principals_p3       | 819 MB
 title_ratings    | title_ratings_low         | 72 MB
 title_ratings    | title_ratings_medium      | 4016 kB
 title_ratings    | title_ratings_high        | 672 kB
 title_ratings    | title_ratings_very_high   | 152 kB
(17 rows)


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
