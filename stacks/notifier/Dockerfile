FROM python:3.12-slim

WORKDIR /app
RUN pip install --no-cache-dir "httpx[http2]" PyJWT cryptography

COPY notifier.py .

VOLUME /data
EXPOSE 8899

HEALTHCHECK --interval=60s --timeout=5s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8899/healthz')"

CMD ["python", "notifier.py"]
