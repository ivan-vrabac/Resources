FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY main.py auth.py admin.py econ.py protection.py ./
COPY systems ./systems
RUN useradd --system --uid 10001 app && mkdir -p /data /logs && chown app /data /logs
USER app
# Trust X-Forwarded-* only from the reverse proxy; override FORWARDED_ALLOW_IPS in .env.
ENV FORWARDED_ALLOW_IPS=127.0.0.1
EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
