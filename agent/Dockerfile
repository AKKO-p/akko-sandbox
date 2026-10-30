# The harness's image: Python, the pinned clients, the harness. Built by
# agent/compose.agent.yaml; no key is baked in, it comes from the environment.
# Runs as root in its container, so that it can write the reports to the
# bind-mounted agent/reports whoever owns it on the host.
FROM python:3.12.15-slim
WORKDIR /agent
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY run.py questions.json ./
COPY tests ./tests
ENTRYPOINT ["python", "/agent/run.py"]
