FROM python:3.12-slim-bookworm
ARG BUILD_GIT_SHA=unknown
ARG BUILD_CREATED_AT=unknown
LABEL org.opencontainers.image.title="QUANT NOVA" \
      org.opencontainers.image.version="NOVA-3.3.2-MASTER-TOP10-LIVEFIX" \
      org.opencontainers.image.revision="${BUILD_GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_CREATED_AT}" \
      io.quantnova.variant="R4.2_OPENING_PROFIT_BRIDGE_SHADOW" \
      io.quantnova.baseline="R4.1_LARGECAP_PREIGNITION" \
      io.quantnova.data_feed_change="NONE" \
      io.quantnova.signal_policy_change="NONE" \
      io.quantnova.guard_change="NONE" \
      io.quantnova.buy_handoff="OFF" \
      io.quantnova.rollback_r41_sha256="25aa65878d4f497564bace3ce17a16b774454cb7a2fe9948a8a5796a4c5e4895"
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    NOVA_DATA_DIR=/app/data/nova30 \
    NOVA_LEGACY_DATA_DIR=/app/data \
    OPENING_BRIDGE_ENABLED=1 \
    OPENING_BRIDGE_UI_ENABLED=1
WORKDIR /app
RUN mkdir -p /app/data/nova30 /app/data/nova30/legacy_bridge
COPY QUANT_NOVA_3.3.2_R4.2_OPENING_PROFIT_BRIDGE_SHADOW_SOURCE_20260814.zip /tmp/nova-source.zip
RUN python -m zipfile -e /tmp/nova-source.zip /tmp/nova-src && \
    SRC="$(find /tmp/nova-src -mindepth 1 -maxdepth 1 -type d | head -1)" && \
    test -n "$SRC" && test -f "$SRC/requirements.txt" && \
    cp -a "$SRC"/. /app/ && \
    rm -rf /tmp/nova-src /tmp/nova-source.zip
RUN python -m pip install --requirement /app/requirements.txt
RUN python -m compileall -q /app/app /app/scripts /app/tests && \
    PYTHONPATH=/app python -m unittest discover -s /app/tests -v && \
    PYTHONPATH=/app python /app/scripts/image_contract.py /app && \
    PYTHONPATH=/app python /app/scripts/master_audit.py && \
    PYTHONPATH=/app python /app/scripts/validate.py --quick
HEALTHCHECK --interval=15s --timeout=4s --start-period=35s --retries=3 \
  CMD python -c "import json,urllib.request,sys; j=json.load(urllib.request.urlopen('http://127.0.0.1:8000/api/livez',timeout=2)); sys.exit(0 if j.get('ok') else 1)"
EXPOSE 8000
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000","--workers","1","--log-level","info","--access-log"]
