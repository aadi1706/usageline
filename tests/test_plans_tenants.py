PLAN = {"name": "starter", "base_fee_cents": 1000, "included_units": 100, "unit_price_cents": 5}


def test_create_and_list_plans(client):
    r = client.post("/plans", json=PLAN)
    assert r.status_code == 201
    assert r.json()["name"] == "starter"
    assert [p["name"] for p in client.get("/plans").json()] == ["starter"]


def test_duplicate_plan_name_conflicts(client):
    client.post("/plans", json=PLAN)
    assert client.post("/plans", json=PLAN).status_code == 409


def test_plan_rejects_negative_values(client):
    assert client.post("/plans", json={**PLAN, "unit_price_cents": -1}).status_code == 422


def test_create_tenant(client):
    plan_id = client.post("/plans", json=PLAN).json()["id"]
    r = client.post("/tenants", json={"name": "acme", "plan_id": plan_id})
    assert r.status_code == 201
    tenant = r.json()
    assert client.get(f"/tenants/{tenant['id']}").json()["name"] == "acme"
    assert len(client.get("/tenants").json()) == 1


def test_tenant_requires_existing_plan(client):
    assert client.post("/tenants", json={"name": "acme", "plan_id": 999}).status_code == 404


def test_duplicate_tenant_name_conflicts(client):
    plan_id = client.post("/plans", json=PLAN).json()["id"]
    client.post("/tenants", json={"name": "acme", "plan_id": plan_id})
    assert client.post("/tenants", json={"name": "acme", "plan_id": plan_id}).status_code == 409


def test_get_unknown_tenant_404(client):
    assert client.get("/tenants/123").status_code == 404
