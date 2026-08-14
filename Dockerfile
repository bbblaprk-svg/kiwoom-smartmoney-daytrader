FROM python:3.12-slim-bookworm

LABEL org.opencontainers.image.title="QUANT NOVA" \
      org.opencontainers.image.version="NOVA-3.3.2-MASTER-TOP10-LIVEFIX" \
      io.quantnova.recovery="MORNING_BASELINE_EXACT_SOURCE" \
      io.quantnova.data_path="FROZEN" \
      io.quantnova.ui_baseline="20260814_MORNING"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    NOVA_DATA_DIR=/app/data/nova30 \
    NOVA_LEGACY_DATA_DIR=/app/data

WORKDIR /app
RUN mkdir -p /app/data/nova30 /app/data/nova30/legacy_bridge /tmp/nova-src

COPY QUANT_NOVA_3.3.2_MASTER_TOP10_LIVEFIX_SOURCE_20260814.zip /tmp/nova-source.zip

RUN python -c "import hashlib,pathlib,sys; p=pathlib.Path('/tmp/nova-source.zip'); h=hashlib.sha256(p.read_bytes()).hexdigest(); exp='328fa0d16db812b9f4c1e1f1c261907f4864a72caa503464ae846dcabbceb602'; print('SOURCE_SHA256='+h); sys.exit(0 if h==exp else 42)"
RUN python -c "import zipfile; zipfile.ZipFile('/tmp/nova-source.zip').extractall('/tmp/nova-src')"
RUN cp -a /tmp/nova-src/QUANT_NOVA_3.3.2_MASTER_TOP10_LIVEFIX/. /app/ && rm -rf /tmp/nova-src /tmp/nova-source.zip

RUN python -m pip install --requirement /app/requirements.txt
RUN python -m compileall -q /app/app /app/scripts && \
    PYTHONPATH=/app python -m unittest discover -s /app/tests -v && \
    PYTHONPATH=/app python /app/scripts/image_contract.py /app && \
    PYTHONPATH=/app python /app/scripts/master_audit.py && \
    PYTHONPATH=/app python /app/scripts/validate.py --quick

HEALTHCHECK --interval=15s --timeout=4s --start-period=35s --retries=3 \
  CMD python -c "import json,urllib.request,sys; j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/livez',timeout=2)); sys.exit(0 if j.get('ok') else 1)"

EXPOSE 8000
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000","--workers","1","--log-level","info","--access-log"]
