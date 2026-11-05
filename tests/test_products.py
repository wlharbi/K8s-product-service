BASE = "/api/v1/products"


def test_create_and_get(client, make_product):
    p = make_product()
    assert p["sku"] == "SKU-1" and p["price"] == "9.99"
    r = client.get(f"{BASE}/{p['id']}")
    assert r.status_code == 200 and r.json()["name"] == "Widget"


def test_duplicate_sku_conflict(client, make_product):
    make_product()
    r = client.post(BASE, json={"sku": "SKU-1", "name": "Other", "price": "1.00"})
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "conflict"


def test_validation_errors(client):
    r = client.post(BASE, json={"sku": "bad sku!", "name": "X", "price": "-1"})
    assert r.status_code == 422


def test_get_missing_404(client):
    r = client.get(f"{BASE}/999")
    assert r.status_code == 404
    assert r.json()["error"]["code"] == "not_found"


def test_list_filter_and_pagination(client, make_product):
    for i in range(5):
        make_product(sku=f"A-{i}", name=f"Apple {i}", price=f"{i + 1}.00")
    make_product(sku="B-1", name="Banana", price="50.00")

    r = client.get(BASE, params={"q": "apple", "limit": 2, "offset": 0}).json()
    assert r["total"] == 5 and len(r["items"]) == 2

    r = client.get(BASE, params={"min_price": 40}).json()
    assert r["total"] == 1 and r["items"][0]["sku"] == "B-1"


def test_partial_update(client, make_product):
    p = make_product()
    r = client.patch(f"{BASE}/{p['id']}", json={"price": "19.50"})
    assert r.status_code == 200
    body = r.json()
    assert body["price"] == "19.50" and body["name"] == "Widget"


def test_delete(client, make_product):
    p = make_product()
    assert client.delete(f"{BASE}/{p['id']}").status_code == 204
    assert client.get(f"{BASE}/{p['id']}").status_code == 404


def test_stock_adjustment(client, make_product):
    p = make_product(stock=5)
    r = client.post(f"{BASE}/{p['id']}/stock", json={"delta": -3})
    assert r.status_code == 200 and r.json()["stock"] == 2
    r = client.post(f"{BASE}/{p['id']}/stock", json={"delta": -3})
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "insufficient_stock"
    assert client.get(f"{BASE}/{p['id']}").json()["stock"] == 2


def test_stock_adjust_missing_product(client):
    assert client.post(f"{BASE}/42/stock", json={"delta": 1}).status_code == 404


def test_health_and_request_id(client):
    assert client.get("/health/live").json() == {"status": "ok"}
    r = client.get("/health/ready", headers={"X-Request-ID": "abc123"})
    assert r.status_code == 200 and r.headers["X-Request-ID"] == "abc123"
