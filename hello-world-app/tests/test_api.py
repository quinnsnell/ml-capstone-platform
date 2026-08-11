from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_hello():
    r = client.get("/")
    assert r.status_code == 200
    assert r.json() == {"hello": "world"}


def test_health_ok():
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert "version" in body
