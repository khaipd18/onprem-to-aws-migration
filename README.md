# On-Premise → AWS Migration

**[🇻🇳 Đọc bản tiếng Việt →](README.vi.md)**

A three-tier on-premise order system migrated to AWS with zero data loss, built entirely
in Terraform. Ships with a working application so the failure modes are **measured, not
claimed**.

![Terraform](https://img.shields.io/badge/Terraform-%E2%89%A5_1.9-7B42BC?logo=terraform&logoColor=white)
![AWS Provider](https://img.shields.io/badge/AWS_Provider-~%3E_6.0-FF9900?logo=amazonwebservices&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)
![Region](https://img.shields.io/badge/Region-ap--southeast--1-232F3E?logo=amazonaws&logoColor=white)

> **Scope.** This repository is the **infrastructure and migration** work: the Terraform
> that builds the target platform, and the DMS/DataSync path off the legacy servers. The
> application is the *workload under test* — it exists so there is something real to
> migrate, and something real to aim chaos tests at.

---

## Scenario

A manufacturer with ~150 users runs Web, Application and PostgreSQL tiers on three
separate physical machines: manual backups, no DR, manual releases. Traffic peaks at
4–5× and the system has gone down under it before.

The migration has to happen **while transactions keep arriving**, with ≤ 15 minutes of
downtime and no lost or duplicated orders.

The company is fictional. The infrastructure is not — the stack was applied and
destroyed on a real AWS account on 2026-09-11:
`Apply complete! Resources: 165 added` → `Destroy complete! Resources: 165 destroyed`,
nothing orphaned.

| | |
|---|---|
| **Infrastructure** | 11 Terraform modules, 165 resources, `ap-southeast-1` |
| **Compute** | EC2 `t4g.small` (Graviton), ASG 2–6, warm pool 2 |
| **Database** | RDS PostgreSQL 16.10 `db.t4g.micro`, Multi-AZ, behind RDS Proxy |
| **Queue** | SQS FIFO + DLQ · DynamoDB accept store for deduplication |
| **Web tier** | CloudFront + S3 static SPA — not EC2 |
| **File share** | EFS with per-department access points |
| **Migration** | DMS `full-load-and-cdc` + DataSync |
| **Application** | Python 3.12 + FastAPI (app tier, worker, SPA) |

---

## Architecture

![AWS architecture](docs/img/architecture.png)

Source: [`docs/diagrams/architecture.drawio`](docs/diagrams/architecture.drawio) ·
all six diagrams: [`docs/architecture.md`](docs/architecture.md)

### The application contract the platform has to uphold

> **The API never reports success before the database has committed.**

```
POST /api/orders       →  202 Accepted   { order_id, status: "PENDING" }
                          ↑ "request received", nothing more

GET  /api/orders/{id}  →  { status: "CONFIRMED" }
                          ↑ this is the committed transaction
```

The worker deletes a message from the queue only after the transaction commits. That one
rule is the reason the platform is shaped the way it is — every row below is an
infrastructure parameter chosen to make it hold:

| Infrastructure decision | Follows from |
|---|---|
| SQS **FIFO** with `MessageDeduplicationId` = idempotency key, not Standard | A redelivered order must never become a second order |
| Visibility timeout **180s**, backoff `min(60 × receive_count, 600)` | Retries have to outlast a 3-minute database outage |
| DLQ at `maxReceiveCount = 5`, 14-day retention, alarm on the first message | A message that failed five times is an operator problem, not a retry problem |
| DynamoDB accept store **outside** RDS | Deduplication has to survive the database it protects |
| ALB target group polls `/ready`, not `/health` | An unreachable database must not make the ASG terminate healthy instances |
| RDS Proxy between app and database | Connections must survive Multi-AZ failover without a restart |

### Decisions worth defending

| Decision | Why |
|---|---|
| Web tier is a **static SPA on CloudFront + S3**, not EC2 | Keeps Web/App separation, saves ~$47/month, removes an entire patching surface |
| **DynamoDB + SQS live outside RDS** | If the accept store shared a database with the `orders` table, deduplication would die exactly when RDS dies — precisely when it is needed |
| **RDS Proxy** between app and database | `db.t4g.micro` tolerates ~85 connections, the ASG can reach 6 instances. The proxy pools connections and holds them across Multi-AZ failover |
| **Warm pool in `Stopped` state** | Standby capacity ready in 30–40s instead of 2–3 minutes, at the cost of EBS only (~$0.60/month) |

---

## Network

![VPC layout](docs/img/network.png)

| Tier | CIDR | Route to `0.0.0.0/0` | Contains |
|---|---|---|---|
| `public` · 2 AZ | `10.0.0.0/24`, `10.0.1.0/24` | Internet Gateway | ALB, NAT Gateway |
| `private` · 2 AZ | `10.0.10.0/24`, `10.0.11.0/24` | NAT Gateway | App tier EC2 + worker |
| `data` · 2 AZ | `10.0.20.0/24`, `10.0.21.0/24` | **none** | RDS, RDS Proxy, EFS mount targets, DMS, DataSync ENI |

What separates `private` from `data` is the **route table**, not the name. The `data`
tier has only the `local` route; merging the two would give RDS and the EFS mount
targets a path to the internet and destroy the isolation.

There is **one NAT Gateway**, in AZ `1a`, with both private subnets routing through it —
a deliberate cost trade-off (~$43/month for the second one). If AZ `1a` fails, private
`1b` loses egress; *inbound* traffic through the ALB is unaffected.

An S3 Gateway Endpoint is attached to all four route tables, so S3 traffic bypasses NAT.
`map_public_ip_on_launch = false` on both public subnets.

### Security groups

| Security group | Ingress | Source |
|---|---|---|
| `sg-alb-public` | `tcp/80`, `tcp/443` | `0.0.0.0/0` |
| `sg-app` | `tcp/8080` | `sg-alb-public` |
| `sg-rds-proxy` | `tcp/5432` | `sg-app` |
| `sg-rds` | `tcp/5432` | `sg-rds-proxy` **and** `sg-app` (fallback if the proxy fails) |
| `sg-fileserver` | `tcp/2049` | `sg-app`, `sg-admin-client` |
| `sg-admin-client` | — | no ingress; exists only to be referenced as a source |

Only `sg-alb-public` opens by CIDR. Every other rule uses
`referenced_security_group_id`, so adding or replacing instances never means editing
rules and no IP is hard-coded. Egress is `all → 0.0.0.0/0` on all six — outbound control
is enforced by route tables, not security groups.
[Diagram →](docs/img/security-groups.png)

---

## Behaviour under failure

![Order lifecycle](docs/img/request-flow.png)

When RDS becomes unreachable:

- `COMMIT` fails → the worker does **not** call `DeleteMessage` → the message stays
  queued → the order stays `PENDING`. Nobody receives a false success.
- After the 180s visibility timeout SQS redelivers. Backoff grows as
  `min(60 × receive_count, 600)` — roughly 10 minutes total.
- RDS returns → the same worker (no restart) drains the queue. Redelivered messages hit
  `ON CONFLICT DO NOTHING`, so no duplicate orders.
- Past `maxReceiveCount = 5` the message lands in `orders-dlq.fifo`, retained 14 days,
  and the `dlq-not-empty` alarm fires on the first occurrence.

---

## Migration

| Source | Tool | Target |
|---|---|---|
| On-premise PostgreSQL | **DMS** `full-load-and-cdc`, replication instance in the data subnet, `publicly_accessible = false` | RDS PostgreSQL primary |
| On-premise file server | Upload to **S3 staging**, then **DataSync** | EFS file system |

Terraform provisions the replication instance, both endpoints and the task, but sets
`start_replication_task = false` — the task does **not** start itself, an operator
triggers it. The S3 staging bucket is deliberately outside this stack: passed in as
`migration_files_bucket_arn`, read access granted through `datasync_role_arn`.

[Diagram →](docs/img/migration.png) ·
[Runbooks → (VI)](docs/ban-giao/migration/)

---

## Observability

Application logs are JSON carrying a `correlation_id` across tiers. The app tier mints
the id on request, attaches it to the SQS message, the worker logs under the same id,
and the `order_events` table stores it per row — one Logs Insights query reconstructs an
order's entire path.

8 CloudWatch alarms, 4 saved Logs Insights queries, a dashboard, SNS notifications.
`alarm_actions` and `ok_actions` point at the same topic, so recovery is announced too.
[Diagram →](docs/img/observability.png)

---

## Measured results

The system is tested against 10 explicit requirements. Numbers below are observed, not
estimated.

### Platform and migration

| Scenario | Req | Where | Result |
|---|---|---|---|
| `terraform apply` then `destroy` | #8 | AWS | 165 added, 165 destroyed, nothing orphaned |
| Kill an app instance mid-traffic | #4 | AWS | **Pass** — 44s gap against a 120s budget |
| Cut database connectivity for 90s | #5 | AWS | **Pass** — 0 false successes, `/health` recovered in 11s |
| RDS Multi-AZ failover | #5 | AWS | **Pass** — 13–20s gap, app and worker `NRestarts=0` |
| Point-in-time recovery of deleted orders | #6 | AWS | **Pass** — RTO 12m49s, RPO 5–7min, 50/50 orders |
| Revoke file-server permissions | #7 | AWS | **Fail, as designed** — see below |
| Cutover under live transactions | #2 | local | 1.1s service interruption, 3,587 orders reconciled, totals exact |
| Per-department file permission matrix | #7 | local | 30/30 |

### Application behaviour on top of it

| Scenario | Req | Where | Result |
|---|---|---|---|
| Same idempotency key sent 5× | #3 | AWS | **Pass** — exactly 1 `order_id` |
| 10 concurrent updates to one order | #3 | AWS | **Pass** — one `200`, nine `409` |
| Parallel reporting under transaction load | #10 | local | 5 jobs, identical checksum, order-create p95 61ms |
| Full test matrix (`scripts/test-all.sh`) | — | local | 21/21 pass |

Local p95 figures are small because the dataset is only 12,000 orders — they demonstrate
**correct behaviour**, not capacity.

<details>
<summary><b>The 10 requirements</b></summary>

| # | Requirement | Implementation |
|---|---|---|
| 1 | Runs independently once on-premise is powered off | No reverse dependencies remain |
| 2 | Migrate under live transactions, downtime ≤ 15 min | DMS `full-load-and-cdc`, order ledger reconciled before/after cutover |
| 3 | No duplicate orders | DynamoDB accept store (`ConditionExpression`) + `UNIQUE(idempotency_key)` |
| 3 | No silent overwrites | `version` column, `UPDATE ... WHERE version = $expected` → `409` |
| 4 | Survive 5× load, p95 ≤ 2s, interruption ≤ 2 min | Tier separation, queue absorbs write spikes, ASG + warm pool |
| 5 | DB down 3 min, self-healing, no false success | API returns `202`; worker deletes the message only after commit |
| 6 | RPO ≤ 5 min, RTO ≤ 30 min | RDS PITR into a temporary instance, then reinsert |
| 7 | Per-department file permissions, revocation ≤ 5 min | EFS access points + manifest checksum |
| 8 | Transaction traceability, reproducible environment | `correlation_id` across tiers, `order_events` table, all infra in Terraform |
| 9 | Cost control, absorb a 20% budget cut | Two sizing profiles, scheduled-shutdown levers |
| 10 | Parallel reporting must not slow OLTP | `REPEATABLE READ` on the replica, explicit cutoff |

Full mapping: [`docs/ban-giao/anh-xa-rang-buoc.md` (VI)](docs/ban-giao/anh-xa-rang-buoc.md)

</details>

---

## Two designs that measurement proved wrong

**EFS does not re-evaluate access points on each I/O operation.** The first version of
the design document stated "delete the access point → the open mount loses access on its
next operation" — reasoned, not measured. Measured, an already-open mount kept reading
and writing for **283 seconds**, well past requirement #7's 5-minute bound. The procedure
became two steps: delete the access point (blocking new mounts) **and** force `umount -f`
via SSM Run Command.

**Backoff shorter than the outage makes retries pointless.**
`release(msg, delay_seconds=5)` with `maxReceiveCount = 5` allows ~25 seconds of total
retry, while requirement #5 demands surviving a 3-minute outage — so 1 in 5 orders landed
in the DLQ. Replaced with `min(60 × receive_count, 600)`, roughly 10 minutes.

## Known gaps

- **30-minute 5× load test (#4)** — needs a dedicated k6 EC2 generator; running it from a
  laptop over the internet measures the link, not the system.
- **With/without RDS Proxy comparison** — current numbers are *with* proxy only.
- **Outage test re-run after the backoff fix** — the fix is committed, the infrastructure
  has not been rebuilt to re-measure.
- **Requirement #1** is satisfied by design only — on-premise has not actually been cut off.

Infrastructure for all three is already in Terraform; what remains is running them.

---

## Run it

### Locally — three commands

```bash
bash scripts/up.sh          # build, start, seed 5,000 orders
bash scripts/test-all.sh    # run the test matrix, write evidence/
open http://localhost:8080  # order UI
```

Requires Docker and Docker Compose. Nothing is installed on the host.

```bash
WITH_ONPREM=1 bash scripts/up.sh      # also start the source system, for cutover rehearsal
FULL=1 bash scripts/test-all.sh       # outage test runs the full 180s
PROFILE=full bash scripts/loadtest.sh # k6: 50 → 250 req/s over 30 minutes
bash scripts/down.sh --volumes        # tear down and wipe data
```

The local topology mirrors AWS deliberately: `web` → CloudFront + S3, `app` → ASG behind
the ALB, `worker` → separate process on the same ASG, `db`/`db-replica` → RDS Multi-AZ +
read replica, and `queue-db` → SQS + DynamoDB. The queue **must** be a separate container
— on AWS, SQS and DynamoDB are independent of RDS, so co-locating them would make the
database-outage test meaningless.

Switching to the real AWS services is environment variables only, no code change:

```bash
QUEUE_DRIVER=sqs              SQS_QUEUE_URL=https://sqs.ap-southeast-1.../orders.fifo
ACCEPT_STORE_DRIVER=dynamodb  DDB_ACCEPT_TABLE=abc-order-accept
DB_HOST=abc-rds-proxy.proxy-xxxx.ap-southeast-1.rds.amazonaws.com
```

### On AWS

```bash
cd deploy/terraform
cp terraform.tfvars.example terraform.tfvars   # set expected_account_id, alarm_email, ...
terraform init
terraform plan
terraform apply
```

Terraform refuses to touch anything if the resolved profile is not
`expected_account_id`. Feature flags: `create_cloudfront`, `create_rds_proxy`,
`create_migration`, `create_dms_service_roles`, `allow_destroy`.
Full guide: [`deploy/terraform/README.md` (VI)](deploy/terraform/README.md)

---

## Layout

```
app/                  App tier, worker, SPA — Python 3.12 + FastAPI
db/                   PostgreSQL schema + data generator
deploy/local/         Docker Compose mirroring the AWS topology
deploy/terraform/     11 modules, each with its own README
docs/diagrams/        .drawio sources (official AWS Architecture Icons)
docs/ban-giao/        Technical docs, runbook, rollout plan, costs (Vietnamese)
scripts/              Per-requirement test scripts, load generation, file-share setup
loadtest/k6/          k6 load scenarios
```

| Module | Contents |
|---|---|
| `network` | VPC, 6 subnets, IGW, 1 NAT, 4 route tables, S3 gateway endpoint |
| `security` | 6 security groups, mutually referenced rules |
| `iam` | Instance role (SSM Session Manager, CloudWatch agent, S3 artifacts), proxy role |
| `data` | RDS Multi-AZ, parameter group, RDS Proxy, Secrets Manager, 5 SSM parameters |
| `queue` | SQS FIFO, DLQ, redrive policy, DynamoDB accept table |
| `compute` | ALB, target group, launch template, ASG, warm pool, 2 S3 buckets, log group |
| `static` | S3 assets bucket, SPA build upload with correct content types |
| `cdn` | CloudFront with 2 origins, OAC, cache policies, custom error responses |
| `fileserver` | EFS, mount targets, access points, file system policy, backup policy |
| `observability` | 8 alarms, SNS, metric filter, dashboard, 4 Logs Insights queries |
| `migration` | DMS replication instance + endpoints + task, DataSync locations + task |

Cross-cutting flows — order creation, database failure, instance loss, scale-out,
release, parallel reporting, tracing, module dependency order:
[`deploy/terraform/FLOW.md` (VI)](deploy/terraform/FLOW.md)

---

## Documentation

Deep documentation is in Vietnamese, under [`docs/ban-giao/`](docs/ban-giao/).

| Document | Contents |
|---|---|
| [tai-lieu-ky-thuat.md](docs/ban-giao/tai-lieu-ky-thuat.md) | Technical overview, written for a reader who does not know AWS — **start here** |
| [lua-chon-thiet-ke.md](docs/ban-giao/lua-chon-thiet-ke.md) | Service choices: what was picked, against what, why, and when to pick the opposite |
| [thong-so-ky-thuat.md](docs/ban-giao/thong-so-ky-thuat.md) | Full parameter reference for every service |
| [runbook.md](docs/ban-giao/runbook.md) | Operational runbook |
| [anh-xa-rang-buoc.md](docs/ban-giao/anh-xa-rang-buoc.md) | Requirement → mechanism → proof |
| [ke-hoach-trien-khai.md](docs/ban-giao/ke-hoach-trien-khai.md) | Rollout plan |
| [chi-phi.md](docs/ban-giao/chi-phi.md) | Cost model: customer quote and demo environment |
| [quy-trinh-release.md](docs/ban-giao/quy-trinh-release.md) | Release process |
| [huong-dan-console.md](docs/ban-giao/huong-dan-console.md) | Console walkthrough, in deployment order |
| [scripts/SAFETY.md](scripts/SAFETY.md) | Rules for permission-probing scripts, written after one destroyed live resources |
