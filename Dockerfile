# Terraform Template Generator: web UI + composer, with Terraform for bundle validation.
#
#   docker build -t tf-generator .
#   docker run --rm -p 8080:8080 -v tf-plugin-cache:/app/.plugin-cache tf-generator
#   # then open http://localhost:8080

FROM python:3.12-slim

ARG TERRAFORM_VERSION=1.16.2
ARG TARGETARCH=amd64

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Terraform (optional for the app, but without it bundles are generated unvalidated).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && curl -fsSL -o /tmp/terraform.zip \
       "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip" \
    && unzip /tmp/terraform.zip terraform -d /usr/local/bin \
    && rm /tmp/terraform.zip \
    && apt-get purge -y curl unzip && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY composer/requirements.txt composer/requirements.txt
RUN pip install --no-cache-dir -r composer/requirements.txt

COPY composer/ composer/
COPY module-library/ module-library/
COPY webapp/ webapp/
COPY tests/ tests/

# Run as a non-root user; the provider cache lives in /app/.plugin-cache (mount a volume to keep it).
RUN useradd --create-home --uid 10001 app \
    && mkdir -p /app/.plugin-cache \
    && chown -R app:app /app
USER app

EXPOSE 8080

CMD ["python", "webapp/server.py", "--host", "0.0.0.0", "--port", "8080"]
