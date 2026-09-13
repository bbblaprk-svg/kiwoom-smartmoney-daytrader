FROM python:3.12-slim
LABEL io.pulse-edge.project="PULSE_EDGE" io.pulse-edge.runtime="3.8.16_REALTIME_HIDDEN_GEM"
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
COPY PULSE_EDGE_GREENFIELD_3_8_16_REALTIME_HIDDEN_GEM_SOURCE.tar.gz /tmp/source.tar.gz
RUN python -c "import pathlib,tarfile; p=pathlib.Path('/tmp/source.tar.gz'); t=tarfile.open(p,'r:gz'); ms=t.getmembers(); names=set(); [( (_ for _ in ()).throw(AssertionError(m.name)) if (pathlib.PurePosixPath(m.name).is_absolute() or '..' in pathlib.PurePosixPath(m.name).parts or not (m.isfile() or m.isdir()) or m.name in names) else names.add(m.name) ) for m in ms]; t.extractall('/app',filter='data'); t.close(); req=['requirements-runtime.txt','pulse_edge/main.py','pulse_edge/config.py','pulse_edge/features.py' if False else 'pulse_edge/engine/features.py','pulse_edge/engine/scorer.py','pulse_edge/engine/coiled.py','pulse_edge/runtime.py','pulse_edge/storage/signals.py','deploy/offline_tests.py','deploy/verify.py']; missing=[f for f in req if not pathlib.Path('/app',f).is_file()]; assert not missing, missing" \
 && test -s /app/requirements-runtime.txt \
 && python -m pip install --no-cache-dir -r /app/requirements-runtime.txt \
 && python -m compileall -q /app/pulse_edge /app/deploy \
 && PYTHONPATH=/app python -m deploy.offline_tests \
 && mkdir -p /app/data/pulse_edge \
 && rm -f /tmp/source.tar.gz
EXPOSE 8000
HEALTHCHECK --interval=20s --timeout=5s --start-period=45s --retries=3 CMD ["python","-c","import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=3).close()"]
CMD ["python","-m","uvicorn","pulse_edge.main:app","--host","0.0.0.0","--port","8000","--workers","1","--no-access-log"]
