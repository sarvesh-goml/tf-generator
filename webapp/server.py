#!/usr/bin/env python3
"""
Demo web server for the Terraform template generator.

Serves the UI and three API endpoints on top of composer/compose.py.
Uses only the Python standard library (plus PyYAML, which the composer needs).

    python webapp/server.py              # http://127.0.0.1:8080
    python webapp/server.py --port 9000

API
    GET  /api/catalog            services for the checkboxes + Terraform status
    POST /api/generate           {"services": [...], "counts": {"ec2": 2}, "names": {"ec2": ["web", "worker"]},
                                  "features": {"lambda": ["function_url"]}, "settings": {...}, "validate": true}
    GET  /api/download/<job_id>  the generated zip
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STATIC_DIR = Path(__file__).resolve().parent / "static"
sys.path.insert(0, str(ROOT / "composer"))
import compose  # noqa: E402

JOBS_DIR = Path(tempfile.gettempdir()) / "tf-generator-jobs"
JOB_TTL_SECONDS = 3600

# Reuse downloaded providers between requests: the first validation downloads the
# AWS provider (~150 MB); later ones take seconds.
PLUGIN_CACHE = ROOT / ".plugin-cache"
PLUGIN_CACHE.mkdir(exist_ok=True)
os.environ.setdefault("TF_PLUGIN_CACHE_DIR", str(PLUGIN_CACHE))
os.environ.setdefault("TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE", "true")

# Settings the UI may send, and how to check them.
ALLOWED_SETTINGS = {
    "project_name": lambda v: isinstance(v, str) and re.fullmatch(r"[a-z][a-z0-9-]{1,19}", v),
    "environment": lambda v: isinstance(v, str) and re.fullmatch(r"[a-z][a-z0-9-]{0,9}", v),
    "aws_region": lambda v: isinstance(v, str) and re.fullmatch(r"[a-z]{2}(-[a-z]+)+-\d", v),
    "vpc_create": lambda v: isinstance(v, bool),
    "ec2_subnet_type": lambda v: v in ("public", "private"),
    "ecs_subnet_type": lambda v: v in ("public", "private"),
    "lambda_attach_to_vpc": lambda v: isinstance(v, bool),
}
MAX_INSTANCES = 20
INSTANCE_NAME = r"[a-z0-9][a-z0-9-]{0,14}"  # same rule as compose.INSTANCE_KEY_PATTERN
PREVIEW_FILES = ["main.tf", "terraform.tfvars.example", "variables.tf", "outputs.tf", "README.md"]

# One build at a time: parallel `terraform init` runs would race on the plugin cache.
BUILD_LOCK = threading.Lock()


def terraform_info() -> dict:
    binary = shutil.which("terraform") or shutil.which("tofu")
    if not binary:
        return {"available": False, "version": None}
    try:
        out = subprocess.run(
            [binary, "version"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=20,
        )
        version = out.stdout.splitlines()[0] if out.stdout else Path(binary).name
    except Exception:
        version = Path(binary).name
    return {"available": True, "version": version}


def cleanup_old_jobs() -> None:
    if not JOBS_DIR.exists():
        return
    cutoff = time.time() - JOB_TTL_SECONDS
    for job in JOBS_DIR.iterdir():
        if job.is_dir() and job.stat().st_mtime < cutoff:
            shutil.rmtree(job, ignore_errors=True)


class Handler(BaseHTTPRequestHandler):
    server_version = "tf-generator-demo"

    # ------------------------------------------------------------------ helpers
    def _send_json(self, payload: dict, status: int = 200) -> None:
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path: Path, content_type: str, download_name: str | None = None) -> None:
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        if download_name:
            self.send_header("Content-Disposition", f'attachment; filename="{download_name}"')
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt: str, *args) -> None:  # quieter console
        sys.stderr.write(f"  {self.command} {self.path} -> {args[1] if len(args) > 1 else ''}\n")

    # ------------------------------------------------------------------ routes
    def do_GET(self) -> None:
        if self.path in ("/", "/index.html"):
            return self._send_file(STATIC_DIR / "index.html", "text/html; charset=utf-8")

        if self.path == "/api/catalog":
            try:
                data = compose.catalog()
            except compose.ComposeError as exc:
                return self._send_json({"error": str(exc)}, 500)
            data["terraform"] = terraform_info()
            return self._send_json(data)

        match = re.fullmatch(r"/api/download/([0-9a-f]{32})", self.path)
        if match:
            zip_path = JOBS_DIR / match.group(1) / "terraform-bundle.zip"
            if zip_path.exists():
                return self._send_file(zip_path, "application/zip", "terraform-bundle.zip")
            return self._send_json({"error": "This bundle has expired. Generate it again."}, 404)

        self._send_json({"error": "Not found"}, 404)

    def do_POST(self) -> None:
        if self.path != "/api/generate":
            return self._send_json({"error": "Not found"}, 404)

        try:
            length = int(self.headers.get("Content-Length", 0))
            request = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            return self._send_json({"error": "Request body must be JSON."}, 400)

        services = request.get("services") or []
        if not isinstance(services, list) or not services:
            return self._send_json({"error": "Select at least one service."}, 400)

        overrides = {}
        for key, value in (request.get("settings") or {}).items():
            check = ALLOWED_SETTINGS.get(key)
            if check is None:
                continue
            if not check(value):
                return self._send_json({"error": f"Invalid value for {key}: {value!r}"}, 400)
            overrides[key] = value

        # "counts": {"ec2": 3} -> ec2_instances = {"1" = {}, "2" = {}, "3" = {}}
        counts = request.get("counts") or {}
        if not isinstance(counts, dict):
            return self._send_json({"error": 'counts must be an object like {"ec2": 2}.'}, 400)
        for svc, n in counts.items():
            if svc not in services:
                continue
            if not isinstance(n, int) or isinstance(n, bool) or not 1 <= n <= MAX_INSTANCES:
                return self._send_json(
                    {"error": f"Count for {svc} must be a whole number from 1 to {MAX_INSTANCES}."},
                    400,
                )
            overrides[f"{svc}_instances"] = {str(i): {} for i in range(1, n + 1)}

        # "names": {"ec2": ["web", "worker"]} -> ec2_instances = {"web" = {}, "worker" = {}}
        # Takes precedence over "counts": the number of names is the number of instances.
        names = request.get("names") or {}
        if not isinstance(names, dict):
            return self._send_json(
                {"error": 'names must be an object like {"ec2": ["web", "worker"]}.'}, 400
            )
        for svc, keys in names.items():
            if svc not in services:
                continue
            if not isinstance(keys, list) or not 1 <= len(keys) <= MAX_INSTANCES:
                return self._send_json(
                    {"error": f"names for {svc} must be a list of 1 to {MAX_INSTANCES} names."}, 400
                )
            for key in keys:
                if not isinstance(key, str) or not re.fullmatch(INSTANCE_NAME, key):
                    return self._send_json(
                        {
                            "error": f"Invalid name for {svc}: {key!r}. Use 1-15 lowercase letters, digits and hyphens, starting with a letter or digit."
                        },
                        400,
                    )
            if len(set(keys)) != len(keys):
                return self._send_json({"error": f"Each {svc} name must be unique."}, 400)
            overrides[f"{svc}_instances"] = {key: {} for key in keys}

        # "features": {"ec2": ["elastic_ip"]} -> ec2_enable_elastic_ip = true
        features = request.get("features") or {}
        if not isinstance(features, dict):
            return self._send_json(
                {"error": 'features must be an object like {"ec2": ["elastic_ip"]}.'}, 400
            )
        if features:
            known = {
                o["id"]: {f["id"]: f for f in o["features"]}
                for g in compose.catalog()["groups"]
                for o in g["options"]
            }
            for svc, ids in features.items():
                if svc not in services:
                    continue
                if not isinstance(ids, list):
                    return self._send_json({"error": f"features for {svc} must be a list."}, 400)
                for fid in ids:
                    feature = known.get(svc, {}).get(fid)
                    if feature is None:
                        return self._send_json({"error": f"Unknown add-on '{fid}' for {svc}."}, 400)
                    overrides[feature["variable"]] = feature["value"]

        cleanup_old_jobs()
        job_id = uuid.uuid4().hex
        job_dir = JOBS_DIR / job_id

        with BUILD_LOCK:
            started = time.time()
            try:
                result = compose.build_bundle(
                    services,
                    job_dir,
                    overrides,
                    run_validation=bool(request.get("validate", True)),
                    strict_overrides=False,
                )
            except compose.ComposeError as exc:
                return self._send_json({"error": str(exc)}, 400)
            except Exception as exc:
                return self._send_json({"error": f"Generation failed: {exc}"}, 500)
            elapsed = round(time.time() - started, 1)

        bundle_dir = Path(result["bundle_dir"])
        files = sorted(
            p.relative_to(bundle_dir).as_posix() for p in bundle_dir.rglob("*") if p.is_file()
        )
        previews = {
            name: (bundle_dir / name).read_text(encoding="utf-8")
            for name in PREVIEW_FILES
            if (bundle_dir / name).exists()
        }
        self._send_json(
            {
                "status": result["status"],
                "tool": result.get("tool"),
                "reason": result.get("reason"),
                "modules": result["modules"],
                "auto_added": result["auto_added"],
                "steps": result["steps"],
                "files": files,
                "previews": previews,
                "elapsed_seconds": elapsed,
                "download_url": f"/api/download/{job_id}" if result.get("zip_path") else None,
            }
        )


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the Terraform template generator demo UI.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()

    JOBS_DIR.mkdir(parents=True, exist_ok=True)
    tf = terraform_info()
    print("Terraform template generator demo")
    print(
        f"  Terraform: {tf['version'] if tf['available'] else 'NOT FOUND (bundles will be generated without validation)'}"
    )
    print(f"  Open:      http://{args.host}:{args.port}")
    print("  Stop:      Ctrl+C\n")
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
