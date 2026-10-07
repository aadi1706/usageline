import re

PLAN = {"name": "starter", "base_fee_cents": 1000, "included_units": 100, "unit_price_cents": 5}


def sample(text, name, **labels):
    """Return the value of a metric sample with exactly the given labels, or None."""
    for line in text.splitlines():
        if not line.startswith(name + "{"):
            continue
        found = dict(re.findall(r'(\w+)="([^"]*)"', line))
        if all(found.get(k) == v for k, v in labels.items()):
            return float(line.rsplit(" ", 1)[1])
    return None


def test_metrics_endpoint_exposes_prometheus_format(client):
    r = client.get("/metrics")
    assert r.status_code == 200
    assert r.headers["content-type"].startswith("text/plain")
    assert "http_requests_total" in r.text


def test_request_counter_uses_route_template_not_raw_path(client):
    plan_id = client.post("/plans", json=PLAN).json()["id"]
    tid = client.post("/tenants", json={"name": "acme", "plan_id": plan_id}).json()["id"]
    before = sample(client.get("/metrics").text, "http_requests_total", route="/tenants/{tenant_id}", status="200") or 0
    client.get(f"/tenants/{tid}")
    client.get(f"/tenants/{tid}")
    text = client.get("/metrics").text
    assert sample(text, "http_requests_total", method="GET", route="/tenants/{tenant_id}", status="200") == before + 2
    assert f'route="/tenants/{tid}"' not in text


def test_many_distinct_ids_do_not_create_new_label_values(client):
    for i in range(5000, 5010):
        client.get(f"/tenants/{i}")  # all 404s
    text = client.get("/metrics").text
    assert 'route="/tenants/5000"' not in text
    assert sample(text, "http_requests_total", route="/tenants/{tenant_id}", status="404") is not None


def test_status_label_records_errors(client):
    client.post("/plans", json={**PLAN, "base_fee_cents": -1})
    text = client.get("/metrics").text
    assert sample(text, "http_requests_total", method="POST", route="/plans", status="422") is not None


def test_unknown_paths_share_one_unmatched_label(client):
    client.get("/definitely/not/a/route/1")
    client.get("/definitely/not/a/route/2")
    text = client.get("/metrics").text
    assert sample(text, "http_requests_total", route="unmatched", status="404") is not None
    assert "/definitely/not" not in text


def test_latency_histogram_recorded(client):
    client.get("/health")
    text = client.get("/metrics").text
    assert sample(text, "http_request_duration_seconds_count", method="GET", route="/health") >= 1
    assert sample(text, "http_request_duration_seconds_bucket", route="/health", le="+Inf") >= 1


def test_metrics_endpoint_is_not_counted(client):
    client.get("/metrics")
    assert 'route="/metrics"' not in client.get("/metrics").text
