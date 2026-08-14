FROM python:3.12-slim-bookworm
ARG BUILD_GIT_SHA=unknown
ARG SOURCE_ZIP_SHA=unknown
ARG SOURCE_TREE_SHA=unknown
ARG BUILD_CREATED_AT=unknown
LABEL org.opencontainers.image.title="QUANT NOVA" \
      org.opencontainers.image.version="NOVA-3.3.2-MASTER-TOP10-LIVEFIX" \
      org.opencontainers.image.revision="${BUILD_GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_CREATED_AT}" \
      org.opencontainers.image.source="https://github.com/bbblaprk-svg/kiwoom-smartmoney-daytrader" \
      io.quantnova.source_zip_sha256="${SOURCE_ZIP_SHA}" \
      io.quantnova.source_tree_sha256="${SOURCE_TREE_SHA}" \
      io.quantnova.deploy_model="GHCR_PULL_ONLY" \
      io.quantnova.runtime_profile="LIGHTSAIL_1GB_BOUNDED" \
      io.quantnova.ui_auth_model="NOVA_UI_ACCESS_TOKEN_OPTIONAL" \
      io.quantnova.http_guard_model="LIVE_BRIDGE_V2_DELTA_PRIMARY"
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    NOVA_DATA_DIR=/app/data/nova30 \
    NOVA_LEGACY_DATA_DIR=/app/data
WORKDIR /app
RUN mkdir -p /app/data/nova30 /app/data/nova30/legacy_bridge
COPY requirements.txt /app/requirements.txt
RUN python -m pip install --requirement /app/requirements.txt
COPY Dockerfile /app/Dockerfile
COPY SOURCE_MANIFEST.sha256 /app/SOURCE_MANIFEST.sha256
COPY SIGNAL_POLICY_FROZEN.json /app/SIGNAL_POLICY_FROZEN.json
COPY ARCHITECTURE.md SPEC_TRACEABILITY.md DEPLOYMENT_INVARIANTS.md /app/
COPY app /app/app
COPY config /app/config
COPY spec /app/spec
COPY static /app/static
COPY ops /app/ops
COPY scripts /app/scripts
COPY tests /app/tests
RUN python -m compileall -q /app/app /app/scripts && \
    PYTHONPATH=/app python -m unittest discover -s /app/tests -v && \
    PYTHONPATH=/app python /app/scripts/image_contract.py /app && \
    PYTHONPATH=/app python /app/scripts/master_audit.py && \
    PYTHONPATH=/app python /app/scripts/validate.py --quick
HEALTHCHECK --interval=15s --timeout=4s --start-period=35s --retries=3 \
  CMD python -c "import json,urllib.request,sys; j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/livez',timeout=2)); sys.exit(0 if j.get('ok') else 1)"
EXPOSE 8000
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000","--workers","1","--log-level","info","--access-log"]
