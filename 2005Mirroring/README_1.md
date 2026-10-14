# SQL Server 2005 – Commvault SQL agent → native backups (Ola Hallengren)

Instance: SQL Server 2005 SP4, Windows 2008, database mirroring, ~10 user databases.
Schedule: weekly full (Sunday), daily diff (Mon–Sat), log every 15 minutes, to `X:\backup`.
Commvault moves to backing up `X:\backup` as files. Alerts go out through Database Mail.

## Order of work

Run every step on **both** mirroring partners unless it says otherwise.

| # | Step | Where |
|---|------|-------|
| 0 | Create `X:\backup` and give the SQL Server service account Modify rights on it | both |
| 1 | Edit and run `01_DatabaseMail_Operator_Alerts.sql`, then **restart SQL Agent** | both |
| 2 | Download `MaintenanceSolution.sql` from ola.hallengren.com/downloads-sql-server-2005.html, set `@BackupDirectory = N'X:\backup'`, `@CleanupTime = NULL` (02 sets retention per job), `@CreateJobs = 'Y'`, `@LogToTable = 'Y'`, and run it in `master` | both |
| 3 | Run `02_Configure_Backup_Jobs.sql` (schedules are created disabled) | both |
| 4 | Run `03_Backup_Health_Check.sql` | both |
| 5 | Test: make a throwaway job that runs `RAISERROR('test',16,1)` with email-on-failure to `DBA Team`, run it, and confirm the email arrives | both |
| 6 | Set up the Commvault file-system subclient for `X:\backup`, scheduled daily after 01:00 fulls/diffs (for example 03:00) | both servers |
| 7 | Disable the Commvault **SQL** subclient schedules | Commvault |
| 8 | Run `04_Cutover.sql` (set `@CommvaultSqlDisabled = 'Y'`) | principal, then mirror |
| 9 | Verify (queries are at the bottom of 04), do a test restore, rehearse a failover | — |
| 10 | Only then decommission the Commvault SQL agent | — |

## How mirroring is handled

- Mirror databases are in RESTORING state. Ola's `DatabaseBackup` only backs up ONLINE databases, so the same jobs on both partners back up whichever side is principal. Nothing has to change on failover.
- After a failover, new backups land in the *other* server's `X:\backup`. That's why Commvault has to protect `X:\backup` on **both** servers.
- The log chain carries on across a failover. A diff taken on the new principal is still based on the last full, which lives on the other server. The health check reports "No full backup on this server" after a failover. Run the FULL job on the new principal so each server holds a complete set.
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
- **Commvault cadence.** Diffs are kept for only 36 hours locally, so the Commvault file job must succeed at least that often. The health check won't see a Commvault failure, so make sure Commvault's own alerts reach you.
- **Restore gap.** Logs can only be restored on top of a full or diff you still hold. Locally you can always recover to any point since the older of the two diffs. Logs older than that are only usable locally while the weekly full is within 4 days old, which means Sunday to Wednesday. Later in the week, a point-in-time restore to around 3 days ago needs that day's diff back from Commvault first. Setting `@DiffCleanupHours = 96` in 02 closes the gap, at the cost of keeping 4 diffs.
- **Mirror side.** The jobs skip databases on the mirror, so they also skip its cleanup. Files a server wrote while it was principal stay on its `X:\backup` until it becomes principal again. Clear them manually after a failover if the space matters.

## Alerting

| What | How |
|------|-----|
| Backup job fails | Agent emails `DBA Team` on job failure (set in 02) |
| A single backup fails | Agent alert on error 3041 (set in 01) |
| A log fills up because log backups stopped | Agent alert on error 9002 (set in 01) |
| Backups silently stop (job disabled, Agent down, new database missed) | `DBA - Backup Health Check`, hourly (set in 03) |

## Not covered here, but worth doing

- **DBCC CHECKDB.** The `DatabaseIntegrityCheck - USER_DATABASES` job is created but has no schedule. Run it weekly, before the Sunday full.
- **Restore runbook.** A recent restore uses files straight from `X:\backup`. An older one means a Commvault file restore first, then `RESTORE ... WITH NORECOVERY` for full, diff and logs. Remember that 2005 backups can only be restored on SQL Server 2016 or earlier.
- **Logins and jobs.** System database fulls cover master and msdb, but keep a scripted copy of logins (`sp_help_revlogin`) on both partners as well.
