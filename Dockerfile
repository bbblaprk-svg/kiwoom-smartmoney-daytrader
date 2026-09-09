# PULSE EDGE 2.1.11.10 POSTCLOSE_SNAPSHOT_CPU_SAFE — R9 one-shot deployment harness
FROM python:3.12-slim
LABEL io.pulse-edge.project="PULSE_EDGE" io.pulse-edge.runtime="2.1.11.10_POSTCLOSE_SNAPSHOT_CPU_SAFE"
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    PULSE_WS_DYNAMIC_MAX_ITEMS=34 \
    PULSE_WS_BACKGROUND_RESERVE_ITEMS=10 \
    PULSE_BACKGROUND_BATCH_SIZE=10 \
    PULSE_BACKGROUND_COVERAGE_INTERVAL_SEC=6
WORKDIR /app
COPY PULSE_EDGE_CORE_2_1_3_RUNTIME_2_1_11_10_POSTCLOSE_SNAPSHOT_CPU_SAFE_R9_SOURCE.tar.gz /tmp/pulse-source.tar.gz
RUN python - <<'PY'
import hashlib, pathlib, tarfile
p=pathlib.Path('/tmp/pulse-source.tar.gz')
expected='bfc3a229f18b884292287bf0c0d297044f351915afc8f847af84bba001db35c5'
assert hashlib.sha256(p.read_bytes()).hexdigest()==expected, 'PULSE source SHA256 mismatch'
with tarfile.open(p,'r:gz') as t:
    t.extractall('/app', filter='data')
for req in ('requirements-runtime.txt','pulse_edge/main.py','pulse_edge/web/pulse.js','deploy/verify.py','deploy/soak_check.py'):
    assert pathlib.Path('/app',req).is_file(), req
PY
RUN python -m pip install --no-cache-dir -r /app/requirements-runtime.txt
RUN python -m compileall -q /app/pulse_edge /app/deploy && mkdir -p /app/data/pulse_edge
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 CMD ["python","-c","import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=3).close()"]
CMD ["python","-m","uvicorn","pulse_edge.main:app","--host","0.0.0.0","--port","8000","--workers","1"]
