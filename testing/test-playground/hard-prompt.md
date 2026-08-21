# The stress-test prompt

Paste the whole block below into Continue's chat panel as a single message. It's intentionally long — designed to exercise long-context handling, structured output discipline, and multi-part reasoning.

---

I'm building a data pipeline in Python that ingests CSV files from S3, validates them against a schema, transforms rows, and writes to a Postgres warehouse. I want you to design the module layout and give me the skeleton code for each module (function signatures, docstrings, and one or two lines of representative body — not full implementations).

Constraints:

1. **Standard library plus these three deps only:** `boto3`, `psycopg[binary]`, `pydantic` (v2). No pandas, no SQLAlchemy, no dagster, no airflow.
2. **Configuration** comes from environment variables validated at startup via a pydantic `Settings` class. Missing or malformed vars should fail fast with a clear error message that names every missing var (not just the first one).
3. **Schemas** are declared as pydantic models. Each CSV file type has one model. On validation failure, log the row number, the specific field that failed, and the raw value — then either skip the row or fail the whole file depending on a per-schema `on_error: Literal["skip", "fail"]` setting.
4. **Transformations** are pure functions taking a validated pydantic row and returning a dict of column-name → value for the warehouse row. Register transformations in a dict keyed by schema name so we can add new file types without touching the runner.
5. **Idempotence:** re-running the pipeline on the same S3 file must be a no-op, not a duplicate insert. Achieve this with a `pipeline_runs` table that tracks (s3_key, sha256, completed_at) and a check at the start of each file.
6. **Batched writes** to Postgres using `COPY` (not `INSERT`), because we might process 10M rows per file.
7. **Observability:** structured logging (JSON) with `logger = logging.getLogger(__name__)` — don't wire up an external logger. Every log line should include at least `s3_key`, `schema`, and one of `event=file_start|row_error|file_done|file_skipped_idempotent`.
8. **Testability:** the S3 client and the Postgres connection are injected, not constructed inside the runner. Tests should be able to swap in fakes.

Deliverables I want from you, in this order:

- **A.** Module layout: list every file, one sentence per file describing its responsibility.
- **B.** For each module, the public interface: class/function signatures with types and docstrings. Bodies can be `...` or 1–2 lines of representative code.
- **C.** A short paragraph on how the idempotence check interacts with partial-failure recovery (what happens if the pipeline crashes after 500k of 10M rows have been COPY-loaded but before `pipeline_runs.completed_at` is written?).
- **D.** One question you'd ask me before writing the real implementation, if you had the chance.

Do not write full implementations. Do not include a top-level `main.py` runnable script — just the module structure and interfaces. If any constraint above is impossible or contradictory, name it in section D rather than silently working around it.
