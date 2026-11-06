FROM python:3.12-slim@sha256:cb33f7f771ecec2ef1225cf39b159591a040391bd73e4c01f00fdfc4c47611d2
COPY credproxy.py /app/credproxy.py
# Runs as root with all caps dropped at run time (reads the tmpfs secret); read-only rootfs.
ENV PYTHONUNBUFFERED=1
EXPOSE 8080
ENTRYPOINT ["python3", "-I", "/app/credproxy.py"]
