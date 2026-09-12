FROM python:3.12-slim
LABEL io.pulse-edge.project="PULSE_EDGE" io.pulse-edge.runtime="3.8.1_GREENFIELD_HIDDEN_GEM_PIPELINE_FIX"
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
WORKDIR /app
COPY PULSE_EDGE_GREENFIELD_3_8_1_HIDDEN_GEM_PIPELINE_FIX_SOURCE.tar.gz /tmp/source.tar.gz
RUN python - <<'PY'
import pathlib,tarfile
p=pathlib.Path('/tmp/source.tar.gz')
with tarfile.open(p,'r:gz') as t:
    names=set()
    for m in t.getmembers():
        q=pathlib.PurePosixPath(m.name)
        assert not q.is_absolute() and '..' not in q.parts
        assert m.isfile() or m.isdir()
        assert str(q) not in names
        names.add(str(q))
    t.extractall('/app',filter='data')
for f in ['requirements-runtime.txt','pulse_edge/main.py','pulse_edge/config.py','pulse_edge/engine/features.py','pulse_edge/engine/scorer.py','pulse_edge/engine/coiled.py','pulse_edge/runtime.py','pulse_edge/storage/signals.py','deploy/offline_tests.py','deploy/verify.py']:
    assert pathlib.Path('/app',f).is_file(),f
PY
RUN python -m pip install --no-cache-dir -r /app/requirements-runtime.txt \
 && python -m compileall -q /app/pulse_edge /app/deploy \
 && PYTHONPATH=/app python -m deploy.offline_tests \
 && mkdir -p /app/data/pulse_edge
EXPOSE 8000
HEALTHCHECK --interval=20s --timeout=5s --start-period=45s --retries=3 CMD ["python","-c","import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health',timeout=3).close()"]
CMD ["python","-m","uvicorn","pulse_edge.main:app","--host","0.0.0.0","--port","8000","--workers","1","--no-access-log"]
