FROM python:3.12-slim-bookworm
ARG BUILD_GIT_SHA=unknown
ARG BUILD_CREATED_AT=unknown
LABEL org.opencontainers.image.title="QUANT NOVA" \
      org.opencontainers.image.version="NOVA-3.3.2-MASTER-TOP10-LIVEFIX-ADDON-R3" \
      org.opencontainers.image.revision="${BUILD_GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_CREATED_AT}" \
      org.opencontainers.image.source="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader" \
      io.quantnova.deploy_model="TWO_FILE_SOURCE_ZIP" \
      io.quantnova.baseline="NOVA-3.3.2-MASTER-TOP10-LIVEFIX" \
      io.quantnova.addon="LARGECAP_SWING_PREIGNITION_READ_ONLY_R3"
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    NOVA_DATA_DIR=/app/data/nova30 \
    NOVA_LEGACY_DATA_DIR=/app/data
WORKDIR /app
COPY ["QUANT_NOVA_3.3.2_MASTER_TOP10_LIVEFIX_ADDON_R3_SOURCE_20260814.zip", "/tmp/nova-source.zip"]
RUN python -c "import hashlib,pathlib; p=pathlib.Path('/tmp/nova-source.zip'); got=hashlib.sha256(p.read_bytes()).hexdigest(); exp='9180026c31e6a9c94732dc0024dbb4b0a04475882e42a1db9771eade2a7e4e65'; assert got==exp, (got,exp)"
RUN python -c "import zipfile; zipfile.ZipFile('/tmp/nova-source.zip').extractall('/tmp/nova-src')"
RUN cp -a /tmp/nova-src/QUANT_NOVA_3.3.2_MASTER_TOP10_LIVEFIX_ADDON_R3/. /app/ && rm -rf /tmp/nova-src /tmp/nova-source.zip
RUN mkdir -p /app/data/nova30 /app/data/nova30/legacy_bridge
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
