# PULSE EDGE 2.1.0 LIVE CERTIFICATION — AWS LIGHTSAIL
# PULSE-only deployment. No NOVA runtime/image/volume/database dependency.
FROM python:3.12-slim

LABEL com.pulse-edge.project="pulse-edge" \
      com.pulse-edge.release="2.1.0-live-certification"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Asia/Seoul

WORKDIR /app

COPY requirements-runtime.txt /app/requirements-runtime.txt
RUN python -m pip install --no-cache-dir -r /app/requirements-runtime.txt tzdata \
    && mkdir -p /app/data/pulse_edge

COPY pulse_edge /app/pulse_edge
RUN python -m compileall -q /app/pulse_edge

EXPOSE 8000

HEALTHCHECK --interval=20s --timeout=4s --start-period=20s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=3).read()" || exit 1

CMD ["uvicorn","pulse_edge.main:app","--host","0.0.0.0","--port","8000"]
