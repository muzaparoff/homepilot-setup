# Stdlib-only, so there is nothing to install and nothing to keep patched.
FROM python:3.12-alpine

COPY container_exporter.py /app/container_exporter.py

EXPOSE 9101
ENTRYPOINT ["python3", "-u", "/app/container_exporter.py"]
