from fastapi import FastAPI
from pydantic import BaseModel

from greetings import APP_VERSION, GREETINGS, get_greeting

app = FastAPI(title="hello-world-app", version=APP_VERSION)


class HealthResponse(BaseModel):
    ok: bool
    version: str


@app.get("/")
def hello(lang: str = "en"):
    return {"hello": get_greeting(lang)}


@app.get("/languages")
def languages():
    return {"supported": sorted(GREETINGS.keys())}


@app.get("/health", response_model=HealthResponse)
def health():
    return HealthResponse(ok=True, version=APP_VERSION)
