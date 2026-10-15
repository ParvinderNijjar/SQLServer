/*
================================================================================
 02_Configure_Backup_Jobs.sql
 SQL Server 2005 SP4 - run on BOTH mirroring partners.

 PREREQUISITE
   Install Ola Hallengren's SQL Server 2005 build first:
     https://ola.hallengren.com/downloads-sql-server-2005.html -> MaintenanceSolution.sql
   (the last release that supports 2005, version dated 2020-01-03).
   Before running it, edit its settings block to:
     SET @CreateJobs          = 'Y'
     SET @BackupDirectory     = N'X:\backup'
     SET @CleanupTime         = NULL      (this script sets retention per job)
     SET @OutputFileDirectory = NULL
     SET @LogToTable          = 'Y'
   It installs into the database you run it in (master by default) and creates
   the jobs WITHOUT schedules. This script then:

 What it does
   1. Sanity checks (Ola installed, jobs exist, X:\backup exists).
   2. Rewrites the four backup job steps with the exact parameters below
      (adds @ChangeBackupType = 'Y' to DIFF and LOG, see notes).
   3. Adds schedules - created DISABLED so nothing runs until cutover
      (04_Cutover.sql enables them).
   4. Emails the DBA operator on failure of every Ola job.
   5. Schedules the Ola housekeeping jobs (history/log cleanup).

 Schedule (edit in CONFIG):
   USER FULL    Sunday              01:00
   USER DIFF    Monday - Saturday   01:00
   USER LOG     every 15 minutes    all day
   SYSTEM FULL  daily               00:30
   Housekeeping Sunday              05:00 - 05:30

 Notes
   * Mirroring: databases in the MIRROR role are in RESTORING state, and
     DatabaseBackup only backs up ONLINE databases, so the same jobs running
     on both partners back up whichever side is principal. No job changes
     needed on failover.
   * @ChangeBackupType = 'Y': a DIFF with no full base is promoted to FULL,
     a LOG with no log chain is promoted to DIFF/FULL. Without it a newly
     created / restored database gets no protection until Sunday.
   * Local retention (Commvault holds everything older):
       USER FULL   @CleanupTime = 24  -> one full per database
       USER DIFF   @CleanupTime = 36  -> the two most recent daily diffs
       USER LOG    @CleanupTime = 96  -> 4 days of log backups
       SYSTEM FULL @CleanupTime = 12  -> one full of master/model/msdb
     How Ola applies it (verified against the 2005 source):
       - Each job only deletes files of its OWN type (FULL job -> FULL
         folder, etc.), per database, AFTER that database's backup has
         succeeded AND passed RESTORE VERIFYONLY. A failed or unverified
         full never deletes the previous full.
       - The old full is deleted straight after the new one verifies, one
         database at a time, so the extra disk needed on Sunday is one
         database's full, not all of them.
       - The diff and full values only need to sit between backup intervals
         (36h is between 24h and 48h), so timing jitter can't make them
         keep one file too many or too few.
       - Cleanup only runs when the job runs. On the MIRROR side databases
         are skipped, so files left there from before a failover stay
         until that server is principal again and its jobs run.
     Commvault must copy X:\backup at least once every 36 hours, or a diff
     can be deleted before it is protected.
   * What X:\backup alone can restore (point in time):
       A point can only be restored from a full + a diff/log chain that
       starts AFTER that full. With one full kept, nothing before the
       current Sunday full is restorable locally, whatever the diff or
       log retention. The local window is therefore:
         Sun 01:00 -> Thu 01:00   back to the Sunday full (0 h -> ~4 days)
         Thu 01:00 -> Sun 01:00   back to the older kept diff (~1-2 days)
       On Sunday morning it is only a few hours. Anything older needs
       files back from Commvault first. Fri/Sat diffs are orphaned (their
       full is gone) from Sunday until Monday's diff job deletes them.
       Logs between ~2 and 4 days old are only usable locally Sun-Wed.
================================================================================
*/
SET NOCOUNT ON;

DECLARE @OlaDatabase     sysname,
        @Directory       nvarchar(256),
        @FullCleanupHours int,
        @DiffCleanupHours int,
        @LogCleanupHours  int,
        @SysCleanupHours  int,
        @OperatorName    sysname,
        @FullDayMask     int,          -- sp_add_jobschedule weekly bitmask: Sun=1 Mon=2 Tue=4 Wed=8 Thu=16 Fri=32 Sat=64
        @DiffDayMask     int,
        @FullStartTime   int,          -- HHMMSS
        @DiffStartTime   int,
        @SysFullTime     int,
        @LogEveryMinutes int,
        @Token           nvarchar(50),
        @Cmd             nvarchar(4000),
        @Job             sysname,
        @Err             nvarchar(400);

/* ----------------------------- CONFIG ---------------------------------- */
SET @OlaDatabase     = N'master';
SET @Directory       = N'X:\backup';
SET @FullCleanupHours = 24;   -- weekly full: keeps one   (any value 1-167)
SET @DiffCleanupHours = 36;   -- daily diff:  keeps two   (between 24 and 48)
SET @LogCleanupHours  = 96;   -- 4 days of logs
SET @SysCleanupHours  = 12;   -- daily system full: keeps one (any value 1-23)
SET @OperatorName    = N'DBA Team';
SET @FullDayMask     = 1;      -- Sunday
SET @DiffDayMask     = 126;    -- Mon..Sat (2+4+8+16+32+64)
SET @FullStartTime   = 10000;  -- 01:00:00
SET @DiffStartTime   = 10000;  -- 01:00:00
SET @SysFullTime     = 3000;   -- 00:30:00
SET @LogEveryMinutes = 15;
/* ----------------------------------------------------------------------- */

/* Agent token, split so SSMS in SQLCMD mode doesn't treat it as a variable */
SET @Token = N'$' + N'(ESCAPE_SQUOTE(SRVR))';

/* ---------- 1. Sanity checks ---------- */
IF CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50)) NOT LIKE N'9.%'
    PRINT 'WARNING: this script was written for SQL Server 2005 (9.x).';

IF OBJECT_ID(QUOTENAME(@OlaDatabase) + N'.dbo.DatabaseBackup') IS NULL
BEGIN
    SET @Err = N'dbo.DatabaseBackup not found in ' + @OlaDatabase + N'. Install Ola''s 2005 MaintenanceSolution.sql first.';
    RAISERROR(@Err, 16, 1);
    RETURN;
END

IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobs WHERE name = N'DatabaseBackup - USER_DATABASES - FULL')
BEGIN
    RAISERROR('Ola backup jobs not found. Re-run MaintenanceSolution.sql with @CreateJobs = ''Y''.', 16, 1);
    RETURN;
END

IF NOT EXISTS (SELECT * FROM msdb.dbo.sysoperators WHERE name = @OperatorName)
BEGIN
    RAISERROR('Operator not found. Run 01_DatabaseMail_Operator_Alerts.sql first.', 16, 1);
    RETURN;
END

CREATE TABLE #FileExist (FileExists int, IsDirectory int, ParentDirExists int);
INSERT INTO #FileExist EXEC master.dbo.xp_fileexist @Directory;
IF NOT EXISTS (SELECT * FROM #FileExist WHERE IsDirectory = 1)
BEGIN
    DROP TABLE #FileExist;
    SET @Err = N'Directory ' + @Directory + N' not found (or not visible to the SQL Server service account).';
    RAISERROR(@Err, 16, 1);
    RETURN;
END
DROP TABLE #FileExist;

/* ---------- 2. Rewrite backup job steps ---------- */
-- USER FULL
SET @Cmd = N'sqlcmd -E -S ' + @Token + N' -d ' + @OlaDatabase
         + N' -Q "EXECUTE [dbo].[DatabaseBackup] @Databases = ''USER_DATABASES'', @Directory = N''' + @Directory
         + N''', @BackupType = ''FULL'', @Verify = ''Y'', @CleanupTime = ' + CAST(@FullCleanupHours AS nvarchar(10))
         + N', @CheckSum = ''Y'', @LogToTable = ''Y''" -b';
EXEC msdb.dbo.sp_update_jobstep @job_name = N'DatabaseBackup - USER_DATABASES - FULL', @step_id = 1, @command = @Cmd;

-- USER DIFF
SET @Cmd = N'sqlcmd -E -S ' + @Token + N' -d ' + @OlaDatabase
         + N' -Q "EXECUTE [dbo].[DatabaseBackup] @Databases = ''USER_DATABASES'', @Directory = N''' + @Directory
         + N''', @BackupType = ''DIFF'', @ChangeBackupType = ''Y'', @Verify = ''Y'', @CleanupTime = ' + CAST(@DiffCleanupHours AS nvarchar(10))
         + N', @CheckSum = ''Y'', @LogToTable = ''Y''" -b';
EXEC msdb.dbo.sp_update_jobstep @job_name = N'DatabaseBackup - USER_DATABASES - DIFF', @step_id = 1, @command = @Cmd;

-- USER LOG
SET @Cmd = N'sqlcmd -E -S ' + @Token + N' -d ' + @OlaDatabase
         + N' -Q "EXECUTE [dbo].[DatabaseBackup] @Databases = ''USER_DATABASES'', @Directory = N''' + @Directory
         + N''', @BackupType = ''LOG'', @ChangeBackupType = ''Y'', @Verify = ''Y'', @CleanupTime = ' + CAST(@LogCleanupHours AS nvarchar(10))
         + N', @CheckSum = ''Y'', @LogToTable = ''Y''" -b';
EXEC msdb.dbo.sp_update_jobstep @job_name = N'DatabaseBackup - USER_DATABASES - LOG', @step_id = 1, @command = @Cmd;

-- SYSTEM FULL (master, model, msdb)
SET @Cmd = N'sqlcmd -E -S ' + @Token + N' -d ' + @OlaDatabase
         + N' -Q "EXECUTE [dbo].[DatabaseBackup] @Databases = ''SYSTEM_DATABASES'', @Directory = N''' + @Directory
         + N''', @BackupType = ''FULL'', @Verify = ''Y'', @CleanupTime = ' + CAST(@SysCleanupHours AS nvarchar(10))
         + N', @CheckSum = ''Y'', @LogToTable = ''Y''" -b';
EXEC msdb.dbo.sp_update_jobstep @job_name = N'DatabaseBackup - SYSTEM_DATABASES - FULL', @step_id = 1, @command = @Cmd;

/* ---------- 3. Schedules (created DISABLED) ---------- */
IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobschedules js
               JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id
               WHERE j.name = N'DatabaseBackup - USER_DATABASES - FULL')
    EXEC msdb.dbo.sp_add_jobschedule
         @job_name = N'DatabaseBackup - USER_DATABASES - FULL', @name = N'Weekly full',
         @enabled = 0, @freq_type = 8, @freq_interval = @FullDayMask, @freq_recurrence_factor = 1,
         @freq_subday_type = 1, @active_start_time = @FullStartTime;

IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobschedules js
               JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id
               WHERE j.name = N'DatabaseBackup - USER_DATABASES - DIFF')
    EXEC msdb.dbo.sp_add_jobschedule
         @job_name = N'DatabaseBackup - USER_DATABASES - DIFF', @name = N'Daily diff (not full day)',
         @enabled = 0, @freq_type = 8, @freq_interval = @DiffDayMask, @freq_recurrence_factor = 1,
         @freq_subday_type = 1, @active_start_time = @DiffStartTime;

IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobschedules js
               JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id
               WHERE j.name = N'DatabaseBackup - USER_DATABASES - LOG')
    EXEC msdb.dbo.sp_add_jobschedule
         @job_name = N'DatabaseBackup - USER_DATABASES - LOG', @name = N'Log every N minutes',
         @enabled = 0, @freq_type = 4, @freq_interval = 1,
         @freq_subday_type = 4, @freq_subday_interval = @LogEveryMinutes,
         @active_start_time = 0, @active_end_time = 235959;

IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobschedules js
               JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id
               WHERE j.name = N'DatabaseBackup - SYSTEM_DATABASES - FULL')
    EXEC msdb.dbo.sp_add_jobschedule
         @job_name = N'DatabaseBackup - SYSTEM_DATABASES - FULL', @name = N'Daily system full',
         @enabled = 0, @freq_type = 4, @freq_interval = 1,
         @freq_subday_type = 1, @active_start_time = @SysFullTime;

-- Housekeeping (Ola defaults keep 30 days of CommandLog / history / output files)
IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id WHERE j.name = N'CommandLog Cleanup')
    EXEC msdb.dbo.sp_add_jobschedule @job_name = N'CommandLog Cleanup', @name = N'Weekly',
         @enabled = 0, @freq_type = 8, @freq_interval = 1, @freq_recurrence_factor = 1, @freq_subday_type = 1, @active_start_time = 50000;
IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id WHERE j.name = N'Output File Cleanup')
    EXEC msdb.dbo.sp_add_jobschedule @job_name = N'Output File Cleanup', @name = N'Weekly',
         @enabled = 0, @freq_type = 8, @freq_interval = 1, @freq_recurrence_factor = 1, @freq_subday_type = 1, @active_start_time = 51000;
IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id WHERE j.name = N'sp_delete_backuphistory')
    EXEC msdb.dbo.sp_add_jobschedule @job_name = N'sp_delete_backuphistory', @name = N'Weekly',
         @enabled = 0, @freq_type = 8, @freq_interval = 1, @freq_recurrence_factor = 1, @freq_subday_type = 1, @active_start_time = 52000;
IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id WHERE j.name = N'sp_purge_jobhistory')
    EXEC msdb.dbo.sp_add_jobschedule @job_name = N'sp_purge_jobhistory', @name = N'Weekly',
         @enabled = 0, @freq_type = 8, @freq_interval = 1, @freq_recurrence_factor = 1, @freq_subday_type = 1, @active_start_time = 53000;

/* DatabaseIntegrityCheck and IndexOptimize jobs are left UNSCHEDULED on purpose.
   If Commvault was not running DBCC CHECKDB for you (it wasn't), schedule
   'DatabaseIntegrityCheck - USER_DATABASES' weekly before the Sunday full -
   a backup of a corrupt database is still a corrupt backup. */

/* ---------- 4. Email operator on failure for every Ola job ---------- */
DECLARE job_cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM msdb.dbo.sysjobs
    WHERE name LIKE N'DatabaseBackup - %'
       OR name LIKE N'DatabaseIntegrityCheck - %'
       OR name LIKE N'IndexOptimize - %'
       OR name IN (N'CommandLog Cleanup', N'Output File Cleanup', N'sp_delete_backuphistory', N'sp_purge_jobhistory');
OPEN job_cur;
FETCH NEXT FROM job_cur INTO @Job;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC msdb.dbo.sp_update_job @job_name = @Job,
         @notify_level_email = 2,                 -- 2 = on failure
         @notify_email_operator_name = @OperatorName;
    FETCH NEXT FROM job_cur INTO @Job;
END
CLOSE job_cur; DEALLOCATE job_cur;

PRINT 'Backup jobs configured on ' + @@SERVERNAME + '. Schedules are DISABLED until cutover (04_Cutover.sql).';

/* Review what was set */
SELECT j.name AS job_name, j.enabled AS job_enabled, s.name AS schedule_name, s.enabled AS schedule_enabled,
       o.name AS notify_operator, st.command
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobsteps st ON st.job_id = j.job_id AND st.step_id = 1
LEFT JOIN msdb.dbo.sysjobschedules js ON js.job_id = j.job_id
LEFT JOIN msdb.dbo.sysschedules s ON s.schedule_id = js.schedule_id
LEFT JOIN msdb.dbo.sysoperators o ON o.id = j.notify_email_operator_id
WHERE j.name LIKE N'DatabaseBackup - %'
ORDER BY j.name;
