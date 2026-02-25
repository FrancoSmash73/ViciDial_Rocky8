# EMPIRE IVR — Session Notes
**Last updated:** 2026-02-25 (evening)
**Status: FULLY WORKING ✅**

---

## Standalone Server (172.236.243.149)

**Purpose:** Outbound dialing only (eventually a simpler IVR — not EMPIRE)
**OS:** Rocky Linux 10.1 (Red Quartz)
**SSH:** `ssh -p 1951 root@172.236.243.149`
**DB user:** `cron` / `O8wF0zxfPtWLipZ1zwj33fo2`
**DB root:** `TQE2lafarwZBk8oF2MEao3mx`

### Verified 2026-02-25
| Check | Status |
|---|---|
| `DBI:mysql` in `agi-VDAD_ALL_inbound.agi` | ✅ 0 — already patched |
| Asterisk | ✅ 18.21.0-vici running |
| Web server (httpd) | ✅ Active |
| Systemd keepalive timer | ✅ Active (every 60s) |
| Crontab | ✅ Full ViciDial crontab in place |
| `ASTVDauto` | ✅ Running (was missing — started via `ADMIN_keepalive_ALL.pl`) |
| `ASTVDadapt` | ✅ Running (was missing — started via `ADMIN_keepalive_ALL.pl`) |
| `ASTVDremote` | ✅ Running |
| `ASTemail` | ✅ Running |

### Active Campaigns
| Campaign | Type |
|---|---|
| `TEST1` | MANUAL |
| `CALI` | RATIO |

### Notes
- EMPIRE IVR **not** deployed here — standalone is outbound only
- A simpler IVR will be added in a future session
- Server 1 SSH key added to standalone `~/.ssh/authorized_keys` (keyless access working)

---

## Architecture

### Cluster (EMPIRE IVR)
| Server | IP | Role |
|---|---|---|
| Server 1 | 172.239.67.94 | DB + Web (MariaDB `asterisk` db) |
| Server 2 | 172.235.34.224 | Asterisk + AGI scripts |

**SSH to Server 2:** `ssh -p 1951 root@172.235.34.224`
**DB user:** `cron` / `6KS8iNvRdIJV9jRVcgtgt6SC`
**DB from Server 1:** connect to `127.0.0.1`
**DB from Server 2:** connect to `172.239.67.94`

### Standalone Server
| Server | IP | Role |
|---|---|---|
| Standalone | 172.236.243.149 | DB + Web + Asterisk (all-in-one) |

**SSH:** `ssh -p 1951 root@172.236.243.149`
**OS:** Rocky Linux 10.1 (Red Quartz)
**DBI:MariaDB patch:** ✅ Already applied (`DBI:mysql` count = 0) — verified 2026-02-25
**Server 1 SSH key:** ✅ Added to standalone `~/.ssh/authorized_keys`

---

## Full IVR Flow (All Working ✅)

1. **DID routing** — DID `16088091363` hits `[trunkinbound]` literal extension → jumps to `empire-ivr-main` context
2. **Language select** — working
3. **Case number entry** — 3 attempts, confirmed → lookup via `empire_lookup_vicidial.agi`
4. **SSN verification** — last 2 digits via `empire_verify_ssn_vicidial.agi`
5. **Transfer to agent** — `agi-VDAD_ALL_inbound.agi` routes call to EMPIRE inbound group with screen pop
6. **Agent receives call** — status must be `READY` or `CLOSER` with `lead_id=0`

**Test record (confirmed working):**
- Case number: `18193698` → ANITA MENA, lead_id 65414
- SSN last 2: `61`
- DID: `16088091363`

---

## What Was Fixed (Root Cause History)

### 1. Column mapping (earlier session)
CSV columns were misaligned in the EMPIRE_SPECIAL template. Fixed in `/root/empire_fix_template.sql`.

### 2. AGI script version + line endings (earlier session)
Old `empire_lookup_vicidial.agi` on Server 2 queried non-existent `ssn_last_two` column.
Fixed: SCP updated scripts from Server 1, then `sed -i 's/\r//'` to strip Windows line endings.

### 3. DID route (earlier session)
`vicidial_inbound_dids` had `did_route=EXTEN` — updated to `did_route=IN_GROUP, group_id=EMPIRE`.

### 4. DBD::mysql missing — ROOT CAUSE of transfer failure (2026-02-25)
`agi-VDAD_ALL_inbound.agi` used `DBI:mysql` throughout. Rocky Linux 10 only has `DBD::MariaDB`
(no `DBD::mysql`). Script crashed silently on DB connect before any logging.

**Fix applied:** Global sed replacement in `agi-VDAD_ALL_inbound.agi`:
```bash
# Backup first
cp /var/lib/asterisk/agi-bin/agi-VDAD_ALL_inbound.agi \
   /var/lib/asterisk/agi-bin/agi-VDAD_ALL_inbound.agi.bak

# Patch
sed -i 's/DBI:mysql/DBI:MariaDB/g' /var/lib/asterisk/agi-bin/agi-VDAD_ALL_inbound.agi
```
Result: 0 `DBI:mysql` remaining, 19 `DBI:MariaDB` in place. Call routed flawlessly.

**Rollback if ever needed:**
```bash
cp /var/lib/asterisk/agi-bin/agi-VDAD_ALL_inbound.agi.bak \
   /var/lib/asterisk/agi-bin/agi-VDAD_ALL_inbound.agi
```

---

## Agent Requirements for Inbound Routing

Agent must be logged in with:
- `status IN ('READY', 'CLOSER')`
- `campaign_id = INBOUND`
- `closer_campaigns` contains `EMPIRE`
- `lead_id = 0` (not on a call)

**Verify before testing:**
```sql
SELECT user, status, campaign_id, closer_campaigns, lead_id
FROM vicidial_live_agents;
```

Agent starts as PAUSED after login — must click **Resume/Go Ready** in the agent interface.

---

## DB State (Production)

```sql
-- EMPIRE inbound group
no_agent_no_queue = N   (queue calls, don't drop)
no_agent_action   = MESSAGE
no_agent_action_value = vm-nobodyavail|vm-goodbye
active = Y

-- DID routing (both DID records)
did_route  = IN_GROUP
group_id   = EMPIRE

-- INBOUND campaign
closer_campaigns = ' EMPIRE -'
```

---

## Key File Locations

### Server 1 (DB/Web)
| File | Purpose |
|---|---|
| `/root/empire_fix_template.sql` | SQL that fixed column mapping + created custom_2000 |
| `/root/empire_inbound_group.sql` | EMPIRE inbound group SQL |
| `/root/empire_lookup_vicidial.agi` | Lookup AGI (source of truth) |
| `/root/empire_verify_ssn_vicidial.agi` | Verify AGI (source of truth) |
| `/root/List_Sample.csv` | Sample CSV showing real column order |
| `/root/EMPIRE_upload_template.csv` | Header-only template file |

### Server 2 (Asterisk)
| File | Purpose |
|---|---|
| `/etc/asterisk/extensions-empire-ivr.conf` | Full IVR dialplan |
| `/etc/asterisk/extensions.conf` | Has `#include extensions-empire-ivr.conf` at end |
| `/var/lib/asterisk/agi-bin/empire_lookup_vicidial.agi` | Deployed lookup AGI |
| `/var/lib/asterisk/agi-bin/empire_verify_ssn_vicidial.agi` | Deployed verify AGI |
| `/var/lib/asterisk/agi-bin/agi-VDAD_ALL_inbound.agi` | **Patched** — DBI:MariaDB (backup: .agi.bak) |
| `/etc/astguiclient.conf` | ViciDial config (DB creds, server IP) |
| `/root/generate_empire_names.py` | TTS name generation script (PyMySQL, 10 workers) |
| `/var/lib/asterisk/sounds/custom/*.wav` | 5276 generated name audio files |
| `/root/empire_tts_generation.log` | TTS generation log |

---

## Installer Updates (2026-02-25)

Changes pushed to `github.com/FrancoSmash73/vicidial-rocky10` — commit `3fc1f89`:

### Part 2 → v11.2
- Added **final safety-net DBI patch block** at the very end of the installer
- Re-applies `DBI:mysql → DBI:MariaDB` to all `.agi` and `.pl` files after all 23 steps complete
- Explicitly verifies `agi-VDAD_ALL_inbound.agi`, `agi-VDAD_ALL_outbound.agi`, `agi-VDAD_local_optimize.agi` by name
- Throws a hard `error` if any critical file still contains `DBI:mysql` after patching
- **Why:** Step 7.5 patches correctly during install, but if `install.pl` is ever re-run manually it redeploys fresh unpatched AGI files — silently breaking all inbound routing

### Part 1 → v1.3
- Fixed header/code version mismatch (header said v1.1, `VERSION` variable was v1.2)
- Restored correct v1.1 changelog label (had been duplicated as v1.2)
- No code changes — DBI patch is a Server 2 concern only

### All files
- Replaced `Striker24x7` author references with `FrancoSmash73` throughout

---

## TTS Audio Name Files (2026-02-25)

**Status: ✅ COMPLETE — 5276/5276 files generated**

### Generation Details
- **Script:** `/root/generate_empire_names.py` on Server 2
- **Method:** Google Translate TTS → MP3 → sox → 8kHz mono PCM WAV
- **Output dir:** `/var/lib/asterisk/sounds/custom/`
- **File naming:** `{lead_id}.wav` (e.g. `65414.wav` for ANITA MENA)
- **Total size:** 146 MB
- **Lead ID range:** 65409–70684
- **Rate:** ~1395 files/min (10 parallel workers)
- **Failed:** 0 | **Skipped:** 0

### How IVR Uses These Files
Dialplan in `/etc/asterisk/extensions-empire-ivr.conf`:
```
same => n,ExecIf($[${STAT(e,/var/lib/asterisk/sounds/custom/${CUSTOMER_ID}.wav)}]?Background(custom/${CUSTOMER_ID}))
```
`CUSTOMER_ID` is set to `lead_id` by `empire_lookup_vicidial.agi` after case number lookup.

### Re-running / Adding New Leads
Script is resume-safe (skips existing files). To generate for new leads only:
```bash
screen -S EMPIREtts
python3 /root/generate_empire_names.py
```
Log: `/root/empire_tts_generation.log`

---

## CSV Column Mapping (for future re-uploads)
Template: `EMPIRE_SPECIAL` → List 2000 → custom_2000

| CSV Col | Field | Stored In |
|---|---|---|
| 0 | internal_case_id | custom_2000 |
| 1 | case_number | vicidial_list.vendor_lead_code + custom_2000 |
| 7 | debtor_first_name | vicidial_list.first_name |
| 8 | debtor_last_name | vicidial_list.last_name |
| 9 | SSN (last 2 digits only) | custom_2000.SSN |
| 12 | phone_1 | vicidial_list.phone_number |
| 13–36 | phone_2–phone_25 | custom_2000.phone_2–phone_25 |
