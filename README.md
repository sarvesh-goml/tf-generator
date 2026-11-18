# Terraform Template Generator

A backend engine that turns a list of checked services (EC2, ECS, Lambda, ECR, S3,
DynamoDB) into a validated, ready-to-use Terraform bundle. A DevOps engineer downloads
the zip, edits one variables file, and runs `terraform apply`.

This README explains **what every file does**, in three parts:

1. [Project layout](#1-project-layout): the big picture
2. [Files in this repository](#2-files-in-this-repository): the module library, composer, and tests
3. [Files in a generated bundle](#3-files-in-a-generated-bundle): what the engineer receives

---

## 1. Project layout

```
tf-generator/
├── README.md                         ← this file
├── module-library/                   ← reusable Terraform modules (the "parts")
│   ├── foundation/
│   │   └── vpc/                      ← networking, auto-included, never shown in the UI
│   ├── deployment/                   ← UI group: "Deployment method"
│   │   ├── ec2/
│   │   ├── ecs/
│   │   └── lambda/
│   │       └── src/handler.py        ← sample Lambda code
│   └── services/                     ← UI group: "Other services"
│       ├── ecr/
│       ├── s3/
│       └── dynamodb/
├── composer/                         ← the engine that assembles bundles
│   ├── compose.py
│   └── requirements.txt
├── webapp/                           ← demo UI (standard-library Python server)
│   ├── server.py
│   └── static/index.html
└── tests/                            ← automated checks for CI
    ├── plan.tftest.hcl
    └── run_tests.sh
```

**How the pieces fit together:**

```
 UI checkboxes ──► compose.py ──► reads module.yaml files ──► resolves dependencies
                                                                     │
  zip to user ◄── validates with terraform ◄── writes root module ◄──┘
```

The modules are the parts; the manifests (`module.yaml`) are the instructions for
connecting them; the composer is the assembler.

## Run the demo UI

Needs Python 3.9+ and PyYAML. Terraform (or OpenTofu) on the PATH is optional: without
it, bundles are generated but not checked.

```bash
pip install -r composer/requirements.txt
python webapp/server.py            # then open http://127.0.0.1:8080
python webapp/server.py --port 9000
```

Tick services, adjust the settings, watch the bundle's file list build on the right, then
**Generate bundle**. The first checked bundle downloads the AWS provider (~150 MB) into
`.plugin-cache/`, which takes a minute or two; later bundles take a few seconds.

---

## 2. Files in this repository

### 2.1 Files every module has

Every folder under `module-library/` follows the same structure. Once you understand
one, you understand all seven.

| File | Purpose | When you edit it |
|---|---|---|
| `main.tf` | The actual AWS resources (instances, buckets, roles, security groups). | Changing what the module creates or how. |
| `variables.tf` | The module's inputs, with types, defaults, descriptions and validation rules. Every module accepts `name_prefix` and `tags`. | Adding a new setting. |
| `outputs.tf` | Values the module exposes to others (IDs, ARNs, URLs). This is how one module feeds another, e.g. `module.vpc.vpc_id` → EC2. | Another module needs a value from this one. |
| `versions.tf` | Minimum Terraform version and provider version ranges. Contains **no** `provider` block: the generated root owns the provider. | Upgrading provider support. |
| `module.yaml` | **Manifest for the composer.** Not Terraform. Describes how the module plugs into a bundle. Never copied into bundles. | Adding root variables, outputs, or wiring. |

### 2.2 The manifest (`module.yaml`) explained

This is the file that makes mix-and-match work. Example (trimmed from EC2):

```yaml
name: ec2                    # unique ID, used by the UI and the CLI
category: deployment         # foundation | deployment | services → UI group
display_name: EC2            # checkbox label
description: Single EC2 ...  # checkbox help text
selectable: true             # false = hidden from UI (only pulled in as a dependency)
requires: [vpc]              # always included alongside this module
providers: [aws]             # providers the bundle must declare

inputs:                      # module argument → expression in the generated main.tf
  vpc_id: module.vpc.vpc_id
  instance_type: var.ec2_instance_type

optional:                    # extra wiring, ONLY if that other module is also selected
  s3:
    inputs:
      s3_bucket_arns: "[module.s3.bucket_arn]"

root_variables:              # variables the engineer edits in terraform.tfvars
  ec2_instance_type:
    type: string
    default: t3.micro
    description: EC2 instance type.

outputs:                     # values printed after `terraform apply`
  ec2_instance_id:
    value: module.ec2.instance_id
    description: EC2 instance ID.

readme_notes: |              # copied into the bundle README under "Service notes"
  Connect with: aws ssm start-session ...

multi: true                  # several instances via an ec2_instances map (see below)
per_instance: [ec2_instance_type, ec2_subnet_type]   # root vars overridable per instance
instance_only:               # settings that only make sense per instance
  subnet_id: string
ui_order: 1                  # position of the checkbox in its UI group

features:                    # optional add-ons shown as checkboxes in the UI
  - id: elastic_ip
    label: Elastic IP
    description: Static public IP that stays the same across stop/start.
    variable: ec2_enable_elastic_ip   # root variable the add-on sets...
    value: true                       # ...to this value
    requires_setting: { ec2_subnet_type: public }   # UI disables it otherwise
    requires_hint: Needs EC2 in a public subnet.

provider_versions:           # only if this module needs a newer provider
  aws: ">= 6.28, < 7.0"
```

**Add-ons (`features`).** An add-on is just a root variable plus the value that switches
it on, so it works everywhere a variable does: in `terraform.tfvars`, per instance in
the `<service>_instances` map (if the variable is in `per_instance`), and as a checkbox
in the UI. The composer checks that each add-on's variable exists and that its value is
one of the variable's `options`.

**Multiple instances (`multi: true`).** The composer turns the module into
`for_each = var.<name>_instances`, a map whose keys are instance names. For every
variable listed in `per_instance`, the module gets
`each.value.<setting> != null ? each.value.<setting> : var.<name>_<setting>`, so an
instance uses the shared default unless it overrides it. `instance_only` settings
(explicit resource names, pinned subnets) exist only inside the map. Each instance's
`name_prefix` becomes `<project>-<env>-<key>`, and outputs become maps keyed by
instance name. Wiring to a multi module uses a for-expression, e.g.
`[for m in module.s3 : m.bucket_arn]`, which grants access to every bucket.

Naming rule: root variables are prefixed with the module name (`ec2_`, `ecs_`, `s3_`...)
so two modules can never clash.

### 2.3 The modules

#### `foundation/vpc/`: networking (auto-included)

Included automatically when EC2 or ECS is selected. Never appears as a checkbox.
The engineer picks the network with one variable:

| `vpc_create` | Network used | Subnets | Cost |
|---|---|---|---|
| `false` (default) | The account's **default VPC** (looked up automatically) | public only | free |
| `true` | A **new dedicated VPC** built by the bundle | public + private | NAT gateway billed hourly |
| `false` + `vpc_existing_id` | An **existing VPC** | the subnet IDs listed | free |

With `vpc_create = true` it creates: VPC with DNS support (`10.0.0.0/16`), public and
private subnets across 2 AZs (CIDRs calculated automatically), internet gateway, route
tables, NAT gateway (one shared, or one per AZ), and a locked-down default security group.

Each compute service then chooses **public or private** independently with its own
`*_subnet_type` variable. Outputs: `mode` (`new` / `default` / `existing`), `vpc_id`,
`vpc_cidr_block`, `public_subnet_ids`, `private_subnet_ids`, `nat_gateway_ids`.

#### `deployment/ec2/`: virtual machine

| Creates | Notes |
|---|---|
| EC2 instance | Latest Amazon Linux 2023 by default (looked up from AWS's public SSM parameter), x86_64 or arm64 |
| Security group | **No inbound ports** by default; add rules via `ec2_ingress_rules` |
| IAM role + instance profile | SSM Session Manager access, so no SSH key needed |
| Inline access policy | Only if S3 / DynamoDB / ECR are in the bundle, scoped to those exact resources |

Placement: `ec2_subnet_type = "public"` (default, gets a public IP) or `"private"`
(no public IP). `ec2_subnet_id` pins an exact subnet. Asking for `private` on the
default VPC stops at plan time with a message explaining what to change.

Hardening: IMDSv2 required, encrypted root volume, AMI changes ignored so a new AMI
release doesn't replace a running server.

#### `deployment/ecs/`: containers on Fargate

| Creates | Notes |
|---|---|
| ECS cluster | Container Insights on; Fargate and Fargate Spot capacity providers |
| Task definition | One container named `app`; CPU, memory, port, env vars configurable |
| ECS service | Public or private subnets via `ecs_subnet_type` (default public); auto-rollback on failed deployments (circuit breaker) |
| Execution role | Lets ECS pull images and write logs |
| Task role | Your app's permissions (S3/DynamoDB access added automatically when present) |
| Application Load Balancer | Optional (on by default). HTTPS on 443 with HTTP→HTTPS redirect when `ecs_certificate_arn` is set |
| Security groups | ALB open to the internet; tasks only reachable from the ALB |
| CloudWatch log group | `/ecs/<project>-<env>`, 14-day retention |

Starts with a public nginx image so the first apply works; swap in your own image
via `ecs_container_image`. Output `ecs_service_url` gives the public URL.

#### `deployment/lambda/`: serverless function

| Creates | Notes |
|---|---|
| Lambda function | Python 3.12 by default; code zipped automatically from a folder |
| IAM execution role | Basic logging; VPC and X-Ray policies added only when needed |
| CloudWatch log group | Created *before* the function so retention applies from day one |
| Security group | Only when running inside a VPC |
| `src/handler.py` | Sample "hello" function. Replace it, or point `lambda_source_dir` at your own folder |

When the bundle also contains a VPC (because EC2/ECS were picked), an extra variable
`lambda_attach_to_vpc` appears. It needs private subnets, so it works with
`vpc_create = true` or an existing VPC, not the default VPC. Uses the `archive` provider to build the zip into `.build/`.

#### `services/ecr/`: container registry

| Creates | Notes |
|---|---|
| ECR repository | Scan on push, encryption, **immutable tags** (set `MUTABLE` to re-push `latest`) |
| Lifecycle policy | Deletes untagged images after 7 days; keeps the last 30 images |

The bundle README includes copy-paste `docker login / build / push` commands.

#### `services/s3/`: storage bucket

| Creates | Notes |
|---|---|
| S3 bucket | Unique name generated automatically unless `s3_bucket_name` is set |
| Public access block | All four settings on |
| Ownership controls | ACLs disabled (bucket owner owns everything) |
| Versioning | On; old versions deleted after 90 days |
| Encryption | AES256 by default, KMS optional |
| Lifecycle rules | Also aborts stuck multipart uploads after 7 days |
| Bucket policy | Rejects any non-HTTPS request |

#### `services/dynamodb/`: NoSQL table

| Creates | Notes |
|---|---|
| DynamoDB table | On-demand billing, partition key `id` (string); optional sort key |
| Encryption | Always on; customer KMS key optional |
| Point-in-time recovery | On (restore to any second in the last 35 days) |
| Optional | TTL attribute, streams, provisioned capacity, deletion protection (turn on for prod) |

### 2.4 The composer

#### `composer/compose.py`

The engine. Your web backend imports it; it also works from the command line.

| Function | What it does |
|---|---|
| (manifest `options`) | A root variable with `options: [a, b]` automatically gets a `validation` block and an `# Options: "a" \| "b"` hint in the tfvars file. |
| `load_library()` | Reads every `module.yaml` and **lints** it: inputs that don't exist in the module, required module variables left unset, unknown dependencies or providers. A broken manifest fails immediately instead of producing a broken bundle. |
| `catalog()` | Returns JSON for the UI: two groups ("Deployment method", "Other services") with ID, label, description and auto-included dependencies for each checkbox. |
| `resolve()` | Expands the selection with everything in `requires`, orders dependencies first, rejects unknown or hidden services and detects cycles. |
| `_effective()` | Adds `optional` wiring for modules whose partner is in the bundle. |
| `generate()` | Copies the needed modules into `modules/` and writes all root files (section 3). Also checks that every `var.x` and `module.y` referenced actually exists. |
| `validate()` | Runs `fmt`, `init -backend=false`, `validate` (plus `tflint` / `checkov` if installed, as advisory). Init runs on a temporary copy so the zip never contains `.terraform/` or a lock file tied to the server's OS. |
| `build_bundle()` | **Main entry point.** generate → validate → write `validation_report.json` → zip. Returns status and zip path. No zip is produced if validation fails. |
| `main()` | Command-line interface. |
| `hcl_value()`, `_attributes()`, `_variable_block()`, `_tfvars_line()`, `_readme()` | Helpers that render Python values and text as neatly aligned HCL and Markdown. |

Constants at the top of the file you may want to change: `PROVIDERS` (version
ranges), `BASE_VARIABLES` (variables every bundle gets), `UI_CATEGORIES` (group labels).

**From the backend:**

```python
from compose import build_bundle, catalog

catalog()  # feed the UI
result = build_bundle(
    ["ec2", "s3"],  # checked boxes
    output_dir="/tmp/job-123",  # unique per request
    overrides={"aws_region": "ap-south-1"},  # optional form values
)
result["status"]  # "passed" | "failed" | "skipped"
result["zip_path"]  # send this file to the user
```

**From the command line:**

```bash
python composer/compose.py --catalog                       # UI JSON
python composer/compose.py ec2 s3 -o ./out                 # build a bundle
python composer/compose.py ecs ecr --set ecs_desired_count=2
python composer/compose.py lambda --no-validate --no-zip   # quick local preview
```

Exit codes: `0` success, `1` validation failed, `2` invalid selection or broken manifest.

#### `composer/requirements.txt`

Python dependency: `PyYAML`. Install with `pip install -r composer/requirements.txt`.
The server also needs `terraform` (or `tofu`) on its PATH.

### 2.5 Demo UI

#### `webapp/server.py`

A small web server built only on the Python standard library. It serves the page and
three endpoints, all calling the composer:

| Endpoint | Purpose |
|---|---|
| `GET /api/catalog` | Services for the checkboxes (in `ui_order` from the manifests) and whether Terraform is installed |
| `POST /api/generate` | Body `{"services": [...], "counts": {"ec2": 3}, "features": {"lambda": ["function_url"]}, "settings": {...}, "validate": true}`. Each add-on id is looked up in the manifest and becomes its variable setting. A count becomes `ec2_instances = { "1" = {}, "2" = {}, "3" = {} }` (1 to 20 per service). Optional `"names": {"ec2": ["web", "worker"]}` sets the instance keys instead (`ec2_instances = { web = {}, worker = {} }`) and takes precedence over `counts`; names must be unique, 1-15 lowercase letters, digits or hyphens. Builds the bundle and returns the check results, the file list, previews of the main files, and a download link |
| `GET /api/download/<id>` | The zip. Bundles are kept for one hour in the system temp folder |

It accepts only a fixed set of settings (`project_name`, `environment`, `aws_region`,
`vpc_create`, `ec2_subnet_type`, `ecs_subnet_type`, `lambda_attach_to_vpc`) and checks
each value. Settings for services that aren't selected are ignored. Builds run one at a
time so parallel `terraform init` runs don't collide on the shared provider cache.

This is a demo server: it listens on `127.0.0.1` only and has no login. Put a proper
framework (FastAPI, Django, etc.) and authentication in front before exposing it to others.

#### `webapp/static/index.html`

The whole UI in one file (HTML, CSS and JavaScript, no build step). Checkbox groups come
from the catalog, so new services appear automatically. Ticking a multi-instance service
shows an "Instances" stepper, one name field per instance (default `1`, `2`, …), and its
add-ons. After generation, a "Rename services" panel lets you change those names and
regenerate; names become the `<service>_instances` keys, so they appear in resource names
as `<project>-<env>-<name>`. Add-ons whose requirement isn't met
(for example Elastic IP while EC2 is private) are disabled with a short explanation. Settings only show when relevant
(network for EC2/ECS, placement per service, Lambda-in-VPC for a new VPC), and "Private"
is disabled on the default VPC. Orange-and-white light theme with a mobile layout.

### 2.6 Tests

#### `tests/plan.tftest.hcl`

A Terraform test that runs a full **plan** of the all-services bundle using **mocked
AWS providers**, so no AWS account or credentials are needed. It catches mistakes that
`terraform validate` misses (counts, conditionals, preconditions). Scenarios covered:

| Run | Checks |
|---|---|
| `defaults_use_default_vpc_public` | Default VPC is used, its subnets discovered and sorted, no private subnets, no NAT |
| `new_vpc_everything_private_https` | New VPC over 3 AZs with a NAT per AZ; EC2, ECS and Lambda all private; HTTPS listener; DynamoDB with sort key, TTL and provisioned billing |
| `new_vpc_mixed_public_private` | New VPC with EC2 public and ECS private |
| `existing_vpc_no_alb` | Existing VPC, EC2 pinned to a subnet, ECS without load balancer, fixed bucket name |
| `bad_subnet_type_rejected` | `ec2_subnet_type = "dmz"` is rejected |
| `bad_project_name_rejected` | Invalid `project_name` is rejected |
| `case_clashing_tags_rejected` | `additional_tags = { project = ... }` is rejected at plan time (IAM treats tag keys as case-insensitive) |
| `extra_tags_accepted` | Normal extra tags still work |
| `many_instances_with_overrides` | 3 EC2, 2 ECS, 2 Lambda, 2 ECR, 2 S3, 2 DynamoDB with per-instance overrides; instance keys appear in resource names |
| `zero_instances_of_a_service` | An empty map creates nothing |
| `long_names_keep_load_balancers_unique` | Long project and instance names still give distinct 32-character ALB names |
| `bad_instance_key_rejected` | Instance names with capitals or underscores are rejected |
| `all_add_ons_with_per_instance_choices` | Every add-on, switched on for some instances and off for others; Elastic IP and function URL appear only where enabled |

Also verified by hand: asking for private EC2, private ECS or a VPC-attached Lambda on
the default VPC each stops at plan time with a message naming the variable to change.

#### `tests/run_tests.sh`

Builds a bundle with all six services, copies the test file in, and runs
`terraform test`. Use it in CI on every change to the library:

```bash
./tests/run_tests.sh                      # uses terraform or tofu from PATH
TF_BINARY=/usr/local/bin/tofu ./tests/run_tests.sh
```

---

## 3. Files in a generated bundle

This is what the DevOps engineer gets in the zip (example: EC2 + S3 selected):

```
terraform-bundle/
├── main.tf                    ← calls the modules and wires them together
├── variables.tf               ← every setting, grouped by service
├── terraform.tfvars.example   ← THE file the engineer edits
├── outputs.tf
├── providers.tf
├── versions.tf
├── backend.tf
├── README.md
├── .gitignore
├── validation_report.json
└── modules/
    ├── vpc/                   ← auto-added because EC2 needs it
    ├── ec2/
    └── s3/
```

| File | Purpose | Should the engineer edit it? |
|---|---|---|
| `terraform.tfvars.example` | Starts with a how-to and the network choices, then every variable with its default, a comment, and allowed options. Copy to `terraform.tfvars` and change values. Lines starting with `#` keep their defaults. | **Yes, this is the main file to edit** |
| `main.tf` | A `locals` block (name prefix `<project>-<env>`, common tags) and one `module` block per service, with outputs of one module passed into another. | Rarely |
| `variables.tf` | Declarations for all settings: general (`aws_region`, `project_name`, `environment`, `additional_tags`) then one section per service. | Only to change defaults permanently |
| `outputs.tf` | Values shown after apply: instance IDs, bucket names, service URL, repository URL, etc. Read them later with `terraform output`. | Optional |
| `providers.tf` | AWS provider using `var.aws_region`, with **default tags** (`Project`, `Environment`, `ManagedBy`) applied to every resource. | Rarely |
| `versions.tf` | Required Terraform version (>= 1.5) and provider versions (AWS 5.x or 6.x; `archive` only if Lambda is included). | Rarely |
| `backend.tf` | Commented-out S3 remote state example. Uncomment and fill in before the first apply when a team shares the infrastructure. | **Yes, for team use** |
| `README.md` | Generated per bundle: which services are inside and why, quick start, **changing settings later** (in-place vs replace), and per-service notes (network table, SSM connect, docker push, Lambda test, what's safe to change). | No |
| `.gitignore` | Keeps state files, `.terraform/`, `terraform.tfvars` (may hold secrets) and `.build/` out of Git. | No |
| `validation_report.json` | Proof the bundle was checked: tool version, each command run, its exit code and output, the modules included and which were auto-added. | No |
| `modules/` | Copies of only the modules this bundle needs. Self-contained: no internet or Git access needed for modules. | Only to customise deeper behaviour |

**Creating several of a service.** Every service has a `<service>_instances` map in
`terraform.tfvars`. Keys are instance names and become part of resource names; values
override the shared `<service>_*` defaults for that instance only:

```hcl
ec2_instances = {
  web    = {}                                              # uses ec2_* defaults
  worker = { instance_type = "t3.small", subnet_type = "private" }
}
dynamodb_instances = {
  users  = { hash_key = "user_id" }
  orders = { hash_key = "order_id", range_key = "created_at" }
}
```

Add a key to create one more; delete a key to destroy only that one; `{}` creates none.
Outputs such as `ec2_instance_id` become maps: `terraform output ec2_instance_id`.

**Add-ons.** Optional extras are off by default and are switched on with a variable,
for every instance or per instance:

| Service | Add-on | Variable (shared default) | Per-instance key |
|---|---|---|---|
| EC2 | Elastic IP (public subnet only) | `ec2_enable_elastic_ip` | `enable_elastic_ip` |
| EC2 | Extra encrypted data disk | `ec2_data_volume_size` (GiB, 0 = none) | `data_volume_size` |
| EC2 | Detailed monitoring | `ec2_detailed_monitoring` | `detailed_monitoring` |
| Lambda | Function URL | `lambda_enable_function_url`, `lambda_function_url_auth` | `enable_function_url`, `function_url_auth` |
| Lambda | Schedule | `lambda_schedule_expression` | `schedule_expression` |
| Lambda | X-Ray tracing | `lambda_enable_xray` | `enable_xray` |
| ECS | Auto scaling on CPU | `ecs_autoscaling_max_count` (0 = off) | `autoscaling_max_count` |
| ECS | ECS Exec | `ecs_enable_execute_command` | `enable_execute_command` |
| ECR | Re-pushable tags | `ecr_image_tag_mutability = "MUTABLE"` | `image_tag_mutability` |
| ECR | Delete with images | `ecr_force_delete` | `force_delete` |
| S3 | Move to Standard-IA | `s3_transition_to_ia_days` (min 30) | `transition_to_ia_days` |
| S3 | Delete with objects | `s3_force_destroy` | `force_destroy` |
| DynamoDB | Streams | `dynamodb_stream_view_type` | `stream_view_type` |
| DynamoDB | TTL | `dynamodb_ttl_attribute` | `ttl_attribute` |
| DynamoDB | Deletion protection | `dynamodb_deletion_protection` | `deletion_protection` |

```hcl
ec2_instances = {
  web    = { enable_elastic_ip = true, data_volume_size = 100 }
  worker = { subnet_type = "private" }
}
lambda_instances = {
  api     = { enable_function_url = true }
  nightly = { schedule_expression = "cron(0 2 * * ? *)" }
}
```

**Engineer workflow:**

```bash
unzip terraform-bundle.zip && cd terraform-bundle
cp terraform.tfvars.example terraform.tfvars   # edit project_name, environment, aws_region...
terraform init
terraform plan -out=tfplan
terraform apply tfplan
terraform output                               # see IDs, URLs, names
```

**Changing things after creation:** edit `terraform.tfvars`, run `terraform plan`, then
`terraform apply`. The plan marks each change as `update in-place` (safe) or
`must be replaced` (deleted and recreated). Common examples:

| Change | Effect |
|---|---|
| `ec2_instance_type` | In place (brief stop/start) |
| `ec2_subnet_type`, an instance's `subnet_id` | That EC2 instance replaced (new IPs, root disk data lost) |
| Adding / removing a key in `<service>_instances` | Creates / destroys only that instance |
| Renaming a key | That instance is replaced (the key is part of its names) |
| `ecs_container_image`, CPU, memory, desired count | New ECS deployment, no downtime |
| `ecs_subnet_type` | ECS tasks restarted in the new subnets |
| Lambda code, memory, timeout | In place |
| `vpc_create` false → true | Everything inside the VPC is recreated |
| A bucket's `bucket_name` | That bucket replaced (must be empty, or `force_destroy = true`) |
| A table's keys or `table_name` | That table replaced, **all its data lost** |

Files that appear **after** the engineer runs Terraform (all git-ignored except the lock file):

| File | Created by | Meaning |
|---|---|---|
| `.terraform/` | `terraform init` | Downloaded providers and module links |
| `.terraform.lock.hcl` | `terraform init` | Locks provider versions. **Commit this** |
| `terraform.tfstate` | `terraform apply` | Record of what exists in AWS. Use remote state (`backend.tf`) for teams |
| `.build/*.zip` | `terraform plan` with Lambda | Packaged Lambda code |

---

## 4. Adding a new service (quick reference)

1. Create `module-library/services/<name>/` with `main.tf`, `variables.tf`,
   `outputs.tf`, `versions.tf` (copy `versions.tf` from any existing module).
2. Accept `name_prefix` and `tags`; don't add a `provider` block.
3. Write `module.yaml`: `requires`, `inputs`, `root_variables` prefixed `<name>_`,
   `outputs`, optional `readme_notes`.
4. Optionally add an `optional: { <name>: ... }` entry to EC2/ECS/Lambda manifests to
   grant them access to the new service.
5. Run `python composer/compose.py --catalog` (lints all manifests), then
   `./tests/run_tests.sh`.

No changes to `compose.py` are needed. The UI picks up the new checkbox from `catalog()`.

---

## 5. Compatibility

Bundles that include **Lambda** need AWS provider **6.28 or newer**. Since October 2025
AWS requires two permissions for public function URLs, and 6.28 is the first provider
version that adds both. Bundles without Lambda work with provider 5.x and 6.x.

Tested with OpenTofu 1.8 against AWS provider 6.68 (all services) and 5.100 (bundles
without Lambda). Earlier testing also covered 6.0. Requires Terraform or
OpenTofu >= 1.5 (mocked-provider tests need >= 1.7). Not yet applied against a live
AWS account; do a sandbox `apply` of each module before production use.
