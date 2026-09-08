# PULSE EDGE runtime 2.1.11.8 CPU_FIX
# Put this Dockerfile and the matching SOURCE archive in the same build folder.
FROM python:3.12-slim
LABEL io.pulse-edge.project="PULSE_EDGE" io.pulse-edge.runtime="2.1.11.8_CPU_FIX"
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 \
    PULSE_WS_DYNAMIC_MAX_ITEMS=34 PULSE_WS_BACKGROUND_RESERVE_ITEMS=10 \
    PULSE_BACKGROUND_BATCH_SIZE=10 PULSE_BACKGROUND_COVERAGE_INTERVAL_SEC=15 \
    OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1
WORKDIR /app
COPY PULSE_EDGE_CORE_2_1_3_RUNTIME_2_1_11_8_*SOURCE*.gz /tmp/pulse-source/
RUN python -c 'import hashlib,pathlib,tarfile; files=sorted(pathlib.Path("/tmp/pulse-source").glob("*.gz")); matched=[p for p in files if hashlib.sha256(p.read_bytes()).hexdigest()=="edbdac11e30d536f379fc83d281977147e3085122932ac97fec67820a2f2f58c"]; assert matched, "PULSE 2.1.11.8 source missing or SHA256 mismatch"; t=tarfile.open(matched[0],"r:gz"); t.extractall("/app",filter="data"); t.close(); assert pathlib.Path("/app/requirements-lock.txt").is_file(); assert pathlib.Path("/app/pulse_edge/main.py").is_file(); assert pathlib.Path("/app/pulse_edge/web/pulse.js").is_file()'
RUN python -m pip install --no-cache-dir -r /app/requirements-lock.txt && python -m pip check
RUN python -m compileall -q /app/pulse_edge /app/deploy \
    && mkdir -p /app/data/pulse_edge
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 CMD ["python","-c","import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=3).close()"]
CMD ["python","-m","uvicorn","pulse_edge.main:app","--host","0.0.0.0","--port","8000","--workers","1","--no-access-log"]
