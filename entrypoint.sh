#!/bin/sh
set -e

echo "Waiting for database..."

until python - <<EOF
import asyncio
import asyncpg
from app.config import settings

async def main():
    dsn = settings.DATABASE_URL.replace("+asyncpg", "")
    conn = await asyncpg.connect(dsn)
    await conn.close()

asyncio.run(main())
EOF
do
  echo "Database is unavailable - sleeping"
  sleep 2
done

echo "Database is up"

echo "Running migrations..."
alembic upgrade head

echo "Starting application..."
exec uvicorn app.main:app --host 0.0.0.0 --port 8000