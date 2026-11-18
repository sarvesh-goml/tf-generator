#!/usr/bin/env python3
"""
Terraform bundle composer.

Reads the module library (each module has a module.yaml manifest), resolves
dependencies for the services a user selected, generates a root Terraform
module that wires the selected modules together, validates it with
terraform/tofu, and packages it as a zip.

Library use (from the web backend):

    from compose import build_bundle, catalog
    catalog()                                  # -> data for the UI checkboxes
    build_bundle(["ec2", "s3"], "/tmp/out")    # -> report dict incl. zip path

CLI use:

    python compose.py --catalog
    python compose.py ec2 s3 dynamodb -o ./out
    python compose.py ecs ecr --set project_name=shop --set aws_region=ap-south-1
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path

import yaml

LIBRARY_DIR = Path(__file__).resolve().parent.parent / "module-library"
CATEGORY_ORDER = ["foundation", "deployment", "services"]
UI_CATEGORIES = {"deployment": "Deployment method", "services": "Other services"}

TERRAFORM_REQUIRED_VERSION = ">= 1.5.0"
PROVIDERS = {
    "aws": {"source": "hashicorp/aws", "version": ">= 5.0, < 7.0"},
    "archive": {"source": "hashicorp/archive", "version": ">= 2.4, < 3.0"},
}

# Variables every bundle gets, regardless of the selection.
BASE_VARIABLES = {
    "aws_region": {
        "type": "string",
        "default": "us-east-1",
        "description": "AWS region to deploy into.",
    },
    "project_name": {
        "type": "string",
        "default": "myapp",
        "description": "Short project name, used as the first part of every resource name.",
        "validation": {
            "condition": 'can(regex("^[a-z][a-z0-9-]{1,19}$", var.project_name))',
            "error_message": "project_name must be 2-20 characters: lowercase letters, digits, hyphens, starting with a letter.",
        },
    },
    "environment": {
        "type": "string",
        "default": "dev",
        "description": "Environment name, e.g. dev, staging, prod.",
        "validation": {
            "condition": 'can(regex("^[a-z][a-z0-9-]{0,9}$", var.environment))',
            "error_message": "environment must be 1-10 characters: lowercase letters, digits, hyphens.",
        },
    },
    "additional_tags": {
        "type": "map(string)",
        "default": {},
        "description": "Extra tags applied to every resource. Project, Environment and ManagedBy are added automatically, so don't repeat them here.",
        "validation": {
            "condition": (
                'alltrue([for k in keys(var.additional_tags) : !contains(["project", "environment", "managedby"], lower(k))]) '
                "&& length(distinct([for k in keys(var.additional_tags) : lower(k)])) == length(var.additional_tags)"
            ),
            "error_message": "additional_tags must not include Project, Environment or ManagedBy in any letter case (they are added automatically), or two keys that differ only by case. AWS IAM treats tag keys as case-insensitive.",
        },
    },
}

GITIGNORE = """\
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
crash.log
crash.*.log
terraform.tfvars
*.auto.tfvars
.build/
"""


def _write(path: Path, text: str) -> None:
    """Always UTF-8 with LF line endings, so bundles are identical on Windows, macOS and
    Linux. (Windows otherwise defaults to cp1252, which can't encode characters like →.)"""
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


class ComposeError(Exception):
    """Raised for invalid selections or broken manifests."""


# ---------------------------------------------------------------------------
# Library loading and linting
# ---------------------------------------------------------------------------
def _module_variables(module_dir: Path) -> dict[str, bool]:
    """Return {variable_name: has_default} parsed from a module's variables.tf."""
    text = (module_dir / "variables.tf").read_text(encoding="utf-8")
    result = {}
    blocks = re.split(r'^variable\s+"', text, flags=re.M)[1:]
    for block in blocks:
        name = block.split('"', 1)[0]
        result[name] = bool(re.search(r"^\s*default\s*=", block, flags=re.M))
    return result


def load_library(library_dir: Path = LIBRARY_DIR) -> dict[str, dict]:
    modules: dict[str, dict] = {}
    for manifest_path in sorted(library_dir.glob("*/*/module.yaml")):
        manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
        manifest["_path"] = manifest_path.parent
        manifest.setdefault("requires", [])
        manifest.setdefault("optional", {})
        manifest.setdefault("inputs", {})
        manifest.setdefault("root_variables", {})
        manifest.setdefault("outputs", {})
        manifest.setdefault("providers", ["aws"])
        manifest.setdefault("readme_notes", "")
        manifest.setdefault("features", [])
        name = manifest["name"]
        if name in modules:
            raise ComposeError(f"Duplicate module name '{name}' in library")
        modules[name] = manifest
    _lint_library(modules)
    return modules


def _lint_library(modules: dict[str, dict]) -> None:
    """Catch manifest mistakes early, before they become broken bundles."""
    problems = []
    for name, m in modules.items():
        variables = _module_variables(m["_path"])
        all_inputs = dict(m["inputs"])
        for dep, extra in m["optional"].items():
            if dep not in modules:
                problems.append(f"{name}: optional dependency '{dep}' not in library")
            all_inputs.update(extra.get("inputs", {}))
        for dep in m["requires"]:
            if dep not in modules:
                problems.append(f"{name}: required dependency '{dep}' not in library")
        for key in all_inputs:
            if key not in variables:
                problems.append(f"{name}: manifest input '{key}' is not a variable of the module")
        for var, has_default in variables.items():
            if not has_default and var not in m["inputs"]:
                problems.append(
                    f"{name}: required module variable '{var}' is not set in manifest inputs"
                )
        root_all = dict(m["root_variables"])
        for extra in m["optional"].values():
            root_all.update(extra.get("root_variables", {}))
        seen_ids = set()
        for f in m["features"]:
            fid = f.get("id")
            if not fid or fid in seen_ids:
                problems.append(f"{name}: feature id missing or duplicated: {fid!r}")
            seen_ids.add(fid)
            var = f.get("variable")
            if var not in root_all:
                problems.append(f"{name}: feature '{fid}' uses unknown root variable '{var}'")
            elif root_all[var].get("options") and f.get("value") not in root_all[var]["options"]:
                problems.append(
                    f"{name}: feature '{fid}' value {f.get('value')!r} is not one of {root_all[var]['options']}"
                )
        if m.get("multi"):
            all_root = dict(m["root_variables"])
            for extra in m["optional"].values():
                all_root.update(extra.get("root_variables", {}))
            for v in m.get("per_instance", []):
                if v not in all_root:
                    problems.append(f"{name}: per_instance '{v}' is not a root variable")
                elif not v.startswith(f"{name}_"):
                    problems.append(f"{name}: per_instance '{v}' must start with '{name}_'")
            for k in m.get("instance_only", {}):
                if k not in variables:
                    problems.append(f"{name}: instance_only '{k}' is not a variable of the module")
        for provider in m["providers"]:
            if provider not in PROVIDERS:
                problems.append(f"{name}: unknown provider '{provider}'")
    if problems:
        raise ComposeError("Module library problems:\n  " + "\n  ".join(problems))


def catalog(library_dir: Path = LIBRARY_DIR) -> dict:
    """Data the UI needs to render its checkbox groups."""
    modules = load_library(library_dir)
    groups = []
    for category, label in UI_CATEGORIES.items():
        items = [
            {
                "id": m["name"],
                "label": m.get("display_name", m["name"]),
                "description": m.get("description", ""),
                "auto_includes": m["requires"],
                "multi": bool(m.get("multi")),
                "features": [
                    {
                        "id": f["id"],
                        "label": f.get("label", f["id"]),
                        "description": f.get("description", ""),
                        "variable": f["variable"],
                        "value": f["value"],
                        "requires_setting": f.get("requires_setting", {}),
                        "requires_hint": f.get("requires_hint", ""),
                    }
                    for f in m["features"]
                ],
            }
            for m in sorted(modules.values(), key=lambda m: (m.get("ui_order", 99), m["name"]))
            if m["category"] == category and m.get("selectable", True)
        ]
        groups.append({"id": category, "label": label, "options": items})
    return {"groups": groups}


# ---------------------------------------------------------------------------
# Dependency resolution
# ---------------------------------------------------------------------------
def resolve(selected: list[str], modules: dict[str, dict]) -> list[str]:
    """Return selected modules plus their dependencies, dependencies first."""
    unknown = [s for s in selected if s not in modules]
    if unknown:
        raise ComposeError(f"Unknown service(s): {', '.join(unknown)}")
    not_selectable = [s for s in selected if not modules[s].get("selectable", True)]
    if not_selectable:
        raise ComposeError(f"Not directly selectable: {', '.join(not_selectable)}")

    order: list[str] = []
    visiting: set[str] = set()

    def visit(name: str) -> None:
        if name in order:
            return
        if name in visiting:
            raise ComposeError(f"Dependency cycle involving '{name}'")
        visiting.add(name)
        for dep in modules[name]["requires"]:
            visit(dep)
        visiting.discard(name)
        order.append(name)

    def sort_key(name: str):
        cat = modules[name]["category"]
        return (CATEGORY_ORDER.index(cat) if cat in CATEGORY_ORDER else 99, name)

    for name in sorted(set(selected), key=sort_key):
        visit(name)
    return order


def _effective(module: dict, bundle: set[str]) -> tuple[dict, dict]:
    """Inputs and root variables for a module, including optional wiring
    that applies because the related module is in this bundle."""
    inputs = dict(module["inputs"])
    root_vars = dict(module["root_variables"])
    for dep, extra in module["optional"].items():
        if dep in bundle:
            inputs.update(extra.get("inputs", {}))
            root_vars.update(extra.get("root_variables", {}))
    return inputs, root_vars


# ---------------------------------------------------------------------------
# HCL rendering helpers
# ---------------------------------------------------------------------------
def hcl_value(value, indent: int = 0) -> str:
    pad = "  " * indent
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        escaped = json.dumps(value).replace("${", "$${").replace("%{", "%%{")
        return escaped
    if isinstance(value, list):
        return "[" + ", ".join(hcl_value(v, indent) for v in value) + "]"
    if isinstance(value, dict):
        if not value:
            return "{}"
        width = max(len(_hcl_key(k)) for k in value)
        lines = [
            f"{pad}  {_hcl_key(k).ljust(width)} = {hcl_value(v, indent + 1)}"
            for k, v in value.items()
        ]
        return "{\n" + "\n".join(lines) + f"\n{pad}}}"
    raise ComposeError(f"Cannot render value of type {type(value).__name__}: {value!r}")


def _hcl_key(key: str) -> str:
    return key if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", key) else json.dumps(key)


def _attributes(pairs: list[tuple[str, str]], indent: int = 1) -> list[str]:
    """Render aligned `key = value` lines."""
    if not pairs:
        return []
    pad = "  " * indent
    width = max(len(k) for k, _ in pairs)
    return [f"{pad}{k.ljust(width)} = {v}" for k, v in pairs]


def _variable_block(name: str, spec: dict) -> str:
    lines = [f'variable "{name}" {{']
    lines += _attributes(
        [
            ("description", hcl_value(spec.get("description", ""))),
            ("type", spec["type"]),
            ("default", hcl_value(spec.get("default"), 1)),
        ]
    )
    validation = spec.get("validation")
    if not validation and spec.get("options"):
        allowed = ", ".join(hcl_value(o) for o in spec["options"])
        validation = {
            "condition": f"contains([{allowed}], var.{name})",
            "error_message": f"{name} must be one of: {', '.join(map(str, spec['options']))}.",
        }
    if validation:
        lines.append("")
        lines.append("  validation {")
        lines += _attributes(
            [
                ("condition", validation["condition"]),
                ("error_message", hcl_value(validation["error_message"])),
            ],
            indent=2,
        )
        lines.append("  }")
    lines.append("}")
    return "\n".join(lines)


def _tfvars_line(name: str, spec: dict) -> str:
    comment = f"# {spec.get('description', '')}"
    if spec.get("instance_fields"):
        comment += "\n# Per-instance settings: " + ", ".join(spec["instance_fields"])
        ex = spec.get("instance_example")
        if ex:
            comment += f"\n# Example: {name} = {{ web = {{}}, worker = {{ {ex} = ... }} }}"
    elif "instance_fields" in spec:
        comment += f"\n# Example: {name} = {{ web = {{}}, worker = {{}} }}"
    if spec.get("options"):
        comment += "\n# Options: " + " | ".join(hcl_value(o) for o in spec["options"])
    if spec.get("default") is None:
        return f"{comment}\n# {name} = null"
    return f"{comment}\n{name} = {hcl_value(spec['default'])}"


# ---------------------------------------------------------------------------
# Root module generation
# ---------------------------------------------------------------------------
INSTANCE_KEY_PATTERN = "^[a-z0-9][a-z0-9-]{0,14}$"


def _make_multi(name: str, m: dict, inputs: dict, root_vars: dict) -> tuple[dict, dict, str]:
    """Turn one module into N instances driven by a `<name>_instances` map.

    Each map key is an instance name (it becomes part of resource names). Each value
    may override any setting listed in the manifest's `per_instance`; anything left
    out falls back to the shared `<name>_*` default variable. Settings listed in
    `instance_only` (e.g. explicit resource names) exist only per instance.
    """
    inst_var = f"{name}_instances"
    prefix = f"{name}_"
    per_instance = [v for v in m.get("per_instance", []) if v in root_vars]
    instance_only = m.get("instance_only", {})

    fields = {v[len(prefix) :]: root_vars[v]["type"] for v in per_instance}
    fields.update({k: t for k, t in instance_only.items()})
    object_type = (
        "map(object({\n"
        + "\n".join(f"    {k} = optional({t})" for k, t in fields.items())
        + "\n  }))"
        if fields
        else "map(object({}))"
    )

    new_inputs = {}
    for key, expr in inputs.items():
        if expr == "local.name_prefix":
            expr = '"${local.name_prefix}-${each.key}"'
        for v in per_instance:
            short = v[len(prefix) :]
            expr = re.sub(
                rf"\bvar\.{v}\b",
                f"(each.value.{short} != null ? each.value.{short} : var.{v})",
                expr,
            )
        # A bare `(x != null ? x : y)` doesn't need the outer brackets.
        if expr.startswith("(each.value.") and expr.endswith(")") and expr.count("(") == 1:
            expr = expr[1:-1]
        new_inputs[key] = expr
    for key in instance_only:
        new_inputs[key] = f"each.value.{key}"

    label = m.get("display_name", name)
    example_field = next(iter(fields), None)
    inst_spec = {
        "type": object_type,
        "default": {"1": {}},
        "description": (
            f"{label} instances to create, one entry per instance. The key is the instance "
            f"name and becomes part of resource names; rename keys freely (e.g. web, worker). "
            f"Leave a value as {{}} to use the {prefix}* defaults below, or override per instance."
        ),
        "instance_fields": list(fields),
        "instance_example": example_field,
        "validation": {
            "condition": f'alltrue([for k in keys(var.{inst_var}) : can(regex("{INSTANCE_KEY_PATTERN}", k))])',
            "error_message": f"{inst_var} keys must be 1-15 characters: lowercase letters, digits and hyphens, starting with a letter or digit.",
        },
    }
    # Instances map first, then the shared defaults (relabelled as such).
    new_root_vars = {inst_var: inst_spec}
    for v, spec in root_vars.items():
        if v in per_instance:
            spec = {
                **spec,
                "description": spec.get("description", "")
                + " Default for every instance; can be overridden per instance.",
            }
        new_root_vars[v] = spec
    return new_inputs, new_root_vars, f"var.{inst_var}"


def generate(
    selected: list[str],
    out_dir: Path,
    overrides: dict | None = None,
    library_dir: Path = LIBRARY_DIR,
    strict_overrides: bool = True,
) -> dict:
    """Write the bundle to out_dir. Returns metadata about what was generated."""
    modules = load_library(library_dir)
    order = resolve(selected, modules)
    bundle = set(order)
    auto_added = [m for m in order if m not in selected]
    overrides = overrides or {}

    if out_dir.exists():
        shutil.rmtree(out_dir)
    (out_dir / "modules").mkdir(parents=True)

    # Copy each module (without its manifest) into the bundle.
    for name in order:
        shutil.copytree(
            modules[name]["_path"],
            out_dir / "modules" / name,
            ignore=shutil.ignore_patterns("module.yaml", "__pycache__", ".terraform", ".build"),
        )

    # Collect variables, module blocks and outputs.
    variable_sections: list[tuple[str, dict]] = [("General", dict(BASE_VARIABLES))]
    module_blocks, output_blocks = [], []
    providers_needed = {"aws"}
    declared = set(BASE_VARIABLES)

    for name in order:
        m = modules[name]
        inputs, root_vars = _effective(m, bundle)
        providers_needed.update(m["providers"])

        if m.get("multi"):
            inputs, root_vars, for_each = _make_multi(name, m, inputs, root_vars)
        else:
            for_each = None

        for var in root_vars:
            if var in declared:
                raise ComposeError(f"Root variable '{var}' declared twice (module {name})")
            declared.add(var)
        variable_sections.append((m.get("display_name", name), root_vars))

        block = [f'module "{name}" {{', f'  source = "./modules/{name}"']
        if for_each:
            block.append(f"  for_each = {for_each}")
        block.append("")
        block += _attributes(list(inputs.items()))
        block.append("}")
        module_blocks.append("\n".join(block))

        for out_name, spec in m["outputs"].items():
            value = spec["value"]
            description = spec.get("description", "")
            if for_each:
                # One value per instance, keyed by instance name.
                value = "{ for k, m in module.%s : k => %s }" % (
                    name,
                    value.replace(f"module.{name}.", "m."),
                )
                description = (
                    description.rstrip(".") + ", per instance (map of instance name => value)."
                )
            output_blocks.append(
                "\n".join(
                    [f'output "{out_name}" {{']
                    + _attributes(
                        [
                            ("description", hcl_value(description)),
                            ("value", value),
                        ]
                    )
                    + ["}"]
                )
            )

    # Apply default overrides coming from the UI/CLI.
    for key, value in overrides.items():
        for _, section in variable_sections:
            if key in section:
                section[key] = {**section[key], "default": value}
                break
        else:
            if strict_overrides:
                raise ComposeError(f"Override for unknown variable '{key}'")

    _check_references(module_blocks + output_blocks, declared, bundle)

    header = "# Generated by the Terraform template generator on {}.\n# Services: {}\n\n".format(
        datetime.now(UTC).strftime("%Y-%m-%d %H:%M UTC"), ", ".join(order)
    )

    # versions.tf: a module may need a newer provider than the default range
    # (manifest key provider_versions); the strictest one wins.
    versions = {p: PROVIDERS[p]["version"] for p in providers_needed}
    for name in order:
        for p, constraint in modules[name].get("provider_versions", {}).items():
            if p in versions and _min_version(constraint) > _min_version(versions[p]):
                versions[p] = constraint
    provider_lines = []
    for p in sorted(providers_needed):
        provider_lines += [
            f"    {p} = {{",
            f'      source  = "{PROVIDERS[p]["source"]}"',
            f'      version = "{versions[p]}"',
            "    }",
        ]
    _write(
        out_dir / "versions.tf",
        "terraform {\n"
        f'  required_version = "{TERRAFORM_REQUIRED_VERSION}"\n\n'
        "  required_providers {\n" + "\n".join(provider_lines) + "\n  }\n}\n",
    )

    # providers.tf
    _write(
        out_dir / "providers.tf",
        'provider "aws" {\n'
        "  region = var.aws_region\n\n"
        "  # Common tags land on every taggable resource automatically.\n"
        "  default_tags {\n"
        "    tags = local.common_tags\n"
        "  }\n"
        "}\n",
    )

    # backend.tf
    _write(
        out_dir / "backend.tf",
        "# Remote state (recommended for teams). Uncomment, fill in, then run `terraform init`.\n"
        "# use_lockfile needs Terraform >= 1.10; on older versions use dynamodb_table instead.\n"
        "#\n"
        "# terraform {\n"
        '#   backend "s3" {\n'
        '#     bucket       = "my-terraform-state-bucket"\n'
        '#     key          = "myapp/dev/terraform.tfstate"\n'
        '#     region       = "us-east-1"\n'
        "#     encrypt      = true\n"
        "#     use_lockfile = true\n"
        "#   }\n"
        "# }\n",
    )

    # main.tf
    locals_block = (
        "locals {\n"
        '  name_prefix = "${var.project_name}-${var.environment}"\n\n'
        "  common_tags = merge(\n"
        "    {\n"
        "      Project     = var.project_name\n"
        "      Environment = var.environment\n"
        '      ManagedBy   = "terraform"\n'
        "    },\n"
        "    var.additional_tags,\n"
        "  )\n"
        "}\n"
    )
    _write(out_dir / "main.tf", header + locals_block + "\n" + "\n\n".join(module_blocks) + "\n")

    # variables.tf
    var_parts = []
    for title, section in variable_sections:
        if not section:
            continue
        var_parts.append(f"# {'-' * 75}\n# {title}\n# {'-' * 75}")
        var_parts += [_variable_block(n, s) for n, s in section.items()]
    _write(out_dir / "variables.tf", "\n\n".join(var_parts) + "\n")

    # outputs.tf
    _write(out_dir / "outputs.tf", "\n\n".join(output_blocks) + "\n")

    # terraform.tfvars.example
    tfvars_parts = [_tfvars_header(bundle)]
    for title, section in variable_sections:
        if not section:
            continue
        tfvars_parts.append(f"# ===== {title} =====")
        tfvars_parts += [_tfvars_line(n, s) for n, s in section.items()]
    _write(out_dir / "terraform.tfvars.example", "\n\n".join(tfvars_parts) + "\n")

    _write(out_dir / ".gitignore", GITIGNORE)
    _write(out_dir / "README.md", _readme(order, auto_added, modules))

    return {"modules": order, "auto_added": auto_added, "providers": sorted(providers_needed)}


def _min_version(constraint: str) -> tuple:
    m = re.search(r">=\s*([\d.]+)", constraint)
    return tuple(int(x) for x in m.group(1).split(".")) if m else (0,)


def _tfvars_header(bundle: set[str]) -> str:
    lines = [
        "# =============================================================================",
        "# HOW TO USE",
        "#   1. cp terraform.tfvars.example terraform.tfvars",
        "#   2. Edit the values below. Lines starting with '#' keep their default.",
        "#   3. terraform init && terraform plan && terraform apply",
        "#",
        "# You can change any value later: edit, run `terraform plan`, review, then",
        '# `terraform apply`. Watch the plan for "must be replaced", which means the',
        '# resource is deleted and recreated (see README.md, "Changing settings later").',
    ]
    if "vpc" in bundle:
        lines += [
            "#",
            "# NETWORK (choose one)",
            "#   vpc_create = false                       -> default VPC, public subnets only (default)",
            "#   vpc_create = true                        -> new VPC with public + private subnets",
            "#   vpc_create = false + vpc_existing_id     -> your existing VPC and subnet IDs",
            "# Then pick public or private per service with the *_subnet_type variables.",
        ]
    lines.append(
        "# =============================================================================\n"
    )
    return "\n".join(lines)


def _check_references(blocks: list[str], declared: set[str], bundle: set[str]) -> None:
    text = "\n".join(blocks)
    missing_vars = sorted(set(re.findall(r"\bvar\.([A-Za-z0-9_]+)", text)) - declared)
    missing_mods = sorted(set(re.findall(r"\bmodule\.([A-Za-z0-9_]+)", text)) - bundle)
    if missing_vars or missing_mods:
        raise ComposeError(
            f"Generated code references undefined variables {missing_vars} or modules {missing_mods}"
        )


def _readme(order: list[str], auto_added: list[str], modules: dict) -> str:
    rows = "\n".join(
        f"| `{n}` | {modules[n].get('display_name', n)} | "
        f"{'auto-included (dependency)' if n in auto_added else 'selected'} | "
        f"{modules[n].get('description', '')} |"
        for n in order
    )
    notes = "\n\n".join(
        f"### {modules[n].get('display_name', n)}\n\n{modules[n]['readme_notes'].strip()}"
        for n in order
        if modules[n]["readme_notes"].strip()
    )
    return f"""# Terraform bundle

Generated by the Terraform template generator. This bundle is self-contained: every
module it uses is in `modules/`, so no registry or Git access is needed for modules.

## What's inside

| Module | Service | Included because | Description |
|---|---|---|---|
{rows}

## Quick start

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit the values
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

At minimum, set `project_name`, `environment` and `aws_region` in `terraform.tfvars`.
Resource names are built as `<project_name>-<environment>-...`.

For team use, configure remote state in `backend.tf` before the first apply.

## Changing settings later

Everything here is meant to be edited. To change something after it is created:

1. Edit the value in `terraform.tfvars` (or anything under `modules/` for deeper changes).
2. Run `terraform plan` and read it before applying:
   - `~ update in-place`: changed without recreating, usually safe.
   - `-/+ must be replaced`: deleted and recreated. Expect downtime, new IDs/IPs, and
     **lost data** for databases, buckets, and instance disks.
3. Run `terraform apply`.

**Adding or removing instances:** each service has a `<service>_instances` map in
`terraform.tfvars`. Add a key to create one more; delete a key to destroy only that
instance. Renaming a key replaces that instance (the key is part of its resource names).

Moving between networks (for example `vpc_create = false` → `true`) replaces everything
that lives in the VPC: EC2 instances, ECS services and load balancers, and VPC-attached
Lambdas. Plan such changes for a maintenance window. Service-specific details are below.

## Files

| File | Purpose |
|---|---|
| `main.tf` | Calls the modules and wires their outputs together |
| `variables.tf` | Every setting you can change, grouped by service |
| `terraform.tfvars.example` | Ready-to-edit copy of all variables with defaults |
| `outputs.tf` | Useful values printed after apply |
| `providers.tf` / `versions.tf` | AWS provider config and version pins |
| `backend.tf` | Commented S3 remote state example |
| `modules/` | The modules used by this bundle |
| `validation_report.json` | Result of the checks run when the bundle was generated |

## Service notes

{notes or "_No extra notes._"}
"""


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
def _run(cmd: list[str], cwd: Path) -> dict:
    proc = subprocess.run(
        cmd, cwd=cwd, capture_output=True, text=True, encoding="utf-8", errors="replace"
    )
    return {
        "command": " ".join([Path(cmd[0]).name] + cmd[1:]),
        "exit_code": proc.returncode,
        "output": (proc.stdout + proc.stderr).strip()[-4000:],
    }


def validate(bundle_dir: Path, tf_binary: str | None = None) -> dict:
    """Format the bundle in place, then init + validate a throwaway copy so the
    shipped bundle carries no .terraform/ folder or platform-specific lock file."""
    tf = tf_binary or shutil.which("terraform") or shutil.which("tofu")
    if not tf:
        return {"status": "skipped", "reason": "terraform/tofu not found on PATH", "steps": []}

    steps = [_run([tf, "fmt", "-recursive", "-no-color"], bundle_dir)]
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp) / "bundle"
        shutil.copytree(bundle_dir, work)
        steps.append(_run([tf, "fmt", "-check", "-recursive", "-no-color"], work))
        steps.append(_run([tf, "init", "-backend=false", "-input=false", "-no-color"], work))
        if steps[-1]["exit_code"] == 0:
            steps.append(_run([tf, "validate", "-no-color"], work))
            # Optional linters: run if installed, reported but never blocking.
            if shutil.which("tflint"):
                lint = _run(["tflint", "--recursive", "--no-color"], work)
                lint["advisory"] = True
                steps.append(lint)
            if shutil.which("checkov"):
                scan = _run(
                    ["checkov", "-d", ".", "--quiet", "--compact", "--framework", "terraform"], work
                )
                scan["advisory"] = True
                steps.append(scan)

    blocking = [s for s in steps if not s.get("advisory")]
    status = "passed" if all(s["exit_code"] == 0 for s in blocking) else "failed"
    version = subprocess.run(
        [tf, "version"], capture_output=True, text=True, encoding="utf-8", errors="replace"
    ).stdout.splitlines()[0]
    return {"status": status, "tool": version, "steps": steps}


# ---------------------------------------------------------------------------
# Public entrypoint
# ---------------------------------------------------------------------------
def build_bundle(
    selected: list[str],
    output_dir: str | Path,
    overrides: dict | None = None,
    run_validation: bool = True,
    make_zip: bool = True,
    tf_binary: str | None = None,
    library_dir: Path = LIBRARY_DIR,
    strict_overrides: bool = True,
) -> dict:
    """strict_overrides=False silently ignores overrides for variables that are not
    in this bundle (e.g. ec2_subnet_type when EC2 isn't selected). Used by the web UI."""
    output_dir = Path(output_dir)
    bundle_dir = output_dir / "terraform-bundle"
    meta = generate(selected, bundle_dir, overrides, library_dir, strict_overrides)

    report = (
        validate(bundle_dir, tf_binary) if run_validation else {"status": "skipped", "steps": []}
    )
    report["generated_at"] = datetime.now(UTC).isoformat()
    report.update(meta)
    _write(bundle_dir / "validation_report.json", json.dumps(report, indent=2) + "\n")

    zip_path = None
    if make_zip and report["status"] != "failed":
        zip_path = shutil.make_archive(str(output_dir / "terraform-bundle"), "zip", bundle_dir)

    return {**report, "bundle_dir": str(bundle_dir), "zip_path": zip_path}


def _parse_override(item: str) -> tuple[str, object]:
    if "=" not in item:
        raise argparse.ArgumentTypeError(f"--set expects key=value, got '{item}'")
    key, raw = item.split("=", 1)
    return key.strip(), yaml.safe_load(raw)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Compose a Terraform bundle from the module library."
    )
    parser.add_argument("services", nargs="*", help="Services to include, e.g. ec2 s3 dynamodb")
    parser.add_argument("-o", "--output", default="./out", help="Output directory (default ./out)")
    parser.add_argument(
        "--set",
        dest="overrides",
        action="append",
        type=_parse_override,
        default=[],
        help="Override a variable default, e.g. --set aws_region=ap-south-1",
    )
    parser.add_argument(
        "--catalog", action="store_true", help="Print the UI catalog as JSON and exit"
    )
    parser.add_argument("--no-validate", action="store_true", help="Skip terraform validation")
    parser.add_argument("--no-zip", action="store_true", help="Do not create a zip")
    parser.add_argument("--tf-binary", help="Path to terraform or tofu (default: search PATH)")
    args = parser.parse_args()

    try:
        if args.catalog:
            print(json.dumps(catalog(), indent=2))
            return 0
        if not args.services:
            parser.error("give at least one service, or use --catalog")
        result = build_bundle(
            args.services,
            args.output,
            dict(args.overrides),
            run_validation=not args.no_validate,
            make_zip=not args.no_zip,
            tf_binary=args.tf_binary,
        )
    except ComposeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    print(f"Modules:    {', '.join(result['modules'])}")
    if result["auto_added"]:
        print(f"Auto-added: {', '.join(result['auto_added'])}")
    print(f"Validation: {result['status']}")
    for step in result["steps"]:
        flag = "ok " if step["exit_code"] == 0 else ("warn" if step.get("advisory") else "FAIL")
        print(f"  [{flag}] {step['command']}")
        if step["exit_code"] != 0:
            print("        " + step["output"].replace("\n", "\n        "))
    print(f"Bundle:     {result['bundle_dir']}")
    if result["zip_path"]:
        print(f"Zip:        {result['zip_path']}")
    return 0 if result["status"] != "failed" else 1


if __name__ == "__main__":
    sys.exit(main())
