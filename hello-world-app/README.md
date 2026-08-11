# hello-world-app

Minimal FastAPI starter for the ML Capstone class deployment lab. Use this to walk through the Coolify setup + push-to-deploy pipeline without getting entangled in ML plumbing.

## Layout

- `main.py` — FastAPI app and endpoints. Wiring only.
- `greetings.py` — content + logic (the greeting dict + `get_greeting()`). Pulled out of `main.py` on purpose so you see the "split logic from wiring" pattern even at hello-world scale.
- `tests/test_api.py` — five pytest tests hitting every endpoint.
- `Dockerfile` — single-stage `python:3.12-slim`, copies all `*.py`, exposes `:8000`.
- `.github/workflows/ci.yml` — three-job pipeline: unit tests → staging deploy → prod deploy.
- `test-local.sh` — build, run, curl a couple endpoints, clean up.

## Endpoints

| Method | Path | Returns |
|---|---|---|
| GET | `/` | `{"hello": "Hello, world"}` — or `{"hello": "Hola, mundo"}` etc. with `?lang=es\|fr\|de\|ja` |
| GET | `/languages` | `{"supported": ["de", "en", "es", "fr", "ja"]}` |
| GET | `/health` | `{"ok": true, "version": "0.1.1"}` |

## Local test

```bash
./test-local.sh
```

Or run without Docker:

```bash
pip install -r requirements.txt
uvicorn main:app --reload
```

Then `curl http://127.0.0.1:8000/` and `curl http://127.0.0.1:8000/health`.

## Unit tests

```bash
pip install fastapi 'uvicorn[standard]' pydantic httpx pytest
pytest tests/ -v
```

## Deploy

This app is deploy-ready for the ml-capstone cluster. Steps:

1. Fork or copy this directory into your team's GitHub repo.
2. Follow **`student-guide.md` → Part B → Setup: Sign in and create your Coolify Applications** (in the top-level of `ml-capstone-platform`) to wire up the Coolify Applications + GitHub secrets.
3. Push to `staging` branch → GitHub Actions runs unit tests → fires the Coolify staging webhook → your app is live at `https://<team>-staging.ml-capstone.cs.byu.edu`.
4. Merge `staging` → `main` → same flow to prod at `https://<team>.ml-capstone.cs.byu.edu`.

Bump `APP_VERSION` in `greetings.py` on each meaningful change so you can eyeball `/health` after a deploy and confirm it's the new build.
