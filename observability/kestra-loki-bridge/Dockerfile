FROM python:3.12-alpine
WORKDIR /app
COPY bridge.py /app/bridge.py
ENV KESTRA_URL=http://kestra:8080 \
    POLL_SECONDS=5 \
    PAGE_SIZE=50 \
    KESTRA_TENANT=main
CMD ["python", "-u", "bridge.py"]
