FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements-runtime.txt /app/requirements-runtime.txt
RUN python -m pip install --no-cache-dir -r /app/requirements-runtime.txt
COPY pulse_edge /app/pulse_edge
RUN python -m compileall -q /app/pulse_edge
EXPOSE 8000
CMD ["python","-m","uvicorn","pulse_edge.main:app","--host","0.0.0.0","--port","8000","--workers","1"]
