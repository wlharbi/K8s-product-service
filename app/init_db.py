"""One-shot schema initialisation, run as a Kubernetes Job before the API rolls out.
Waits for the database, then creates tables. Replace with Alembic migrations
(`alembic upgrade head`) once the schema starts evolving."""
import sys
import time

from sqlalchemy import text

import app.models  # noqa: F401  (registers tables on Base.metadata)
from app.database import Base, engine


def main(retries: int = 60, delay: float = 2.0) -> int:
    for attempt in range(1, retries + 1):
        try:
            with engine.connect() as conn:
                conn.execute(text("SELECT 1"))
            Base.metadata.create_all(bind=engine)
            print("schema ready", flush=True)
            return 0
        except Exception as exc:  # noqa: BLE001
            print(f"database not ready ({attempt}/{retries}): {exc}", flush=True)
            time.sleep(delay)
    return 1


if __name__ == "__main__":
    sys.exit(main())
