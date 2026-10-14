/*
================================================================================
 04_Cutover.sql
 SQL Server 2005 SP4 - run on the PRINCIPAL first, then on the MIRROR.

 BEFORE RUNNING - all of these must be true:
   [ ] 01, 02, 03 run on BOTH partners; SQL Agent restarted on both.
   [ ] Test email received; a deliberately failed test job emailed you.
   [ ] Commvault SQL Server subclient schedules are DISABLED (or the job
       is set to copy-only). Two tools taking non-copy-only fulls breaks
       each other's differential base.
   [ ] Commvault FILE SYSTEM subclient for X:\backup exists on BOTH partners,
       scheduled daily AFTER the 01:00 full/diff finishes (e.g. 03:00),
       and you know its retention.
   [ ] X:\backup has room for: all fulls + the LARGEST single full (old one
       is deleted per database after the new one verifies) + the two
       biggest diffs (Fri + Sat, diffs grow all week) + 4 days of logs.
       No compression on 2005 - a full is roughly the data used.
   [ ] Commvault file job on X:\backup runs at least every 36 hours
       (diffs are only kept 36h locally).
   [ ] SQL Server service account on both partners has Modify on X:\backup.

 Then set @CommvaultSqlDisabled = 'Y' below and run.

 What it does
   1. Starts the USER and SYSTEM full backup jobs now, so a native full
      exists immediately (until it completes, a restore of this window needs
      the last Commvault full + native logs - the log chain itself carries on
      unbroken across the switch).
   2. Enables every schedule on the DatabaseBackup, housekeeping and
      health-check jobs.
================================================================================
*/
SET NOCOUNT ON;

DECLARE @CommvaultSqlDisabled char(1),
        @StartFullsNow        char(1),
        @ScheduleId           int,
        @Name                 nvarchar(300);

/* ----------------------------- CONFIG ---------------------------------- */
SET @CommvaultSqlDisabled = 'N';   -- <<< set to 'Y' once Commvault SQL schedules are off
SET @StartFullsNow        = 'Y';   -- 'Y' on the principal; harmless on the mirror (nothing ONLINE to back up)
/* ----------------------------------------------------------------------- */

IF @CommvaultSqlDisabled <> 'Y'
BEGIN
    RAISERROR('Stopped: disable the Commvault SQL subclient schedules first, then set @CommvaultSqlDisabled = ''Y''.', 16, 1);
    RETURN;
END

/* 1. Take native fulls now */
IF @StartFullsNow = 'Y'
BEGIN
    EXEC msdb.dbo.sp_start_job @job_name = N'DatabaseBackup - USER_DATABASES - FULL';
    EXEC msdb.dbo.sp_start_job @job_name = N'DatabaseBackup - SYSTEM_DATABASES - FULL';
    PRINT 'Full backup jobs started. Watch them in Job Activity Monitor.';
END

/* 2. Enable schedules */
DECLARE sch_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT s.schedule_id, j.name + N' / ' + s.name
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobschedules js ON js.job_id = j.job_id
    JOIN msdb.dbo.sysschedules s     ON s.schedule_id = js.schedule_id
    WHERE (j.name LIKE N'DatabaseBackup - %'
        OR j.name IN (N'CommandLog Cleanup', N'Output File Cleanup', N'sp_delete_backuphistory',
                      N'sp_purge_jobhistory', N'DBA - Backup Health Check'))
      AND s.enabled = 0;
OPEN sch_cur;
FETCH NEXT FROM sch_cur INTO @ScheduleId, @Name;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC msdb.dbo.sp_update_schedule @schedule_id = @ScheduleId, @enabled = 1;
    PRINT 'Enabled: ' + @Name;
    FETCH NEXT FROM sch_cur INTO @ScheduleId, @Name;
END
CLOSE sch_cur; DEALLOCATE sch_cur;

/* Make sure the jobs themselves are enabled too (via the API, not a direct
   UPDATE, so Agent's job cache is refreshed) */
DECLARE job_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM msdb.dbo.sysjobs
    WHERE enabled = 0
      AND (name LIKE N'DatabaseBackup - %' OR name = N'DBA - Backup Health Check');
OPEN job_cur;
FETCH NEXT FROM job_cur INTO @Name;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC msdb.dbo.sp_update_job @job_name = @Name, @enabled = 1;
    PRINT 'Enabled job: ' + @Name;
    FETCH NEXT FROM job_cur INTO @Name;
END
CLOSE job_cur; DEALLOCATE job_cur;

PRINT 'Cutover complete on ' + @@SERVERNAME + '.';

/*
 AFTER CUTOVER (verification)
   -- Native backups landing, per database:
   SELECT database_name, type, MAX(backup_finish_date) AS last_finish
   FROM msdb.dbo.backupset
   WHERE backup_finish_date > DATEADD(dd, -1, GETDATE())
   GROUP BY database_name, type ORDER BY database_name, type;

   -- Any Ola errors:
   SELECT TOP 50 * FROM master.dbo.CommandLog WHERE ErrorNumber <> 0 ORDER BY ID DESC;

   -- Health check, no email:
   EXEC master.dbo.usp_CheckBackupHealth @SendEmail = 0;

 Then, before decommissioning the Commvault SQL agent:
   1. Restore a full + diff + logs to a point in time on a test server.
   2. Restore the same, but from files Commvault brought back from tape/disk
      (proves the file-level path end to end).
   3. Do one mirroring failover in a maintenance window, run the FULL job on
      the new principal, confirm the health check goes quiet, fail back.
*/
