# ELK / CDR ingestion pipeline — configuration

This directory **is** the live installation and the repository at the same time. Git
tracks only the hand-written configuration; the 3.7 GB of downloaded Elastic
distributions, the indexed data, the CDR exports and the runtime logs are excluded by
`.gitignore`. Edit the files in place, commit, and the team pulls the result — there is
no second copy to keep in sync.

These files had already been lost once before this was set up.

Reporting reads from Elasticsearch, not the database (`USE_ELASTICSEARCH_REPORTS = true`),
so this pipeline is production-critical: if it stops, every Insights figure stops
updating, silently and without an error on screen.

## Data flow

```
Web2SMS EARs                 Filebeat                Logstash              Elasticsearch
  ELKCDRTask          →   filebeat-cdrs.yml   →   logstash-cdrs.conf   →   web2sms-sms-*
  ELKCDRTaskCampaigns     (filestream tail)       (:5045 beats in)         web2sms-campaigns-*
        │
        └─ writes CSV CDRs to /opt/jboss-eap-8.1.9/runtime/app/web2sms-core/cdrs/{elk_cdr,elk_camp_cdr}/
```

**Since 2026-11-05 the source is the JBoss EAP 8.1 runtime on this host** (Web2SMS-Core, tasks run by
`scheduler.ear`); Filebeat reads its export directories in place (inputs `sms-csv-input-eap81`,
`campaigns-csv-input-eap81`). Before that, the WebLogic export was copied every minute by cron
(`docker cp vss2-dev:…/cdrs/elk_cdr|elk_camp_cdr` → `/work/ELK/elk_cdr/{sms,campaigns}/`, inputs `…-v2`);
that directory and the registry state of the old inputs are kept untouched.

## What is tracked

| Path (relative to `/work/ELK`) | What it is |
|---|---|
| `logstash-9.3.0/config/logstash-cdrs.conf` | the pipeline — parsing, enrichment, routing |
| `filebeat-9.3.0-linux-x86_64/filebeat-cdrs.yml` | the shipper — which CDR directories are tailed |
| `index-templates/*.json` | exported Elasticsearch mappings (the live copy lives inside ES) |
| `systemd/*.service` | copies of the units; the live ones are in `/etc/systemd/system/` |
| `start-elk.sh` | ordered startup with a readiness gate |

Everything else in this tree is ignored. To track a new file, add an un-ignore rule to
`.gitignore` — see the comment at the top of that file for why each level needs one.

The `systemd/` copies are exactly that: **copies**. systemd reads from
`/etc/systemd/system/`, so a change here does nothing until it is copied back and
`systemctl daemon-reload` is run.

## Credentials

**No credentials are committed.** Two files held the Elasticsearch password in plaintext
and were parameterised before the first commit:

- `logstash-9.3.0/config/logstash-cdrs.conf` — now uses `${ES_USER}` / `${ES_PASSWORD}`
- `start-elk.sh` — now sources an untracked env file

This matters because this repository is shared with the team. A secret committed once
stays in the history even after it is deleted, and the only real remedy is rewriting the
history and rotating the password.

### Logstash

Logstash resolves `${...}` from its keystore or the process environment. Use the
keystore — it is per-machine and is never committed (`.gitignore` blocks
`**/logstash.keystore`):

```bash
cd /work/ELK/logstash-9.3.0
bin/logstash-keystore create
bin/logstash-keystore add ES_USER        # enter: elastic
bin/logstash-keystore add ES_PASSWORD    # enter the real password
```

Created this way the keystore needs no passphrase, so the service unit needs no
change. It is protected by file permissions alone; to encrypt it instead, set
`LOGSTASH_KEYSTORE_PASS` before `create` and make the same value visible to the
service with `EnvironmentFile=/work/ELK/.elk-env` in
`systemd/logstash-cdrs.service`. If that variable is ever set at `create` time and
then missing at start time, Logstash fails to boot.

### start-elk.sh and any manual curl

Create `/work/ELK/.elk-env`, `chmod 600`, **never commit it**:

```bash
export ES_USER=elastic
export ES_PASSWORD='...'
```

## Index templates

`index-templates/` holds the mappings for both indices, exported from the live cluster
on 2026-09-17. Restore into a rebuilt cluster with:

```
PUT _index_template/web2sms-sms        # body = index-templates/web2sms-sms.json
PUT _index_template/web2sms-campaigns  # body = index-templates/web2sms-campaigns.json
```

Re-export after any mapping change:

```
GET _index_template/web2sms*
```

Keep the body only — drop the read-only `created_date_millis` / `modified_date_millis`
fields, which Elasticsearch rejects on `PUT`.

### Why these files matter

Every identifier query in `ElasticsearchReportService` uses the `.keyword` sub-field
(`campaignId.keyword`, `camp_id.keyword`, `accountId.keyword`, `status.keyword`, …).
A mapping that omits those sub-fields does not raise an error — the query simply
matches **nothing**, and the report renders as an empty chart or a zero total. This
has already happened once in this project.

Both templates now declare `"type": "keyword"` **with** a nested `fields.keyword`
sub-field for every field the reporting code filters on, so queries written either way
resolve. Fields not used as filters (`language`, `tagIds`, `whiteLists`, `frequency`,
`tier`, `campaignAgency`, `campaignClient`) are plain `keyword` with no sub-field — if
reporting ever starts filtering on one of them by `.keyword`, the template must be
updated first.

**An index template only applies to indices created after it is saved.** Changing a
template never repairs existing indices. Indices created while an older template was in
force keep their original mapping until they are reindexed.

## Making a change

The files are edited where they run, so there is nothing to copy:

```bash
cd /work/ELK
vim logstash-9.3.0/config/logstash-cdrs.conf
sudo systemctl restart logstash-cdrs        # or filebeat-cdrs
git add -A && git commit -m "fix(logstash): ..."
git push                                    # if a remote is configured
```

A restart is not proof that a change took effect. Logstash starts cleanly even when its
output is misconfigured and then fails silently per event, so confirm that the document
count in Elasticsearch actually moves after the next CDR export.

Two exceptions to "edit in place":

- **systemd units** — edit `systemd/*.service` here, then
  `sudo cp systemd/*.service /etc/systemd/system/ && sudo systemctl daemon-reload`.
- **Index templates** — `index-templates/*.json` are exports. Changing a file here does
  nothing until it is `PUT` back into Elasticsearch, and even then it only affects
  indices created afterwards.

Services are systemd-managed. Do **not** launch Filebeat with `nohup ./filebeat`, and
do **not** delete its lockfile — both corrupt the registry at
`/work/ELK/.filebeat-cdrs-registry` and cause the whole CDR history to be re-ingested.

## Two behaviours that look like bugs but are not

**1. `version_type => external_gte` on the campaigns output.** Filebeat re-reads every
CDR file every few minutes. Campaign CDRs are snapshots, so without a version guard a
stale file could roll a campaign's status backwards from `FINISHED` to `RUNNING`. The
ordering token is derived from the export filename (`..._YYYYMMDD_HH-MM.csv`) because
`processingDate` is the campaign's creation time and cannot order status changes.
`version_conflict_engine_exception` is therefore expected and is silenced.

**2. Fingerprinting disabled in `filebeat-cdrs.yml`.** Campaign CDRs are frequently
byte-identical, which made content fingerprinting collapse hundreds of distinct files
into one. Filenames are unique and minute-stamped, so `file_identity.path` is correct
here.
