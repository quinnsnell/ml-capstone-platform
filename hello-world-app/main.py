from fastapi import FastAPI
from pydantic import BaseModel

APP_VERSION = "0.1.0"

app = FastAPI(title="hello-world-app", version=APP_VERSION)


class HealthResponse(BaseModel):
    ok: bool
    version: str


@app.get("/")
def hello():
    return {"hello": "world"}


@app.get("/health", response_model=HealthResponse)
def health():
    return HealthResponse(ok=True, version=APP_VERSION)
