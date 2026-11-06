FROM python:3.12-slim@sha256:cb33f7f771ecec2ef1225cf39b159591a040391bd73e4c01f00fdfc4c47611d2
COPY egressproxy.py /app/egressproxy.py
COPY allowlist.txt /etc/egress/allowlist.txt
ENV PYTHONUNBUFFERED=1
USER 10002:10002
EXPOSE 3128
ENTRYPOINT ["python3", "-I", "/app/egressproxy.py"]
