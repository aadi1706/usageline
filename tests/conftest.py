import os

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.db import Base, get_db
from app.main import app


@pytest.fixture()
def client():
    url = os.getenv("TEST_DATABASE_URL", "sqlite://")
    is_sqlite = url.startswith("sqlite")
    kwargs = {"connect_args": {"check_same_thread": False}, "poolclass": StaticPool} if is_sqlite else {}
    engine = create_engine(url, **kwargs)

    if is_sqlite:
        Base.metadata.create_all(engine)
    else:
        # Schema must come from `alembic upgrade head`, so the migrations are what is under test.
        tables = ", ".join(Base.metadata.tables)
        with engine.begin() as conn:
            conn.execute(text(f"TRUNCATE {tables} RESTART IDENTITY CASCADE"))

    Session = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)

    def override_get_db():
        db = Session()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    yield TestClient(app)
    app.dependency_overrides.clear()
    if is_sqlite:
        Base.metadata.drop_all(engine)
    engine.dispose()
