PLAN = {"name": "starter", "base_fee_cents": 1000, "included_units": 100, "unit_price_cents": 5}
PERIOD = {"period_start": "2026-01-01T00:00:00Z", "period_end": "2026-02-01T00:00:00Z"}


def make_tenant(client, name="acme", plan=None):
    plan = plan or PLAN
    existing = [p for p in client.get("/plans").json() if p["name"] == plan["name"]]
    plan_id = existing[0]["id"] if existing else client.post("/plans", json=plan).json()["id"]
    return client.post("/tenants", json={"name": name, "plan_id": plan_id}).json()["id"]


def add_usage(client, tenant_id, quantity, ts):
    r = client.post(f"/tenants/{tenant_id}/usage", json={"metric": "api_calls", "quantity": quantity, "timestamp": ts})
    assert r.status_code == 201
    return r.json()


def test_record_and_list_usage(client):
    tid = make_tenant(client)
    add_usage(client, tid, 10, "2026-01-05T00:00:00Z")
    events = client.get(f"/tenants/{tid}/usage").json()
    assert len(events) == 1 and events[0]["quantity"] == 10


def test_usage_defaults_timestamp(client):
    tid = make_tenant(client)
    r = client.post(f"/tenants/{tid}/usage", json={"metric": "api_calls", "quantity": 1})
    assert r.status_code == 201 and r.json()["timestamp"]


def test_usage_rejects_non_positive_quantity(client):
    tid = make_tenant(client)
    assert client.post(f"/tenants/{tid}/usage", json={"metric": "m", "quantity": 0}).status_code == 422


def test_usage_for_unknown_tenant_404(client):
    assert client.post("/tenants/999/usage", json={"metric": "m", "quantity": 1}).status_code == 404


def test_invoice_with_overage(client):
    tid = make_tenant(client)
    add_usage(client, tid, 80, "2026-01-05T00:00:00Z")
    add_usage(client, tid, 70, "2026-01-20T00:00:00Z")
    r = client.post(f"/tenants/{tid}/invoices", json=PERIOD)
    assert r.status_code == 201
    inv = r.json()
    assert inv["total_units"] == 150
    assert inv["billable_units"] == 50
    assert inv["base_fee_cents"] == 1000
    assert inv["usage_charge_cents"] == 250
    assert inv["total_cents"] == 1250


def test_invoice_within_included_units_charges_base_fee_only(client):
    tid = make_tenant(client)
    add_usage(client, tid, 40, "2026-01-05T00:00:00Z")
    inv = client.post(f"/tenants/{tid}/invoices", json=PERIOD).json()
    assert inv["billable_units"] == 0
    assert inv["total_cents"] == 1000


def test_invoice_with_no_usage(client):
    tid = make_tenant(client)
    inv = client.post(f"/tenants/{tid}/invoices", json=PERIOD).json()
    assert inv["total_units"] == 0 and inv["total_cents"] == 1000


def test_invoice_period_is_start_inclusive_end_exclusive(client):
    tid = make_tenant(client)
    add_usage(client, tid, 1, "2026-01-01T00:00:00Z")
    add_usage(client, tid, 100, "2026-02-01T00:00:00Z")
    add_usage(client, tid, 100, "2025-12-31T23:59:59Z")
    inv = client.post(f"/tenants/{tid}/invoices", json=PERIOD).json()
    assert inv["total_units"] == 1


def test_invoice_only_counts_own_tenant_usage(client):
    a = make_tenant(client, "a")
    b = make_tenant(client, "b")
    add_usage(client, a, 10, "2026-01-05T00:00:00Z")
    add_usage(client, b, 500, "2026-01-05T00:00:00Z")
    assert client.post(f"/tenants/{a}/invoices", json=PERIOD).json()["total_units"] == 10
    assert client.post(f"/tenants/{b}/invoices", json=PERIOD).json()["total_units"] == 500


def test_invoice_rejects_inverted_period(client):
    tid = make_tenant(client)
    bad = {"period_start": PERIOD["period_end"], "period_end": PERIOD["period_start"]}
    assert client.post(f"/tenants/{tid}/invoices", json=bad).status_code == 422


def test_invoice_unknown_tenant_404(client):
    assert client.post("/tenants/999/invoices", json=PERIOD).status_code == 404


def test_list_and_get_invoices(client):
    tid = make_tenant(client)
    inv = client.post(f"/tenants/{tid}/invoices", json=PERIOD).json()
    assert [i["id"] for i in client.get(f"/tenants/{tid}/invoices").json()] == [inv["id"]]
    assert client.get(f"/invoices/{inv['id']}").json()["id"] == inv["id"]
    assert client.get("/invoices/999").status_code == 404
