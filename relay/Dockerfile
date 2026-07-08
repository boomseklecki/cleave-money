FROM python:3.12-slim-bookworm

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

COPY pyproject.toml ./
RUN uv pip install --system --no-cache .

COPY . .

EXPOSE 8000

# The sqlite store lives under /data (mount a volume there and set DB_PATH=/data/relay.db).
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
