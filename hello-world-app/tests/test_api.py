from fastapi.testclient import TestClient
from main import app

client = TestClient(app)


def test_hello_default():
    r = client.get("/")
    assert r.status_code == 200
    assert r.json() == {"hello": "Hello, world"}


def test_hello_spanish():
    r = client.get("/", params={"lang": "es"})
    assert r.status_code == 200
    assert r.json() == {"hello": "Hola, mundo"}


def test_hello_unknown_lang_falls_back_to_default():
    r = client.get("/", params={"lang": "xx"})
    assert r.status_code == 200
    assert r.json() == {"hello": "Hello, world"}


def test_languages_lists_all_supported():
    r = client.get("/languages")
    assert r.status_code == 200
    body = r.json()
    assert "en" in body["supported"]
    assert "es" in body["supported"]


def test_health_ok():
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert "version" in body
