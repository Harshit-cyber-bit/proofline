# syntax=docker/dockerfile:1
FROM python:3.11-slim-bookworm AS build

ENV PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /build
COPY requirements.txt .
RUN python3 -m venv /venv \
    && /venv/bin/pip install --no-cache-dir -r requirements.txt

FROM python:3.11-slim-bookworm AS runtime

# A real user, created at build time. The Kubernetes securityContext also sets
# runAsUser, but an image that only runs as non-root because something else told
# it to is an image that runs as root everywhere else.
RUN groupadd --gid 1000 app \
    && useradd --uid 1000 --gid 1000 --no-create-home --shell /usr/sbin/nologin app

COPY --from=build /venv /venv
WORKDIR /app
COPY app.py .

ENV PATH="/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PORT=8080

USER app
EXPOSE 8080

# --graceful-timeout must exceed the application's own drain window, or gunicorn
# kills the workers before they finish draining and the careful shutdown in
# app.py never completes.
#
# Gunicorn forwards SIGTERM to the workers, which is what triggers the drain.
CMD ["gunicorn", \
     "--bind", "0.0.0.0:8080", \
     "--workers", "2", \
     "--graceful-timeout", "30", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "app:app"]
