# Override with --build-arg BASE_IMAGE=... when Docker Hub is unreachable and a
# different python base is cached locally.
ARG BASE_IMAGE=python:3.12-slim
FROM ${BASE_IMAGE}
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY consumer.py .
ENTRYPOINT ["python", "-u", "consumer.py"]
