FROM us-central1-docker.pkg.dev/cloud-workstations-images/predefined/code-oss:latest

RUN apt-get update && \
    apt-get install --no-install-recommends --no-install-suggests -y \
    python3-venv \
    && apt-get remove --purge --auto-remove -y \
    && rm -rf /var/lib/apt/lists/*

RUN npm install --quiet -g @google/gemini-cli
