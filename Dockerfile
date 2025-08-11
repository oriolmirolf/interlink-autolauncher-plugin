FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8001

WORKDIR /app

# For docker CLI (optional, comment if you run on host Python)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl iproute2 git jq \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

EXPOSE 8001
CMD ["uvicorn","main:app","--host","0.0.0.0","--port","8001"]
