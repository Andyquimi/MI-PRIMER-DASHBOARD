FROM python:3.12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-client \
 && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir pandas psycopg2-binary
ENV PYTHONUNBUFFERED=1 PYTHONIOENCODING=utf-8 PGCLIENTENCODING=UTF8 LANG=C.UTF-8
WORKDIR /app
