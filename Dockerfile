# Slim, current Debian 12 base. The old python:3.12.3 (full, Debian 12.5) image was the source of
# ~2,300 of the HIGH/CRITICAL findings Trivy reported (kernel headers, -dev libs, old libc, etc.).
FROM python:3.12-slim-bookworm

WORKDIR /main

# Pull in the latest Debian security patches published since the base image was built
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

COPY ./main/requirements.txt /main/requirements.txt

# setuptools / wheel are upgraded because Trivy flagged the versions bundled with the base image
RUN pip install --no-cache-dir --upgrade pip "setuptools>=78.1.1" "wheel>=0.46.2" \
    && pip install --no-cache-dir --upgrade -r /main/requirements.txt

COPY ./main /main

ENV FLASK_APP=run.py
ENV FLASK_RUN_HOST=0.0.0.0
ENV FLASK_RUN_PORT=5000

EXPOSE 5000

CMD ["flask", "run"]
