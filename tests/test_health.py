from app.db import get_db
from app.main import app


def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_ready_when_database_reachable(client):
    r = client.get("/ready")
    assert r.status_code == 200
    assert r.json() == {"status": "ready"}


def test_ready_returns_503_when_database_down(client):
    class BrokenSession:
        def execute(self, *args, **kwargs):
            raise RuntimeError("connection refused")

        def close(self):
            pass

    app.dependency_overrides[get_db] = lambda: BrokenSession()
    r = client.get("/ready")
    assert r.status_code == 503


def test_health_stays_up_when_database_down(client):
    class BrokenSession:
        def execute(self, *args, **kwargs):
            raise RuntimeError("connection refused")

        def close(self):
            pass

    app.dependency_overrides[get_db] = lambda: BrokenSession()
    assert client.get("/health").status_code == 200
