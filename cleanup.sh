#!/bin/bash
# Cleanup script for IMDb PostgreSQL setup

echo "Stopping all IMDb-related containers..."
docker stop $(docker ps -a -q --filter "name=imdb") 2>/dev/null || true

echo "Removing all IMDb-related containers..."
docker rm $(docker ps -a -q --filter "name=imdb") 2>/dev/null || true

echo "Removing all IMDb-related volumes..."
docker volume rm $(docker volume ls -q --filter "name=imdb") 2>/dev/null || true

echo "Removing orphaned containers..."
docker container prune -f

echo "Cleaning up networks..."
docker network prune -f

echo "Done! All IMDb-related Docker resources have been cleaned up."
