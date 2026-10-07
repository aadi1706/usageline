import os

DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql+psycopg2://usageline:usageline@localhost:5433/usageline",
)
