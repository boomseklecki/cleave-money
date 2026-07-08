# Pinned to bookworm: the PGDG apt repo line below targets bookworm-pgdg, and the bare `slim` tag has
# rolled forward to trixie (Debian 13), whose libldap can't satisfy the bookworm libpq5 dependency.
FROM python:3.12-slim-bookworm

# postgresql-client-16 (pg_dump/pg_restore for admin backups) from the PGDG apt repo - the Debian
# bookworm default client is 15, which can't dump a Postgres 16 server. restic + rclone provide the
# off-device backup tier (restic encrypts/dedups; rclone is restic's transport for non-native targets).
# openssh-client is restic's transport for native sftp: repos - it shells out to `ssh` (e.g. a NAS over
# SFTP-over-SSH with a mounted key; see the api's /root/.ssh mount + docs/OPERATIONS.md).
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates gnupg \
    && install -d /usr/share/postgresql-common/pgdg \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
         -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends postgresql-client-16 restic rclone openssh-client \
    && apt-get purge -y --auto-remove gnupg \
    && rm -rf /var/lib/apt/lists/*

# uv for fast, reproducible installs
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

WORKDIR /app

# Install dependencies first for layer caching
COPY pyproject.toml ./
RUN uv pip install --system --no-cache .

COPY . .

RUN chmod +x /app/docker-entrypoint.sh

EXPOSE 8000

# The entrypoint runs `alembic upgrade head` before the default (uvicorn) command so a prebuilt image is ready
# after one action, with no manual migration step (see docker-entrypoint.sh). An explicit command passes
# straight through, so `docker compose run --rm api alembic upgrade head` and the like are unaffected.
ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
