from pathlib import Path

from fastapi.testclient import TestClient

from main import app

INDEX_HTML = (Path(__file__).resolve().parent.parent / "static" / "index.html").read_text(
    encoding="utf-8"
)
# Distinctive copy from static/index.html so the assertion tracks the real page
EXPECTED_SNIPPET = "Coming soon Jai Guruji,Blessings always - Ish"

client = TestClient(app)


def test_root_returns_index_html():
    response = client.get("/")
    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]
    assert EXPECTED_SNIPPET in response.text
    assert EXPECTED_SNIPPET in INDEX_HTML


def test_static_index_is_served():
    response = client.get("/static/index.html")
    assert response.status_code == 200
    assert EXPECTED_SNIPPET in response.text
