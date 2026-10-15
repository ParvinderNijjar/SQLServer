# SQL Server 2005 – Commvault SQL agent → native backups (Ola Hallengren)

Instance: SQL Server 2005 SP4, Windows 2008, database mirroring, ~10 user databases.
Schedule: weekly full (Sunday), daily diff (Mon–Sat), log every 15 minutes, to `X:\backup`.
Commvault moves to backing up `X:\backup` as files. Alerts go out through Database Mail.

## Order of work

Run every step on **both** mirroring partners unless it says otherwise.

| # | Step | Where |
|---|------|-------|
| 0 | Create `X:\backup` on a volume with no database files, and give the SQL Server service account Modify rights on it | both |
| 1 | Edit and run `01_DatabaseMail_Operator_Alerts.sql`, then **restart SQL Agent**. The script stops if msdb Service Broker is off, because mail would queue and never send | both |
| 2 | Download `MaintenanceSolution.sql` from ola.hallengren.com/downloads-sql-server-2005.html, set `@BackupDirectory = N'X:\backup'`, `@CleanupTime = NULL` (02 sets retention per job), `@CreateJobs = 'Y'`, `@LogToTable = 'Y'`, and run it in `master` | both |
| 3 | Run `02_Configure_Backup_Jobs.sql` (schedules are created disabled) | both |
| 4 | Run `03_Backup_Health_Check.sql` | both |
| 5 | Test: make a throwaway job that runs `RAISERROR('test',16,1)` with email-on-failure to `DBA Team`, run it, and confirm the email arrives | both |
| 6 | Set up the Commvault file-system subclient for `X:\backup`. See "Commvault side" below | both servers |
| 7 | Disable **all** Commvault SQL subclient schedules, including any automatic (log-space-triggered) log schedule | Commvault |
| 8 | Run `04_Cutover.sql` (set `@CommvaultSqlDisabled = 'Y'`). It starts the first native fulls | principal, then mirror |
| 9 | When the fulls finish, run `05_Enable_Health_Check.sql`. It only enables the hourly check once the check comes back clean | both |
| 10 | Verify (queries at the bottom of 04), do a test restore, rehearse a failover **and** a failback | — |
| 11 | Only then decommission the Commvault SQL agent | — |

## Commvault side

These settings decide whether the design works, and SQL Server can't check them for you.

- **Deleted-item retention is now your backup retention.** Every file in `X:\backup` is deleted from disk within 1–7 days. How long Commvault keeps a file after it disappears from the source therefore *is* how long you can restore from. Set it to match what the SQL agent gave you before the SQL agent goes.
- **Frequency.** The job must run at least every 36 hours, because diffs are only kept that long locally, and after the 01:00 full/diff (for example 03:00). A file caught half-written is picked up complete on the next run.
- **Content.** The subclient should cover `X:\backup` only, and `.mdf`/`.ldf`/`.ndf` files should be excluded from any other file-system subclient on these servers.
- **VSS.** If a Commvault VSS snapshot includes a volume with database files, the SQL Server VSS writer can record a snapshot "full" in msdb. That moves the differential base, Ola then promotes every diff to a full, and `X:\backup` fills up. The health check reports this as "Non-native backup (VSS snapshot)".
- **Alerts.** The health check can't see a failed Commvault job. Make sure Commvault's own failure alerts reach you.

## How mirroring is handled

- Mirror databases are in RESTORING state. Ola's `DatabaseBackup` only backs up ONLINE databases, so the same jobs on both partners back up whichever side is principal. Nothing has to change on failover.
- After a failover, new backups land in the *other* server's `X:\backup`. That's why Commvault has to protect `X:\backup` on **both** servers.
- The log chain carries on across a failover. A diff taken on the new principal is still based on the last full, which lives on the *other* server's disk. **After every role change, failover or failback, run `DatabaseBackup - USER_DATABASES - FULL` on the new principal.** Failback needs it too, because the old principal's local full is no longer the diff base.
- The health check's "Diff base" check spots this. It compares the database's actual differential base, from `sys.master_files`, with the full on this server's disk, so you'll get an email within the hour if the FULL job isn't run after a role change.
- Log backups only run on the principal. That's correct: the mirror's log can't be backed up.

## Retention and disk

Local retention on `X:\backup`. Everything older lives in Commvault.

| Backup | Kept locally | Ola `@CleanupTime` |
|--------|--------------|--------------------|
| User full (weekly) | 1 | 24 h |
| User diff (daily) | latest 2 | 36 h |
| User log (15 min) | 4 days | 96 h |
| System full (daily) | 1 | 12 h |

- **Safe on failure.** Ola only deletes old files after the new backup of that database has succeeded and passed `RESTORE VERIFYONLY`, and each job only deletes its own backup type. A failed Sunday full leaves last week's full in place.
- **Disk.** The old full is removed per database right after its replacement verifies. Peak space is therefore all fulls, plus one extra copy of the largest full, plus the two biggest diffs, plus 4 days of logs. Diffs are cumulative, so Friday's and Saturday's are the largest. There's no backup compression on 2005.
- **What local disk alone can restore.** A restore needs a full plus diffs or logs taken *after* that full. With only one full kept, no point before the current Sunday full can be restored from `X:\backup`, whatever the diff or log retention is.
  - Sunday 01:00 to Thursday 01:00: you can go back to the Sunday full, so the window grows from a few hours to about 4 days.
  - Thursday 01:00 to Sunday 01:00: you can go back to the older of the two kept diffs, about 1–2 days.
  - Anything older means a Commvault file restore first. Plan the restore runbook and RTO around that. On Sunday morning, "restore to last night" is already a Commvault restore.
  - Logs between about 2 and 4 days old can only be used locally from Sunday to Wednesday. From Sunday until Monday's diff job deletes them, the Friday and Saturday diffs are orphaned, because the full they depend on has gone.
- **Mirror side.** The jobs skip databases on the mirror, so they also skip its cleanup. Files a server wrote while it was principal stay on its `X:\backup` until it becomes principal again. Clear them manually after a failover if the space matters.

## Alerting

| What | How |
|------|-----|
| Backup job fails | Agent emails `DBA Team` on job failure (set in 02) |
| A single backup fails | Agent alert on error 3041 (set in 01) |
| A log fills up because log backups stopped | Agent alert on error 9002 (set in 01) |
| Backups silently stop (job disabled, Agent down, new database missed), including system databases | `DBA - Backup Health Check`, hourly (03): Full / Diff / Log / System full |
| The single full the diffs depend on isn't a native full on this server, or has gone from disk (failover or failback, ad-hoc full, Commvault or VSS full) | Health check: Diff base |
| A backup was taken outside `X:\backup` without COPY_ONLY (Commvault still running, ad-hoc, `TO DISK='NUL'`, VSS) | Health check: Non-native backup |

Problems that persist are re-emailed every hour until they're fixed. Each non-native backup is reported once.

## Not covered here, but worth doing

- **DBCC CHECKDB.** The `DatabaseIntegrityCheck - USER_DATABASES` job is created but has no schedule. Run it weekly, before the Sunday full.
- **Restore runbook.** A recent restore uses files straight from `X:\backup`. An older one means a Commvault file restore first, then `RESTORE ... WITH NORECOVERY` for full, diff and logs. Remember that 2005 backups can only be restored on SQL Server 2016 or earlier.
- **Logins and jobs.** System database fulls cover master and msdb, but keep a scripted copy of logins (`sp_help_revlogin`) on both partners as well.
