CREATE TABLE IF NOT EXISTS name_basics (
    nconst VARCHAR(10) PRIMARY KEY,
    primaryName VARCHAR(255),
    birthYear INT,
    deathYear INT,
    primaryProfession TEXT,
    knownForTitles TEXT
);

CREATE TABLE IF NOT EXISTS title_basics (
    tconst VARCHAR(10) PRIMARY KEY,
    titleType VARCHAR(20),
    primaryTitle VARCHAR(500),
    originalTitle VARCHAR(500),
    isAdult BOOLEAN,
    startYear INT,
    endYear INT,
    runtimeMinutes INT,
    genres TEXT
);

CREATE TABLE IF NOT EXISTS title_ratings (
    tconst VARCHAR(10) PRIMARY KEY,
    averageRating DECIMAL(3,1),
    numVotes INT
);

CREATE TABLE IF NOT EXISTS title_principals (
    tconst VARCHAR(10),
    ordering INT,
    nconst VARCHAR(10),
    category VARCHAR(50),
    job TEXT,
    characters TEXT,
    PRIMARY KEY (tconst, ordering)
);
