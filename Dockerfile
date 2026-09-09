# PULSE EDGE runtime 2.1.11.9 SCOUT_FUNNEL_CPU_SAFE R1
FROM python:3.12-slim
LABEL io.pulse-edge.project="PULSE_EDGE" io.pulse-edge.runtime="2.1.11.9_SCOUT_FUNNEL_CPU_SAFE"
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PULSE_WS_DYNAMIC_MAX_ITEMS=34 PULSE_WS_BACKGROUND_RESERVE_ITEMS=10 PULSE_BACKGROUND_BATCH_SIZE=10 PULSE_BACKGROUND_COVERAGE_INTERVAL_SEC=6
WORKDIR /app
COPY PULSE_EDGE_CORE_2_1_3_RUNTIME_2_1_11_9_*SOURCE*.gz /tmp/pulse-source/
RUN python -c 'import hashlib,pathlib,tarfile; files=sorted(pathlib.Path("/tmp/pulse-source").glob("*.gz")); matched=[p for p in files if hashlib.sha256(p.read_bytes()).hexdigest()=="675d336d466d9b06934bd439639827e3784c972314669cf4c8c570018c8ff434"]; assert matched, "PULSE 2.1.11.9 source missing or SHA256 mismatch"; t=tarfile.open(matched[0],"r:gz"); t.extractall("/app",filter="data"); t.close(); assert pathlib.Path("/app/requirements-runtime.txt").is_file(); assert pathlib.Path("/app/pulse_edge/main.py").is_file(); assert pathlib.Path("/app/pulse_edge/web/pulse.js").is_file()'
RUN python -m pip install --no-cache-dir -r /app/requirements-runtime.txt
RUN python -m compileall -q /app/pulse_edge /app/deploy && mkdir -p /app/data/pulse_edge
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 CMD ["python","-c","import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=3).close()"]
CMD ["python","-m","uvicorn","pulse_edge.main:app","--host","0.0.0.0","--port","8000","--workers","1"]
