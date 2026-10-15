/*
================================================================================
 03_Backup_Health_Check.sql
 SQL Server 2005 SP4 - run on BOTH mirroring partners.

 Job-failure emails (from 02) tell you when a backup job FAILS. This catches
 the ways a native backup set can quietly become unusable while every job
 still succeeds. It reads msdb and emails the DBA operator when:

   Full / Diff / Log   an ONLINE user database is overdue
   System full         master / model / msdb have no full in 30h
   Diff base           the full your diffs depend on is not a native full
                       taken on THIS server into X:\backup, or that .bak file
                       is no longer on disk. With ONE full kept, this is the
                       file every diff relies on. Triggered by: a mirroring
                       failover or failback, an ad-hoc full without
                       COPY_ONLY, a Commvault SQL backup still running, or a
                       VSS snapshot full taken by a file-level backup.
   Non-native backup   any non-COPY_ONLY backup written anywhere other than
                       X:\backup in the last 70 minutes (Commvault SQL agent
                       or its automatic log schedule, someone's ad-hoc
                       backup, VSS snapshot fulls, BACKUP LOG TO DISK='NUL').
                       A log backup elsewhere splits the log chain; a full
                       elsewhere moves the differential base.

 Thresholds (weekly full Sun 01:00, daily diff 01:00, log every 15 min):
   full 200h (8 days + slack), full/diff 30h, log 45 min, system full 30h.
   The 30h full/diff threshold leaves ~5h for the Sunday full / daily diff
   of the last database in the list to finish before it can false-alert.

 Mirroring: only ONLINE databases are checked, so the mirror side checks
 only its system databases. Backup history is per server, so after a role
 change the new principal reports "Diff base" (and "Full") until its FULL
 job has run - which is exactly the action needed.

 Creates
   master.dbo.usp_CheckBackupHealth
   Job 'DBA - Backup Health Check' (hourly; schedule created DISABLED -
   05_Enable_Health_Check.sql enables it once the first native fulls exist,
   otherwise it would alert during cutover about the Commvault-era base).

 Run manually any time:
   EXEC master.dbo.usp_CheckBackupHealth @SendEmail = 0;
================================================================================
*/
USE master;
GO

IF OBJECT_ID(N'dbo.usp_CheckBackupHealth', N'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_CheckBackupHealth;
GO

CREATE PROCEDURE dbo.usp_CheckBackupHealth
    @Directory              nvarchar(256) = N'X:\backup',
    @FullHours              int           = 200,
    @DiffHours              int           = 30,
    @LogMinutes             int           = 45,
    @SysFullHours           int           = 30,
    @ForeignLookbackMinutes int           = 70,     -- job runs hourly, so each non-native backup is reported once
    @ProfileName            sysname       = N'DBA Mail',
    @OperatorName           sysname       = N'DBA Team',
    @Recipients             nvarchar(max) = NULL,   -- NULL = the operator's email address
    @SendEmail              bit           = 1,
    @IssueCount             int           = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now         datetime,
            @ServerName  sysname,
            @ServerName2 sysname,
            @DirPrefix   nvarchar(260),
            @Db          sysname,
            @Path        nvarchar(260),
            @Rows        nvarchar(max),
            @Body        nvarchar(max),
            @Subject     nvarchar(255);

    SET @Now         = GETDATE();
    SET @ServerName  = @@SERVERNAME;
    SET @ServerName2 = CAST(SERVERPROPERTY('ServerName') AS sysname);
    SET @DirPrefix   = CASE WHEN RIGHT(@Directory, 1) = N'\' THEN @Directory ELSE @Directory + N'\' END;

    CREATE TABLE #Issues
    (
        DatabaseName sysname        NOT NULL,
        CheckName    nvarchar(60)   NOT NULL,
        Detail       nvarchar(1000) NOT NULL
    );

    CREATE TABLE #Last
    (
        DatabaseName   sysname      NOT NULL,
        DatabaseId     int          NOT NULL,
        RecoveryModel  nvarchar(60) NOT NULL,
        LastFull       datetime     NULL,
        LastFullOrDiff datetime     NULL,
        LastLog        datetime     NULL
    );

    CREATE TABLE #Base
    (
        DatabaseName sysname          NOT NULL,
        BaseGuid     uniqueidentifier NULL,
        BaseLsn      numeric(25,0)    NULL,
        BackupSetId  int              NULL
    );

    CREATE TABLE #FileExist (FileExists int, IsDirectory int, ParentDirExists int);

    /* ---------- Latest native-chain backups per database (this server only) ----------
       server_name filter excludes rows msdb records when RESTORING another
       server's backup (e.g. the restore used to set up mirroring). */
    INSERT INTO #Last (DatabaseName, DatabaseId, RecoveryModel, LastFull, LastFullOrDiff, LastLog)
    SELECT d.name,
           d.database_id,
           d.recovery_model_desc,
           MAX(CASE WHEN b.type = 'D'         THEN b.backup_finish_date END),
           MAX(CASE WHEN b.type IN ('D', 'I') THEN b.backup_finish_date END),
           MAX(CASE WHEN b.type = 'L'         THEN b.backup_finish_date END)
    FROM sys.databases d
    LEFT JOIN msdb.dbo.backupset b
           ON  b.database_name = d.name
           AND b.is_copy_only  = 0
           AND b.server_name IN (@ServerName, @ServerName2)
    WHERE d.database_id <> 2                                 -- tempdb
      AND d.state_desc = N'ONLINE'                           -- skips mirror (RESTORING), offline etc.
      AND d.source_database_id IS NULL                       -- skips database snapshots
      AND d.create_date < DATEADD(mi, -@LogMinutes, @Now)   -- give a brand-new database one log cycle
    GROUP BY d.name, d.database_id, d.recovery_model_desc;

    /* ---------- System databases: one daily full ---------- */
    INSERT INTO #Issues (DatabaseName, CheckName, Detail)
    SELECT DatabaseName, N'System full',
           CASE WHEN LastFull IS NULL THEN N'No full backup on this server.'
                ELSE N'Last full ' + CONVERT(nvarchar(19), LastFull, 120) + N', older than '
                     + CAST(@SysFullHours AS nvarchar(10)) + N'h.' END
    FROM #Last
    WHERE DatabaseId IN (1, 3, 4)
      AND (LastFull IS NULL OR LastFull < DATEADD(hh, -@SysFullHours, @Now));

    /* ---------- User databases: overdue ---------- */
    INSERT INTO #Issues (DatabaseName, CheckName, Detail)
    SELECT DatabaseName, N'Full',
           CASE WHEN LastFull IS NULL THEN N'No full backup on this server.'
                ELSE N'Last full ' + CONVERT(nvarchar(19), LastFull, 120) + N', older than '
                     + CAST(@FullHours AS nvarchar(10)) + N'h.' END
    FROM #Last
    WHERE DatabaseId > 4
      AND (LastFull IS NULL OR LastFull < DATEADD(hh, -@FullHours, @Now));

    INSERT INTO #Issues (DatabaseName, CheckName, Detail)
    SELECT DatabaseName, N'Diff',
           N'Last full or diff ' + CONVERT(nvarchar(19), LastFullOrDiff, 120) + N', older than '
           + CAST(@DiffHours AS nvarchar(10)) + N'h.'
    FROM #Last
    WHERE DatabaseId > 4
      AND LastFullOrDiff IS NOT NULL
      AND LastFullOrDiff < DATEADD(hh, -@DiffHours, @Now);

    INSERT INTO #Issues (DatabaseName, CheckName, Detail)
    SELECT DatabaseName, N'Log',
           CASE WHEN LastLog IS NULL THEN N'No log backup on this server.'
                ELSE N'Last log ' + CONVERT(nvarchar(19), LastLog, 120) + N', older than '
                     + CAST(@LogMinutes AS nvarchar(10)) + N' min.' END
    FROM #Last
    WHERE DatabaseId > 4
      AND RecoveryModel <> N'SIMPLE'
      AND (LastLog IS NULL OR LastLog < DATEADD(mi, -@LogMinutes, @Now));

    /* ---------- Differential base: must be a native full, on this server, still on disk ----------
       Same source Ola uses (primary data file in sys.master_files), including
       Ola's SQL 2005 rule: a base LSN with no base time is stale - ignore it. */
    INSERT INTO #Base (DatabaseName, BaseGuid, BaseLsn)
    SELECT l.DatabaseName, mf.differential_base_guid, mf.differential_base_lsn
    FROM #Last l
    JOIN sys.master_files mf
      ON mf.database_id = l.DatabaseId AND mf.[type] = 0 AND mf.[file_id] = 1
    WHERE l.DatabaseId > 4
      AND mf.differential_base_lsn  IS NOT NULL
      AND mf.differential_base_time IS NOT NULL;

    UPDATE bs
    SET BackupSetId = (SELECT TOP 1 b.backup_set_id
                       FROM msdb.dbo.backupset b
                       WHERE b.database_name = bs.DatabaseName
                         AND b.type = 'D'
                         AND (b.backup_set_uuid = bs.BaseGuid OR b.checkpoint_lsn = bs.BaseLsn)
                       ORDER BY CASE WHEN b.server_name IN (@ServerName, @ServerName2) THEN 0 ELSE 1 END,
                                b.backup_set_id DESC)
    FROM #Base bs;

    INSERT INTO #Issues (DatabaseName, CheckName, Detail)
    SELECT DatabaseName, N'Diff base',
           N'The full that diffs are based on is not in this server''s backup history '
         + N'(taken on the mirroring partner, by another tool, or history purged). '
         + N'Run job ''DatabaseBackup - USER_DATABASES - FULL'' on this server.'
    FROM #Base
    WHERE BackupSetId IS NULL;

    INSERT INTO #Issues (DatabaseName, CheckName, Detail)
    SELECT bs.DatabaseName, N'Diff base',
           N'Diffs are based on a full taken on ' + b.server_name + N' at '
         + CONVERT(nvarchar(19), b.backup_finish_date, 120)
         + N'. Run job ''DatabaseBackup - USER_DATABASES - FULL'' on this server.'
    FROM #Base bs
    JOIN msdb.dbo.backupset b ON b.backup_set_id = bs.BackupSetId
    WHERE b.server_name NOT IN (@ServerName, @ServerName2);

    INSERT INTO #Issues (DatabaseName, CheckName, Detail)
    SELECT bs.DatabaseName, N'Diff base',
           N'Diffs are based on a full written to ' + LEFT(mf.physical_device_name, 300)
         + N' at ' + CONVERT(nvarchar(19), b.backup_finish_date, 120)
         + CASE WHEN b.is_snapshot = 1 THEN N' (VSS snapshot)' ELSE N'' END
         + N', not to ' + @Directory + N'. Run job ''DatabaseBackup - USER_DATABASES - FULL''.'
    FROM #Base bs
    JOIN msdb.dbo.backupset b         ON b.backup_set_id = bs.BackupSetId
    JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = b.media_set_id
    WHERE b.server_name IN (@ServerName, @ServerName2)
      AND mf.physical_device_name NOT LIKE @DirPrefix + N'%';

    -- Base full is in X:\backup: is the file still there?
    DECLARE base_cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT bs.DatabaseName, mf.physical_device_name
        FROM #Base bs
        JOIN msdb.dbo.backupset b         ON b.backup_set_id = bs.BackupSetId
        JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = b.media_set_id
        WHERE b.server_name IN (@ServerName, @ServerName2)
          AND mf.physical_device_name LIKE @DirPrefix + N'%';
    OPEN base_cur;
    FETCH NEXT FROM base_cur INTO @Db, @Path;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DELETE FROM #FileExist;
        INSERT INTO #FileExist EXEC master.dbo.xp_fileexist @Path;
        IF EXISTS (SELECT * FROM #FileExist WHERE FileExists = 0)
            INSERT INTO #Issues (DatabaseName, CheckName, Detail)
            VALUES (@Db, N'Diff base',
                    N'The full that diffs are based on is missing from disk: ' + @Path
                  + N'. Local diffs cannot be restored. Run job ''DatabaseBackup - USER_DATABASES - FULL''.');
        FETCH NEXT FROM base_cur INTO @Db, @Path;
    END
    CLOSE base_cur; DEALLOCATE base_cur;

    /* ---------- Non-native backups (anything not COPY_ONLY and not in X:\backup) ---------- */
    INSERT INTO #Issues (DatabaseName, CheckName, Detail)
    SELECT b.database_name, N'Non-native backup',
           CASE b.type WHEN 'D' THEN N'Full' WHEN 'I' THEN N'Diff' WHEN 'L' THEN N'Log' ELSE N'Other' END
         + N' backup (not COPY_ONLY) finished ' + CONVERT(nvarchar(19), b.backup_finish_date, 120)
         + N' to ' + LEFT(mf.physical_device_name, 300)
         + CASE WHEN b.is_snapshot = 1 THEN N' (VSS snapshot)' ELSE N'' END
         + CASE b.type
             WHEN 'L' THEN N'. The log chain is now split between ' + @Directory + N' and that location.'
             WHEN 'D' THEN N'. Differential base has moved away from ' + @Directory + N' - see Diff base.'
             ELSE N'.' END
         + N' Find who/what took it (backupset.user_name = ' + ISNULL(b.user_name, N'?') + N').'
    FROM msdb.dbo.backupset b
    JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = b.media_set_id
    WHERE b.backup_finish_date >= DATEADD(mi, -@ForeignLookbackMinutes, @Now)
      AND b.is_copy_only = 0
      AND b.server_name IN (@ServerName, @ServerName2)
      AND mf.physical_device_name NOT LIKE @DirPrefix + N'%';

    /* ---------- Report ---------- */
    SELECT @IssueCount = COUNT(*) FROM #Issues;

    SELECT DatabaseName, CheckName, Detail
    FROM #Issues
    ORDER BY DatabaseName, CheckName;

    IF @IssueCount = 0
    BEGIN
        PRINT 'Backup health check OK on ' + @ServerName + '.';
        RETURN 0;
    END

    IF @SendEmail = 1
    BEGIN
        IF @Recipients IS NULL
            SELECT @Recipients = email_address FROM msdb.dbo.sysoperators WHERE name = @OperatorName;

        IF @Recipients IS NULL
        BEGIN
            RAISERROR('No recipients: pass @Recipients or create the operator.', 16, 1);
            RETURN 1;
        END

        SET @Rows = CAST((
            SELECT td = DatabaseName, '',
                   td = CheckName, '',
                   td = Detail
            FROM #Issues
            ORDER BY DatabaseName, CheckName
            FOR XML PATH('tr'), TYPE) AS nvarchar(max));

        SET @Body =
              N'<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:10pt">'
            + N'<p><b>' + CAST(@IssueCount AS nvarchar(10)) + N'</b> backup issue(s) on <b>' + @ServerName
            + N'</b> (checked ' + CONVERT(nvarchar(19), @Now, 120) + N').</p>'
            + N'<table border="1" cellpadding="4" cellspacing="0" style="border-collapse:collapse;font-size:10pt">'
            + N'<tr style="background:#ddd"><th>Database</th><th>Check</th><th>Detail</th></tr>'
            + ISNULL(@Rows, N'')
            + N'</table>'
            + N'<p>Also check:</p><ul>'
            + N'<li>SQL Agent is running; DatabaseBackup jobs and schedules are enabled.</li>'
            + N'<li>Job history / output files of the DatabaseBackup jobs.</li>'
            + N'<li>SELECT TOP 50 * FROM master.dbo.CommandLog WHERE ErrorNumber &lt;&gt; 0 ORDER BY ID DESC</li>'
            + N'<li>Free space on ' + @Directory + N'.</li>'
            + N'</ul></body></html>';

        SET @Subject = N'[' + @ServerName + N'] Backup health check: '
                     + CAST(@IssueCount AS nvarchar(10)) + N' issue(s)';

        EXEC msdb.dbo.sp_send_dbmail
             @profile_name = @ProfileName,
             @recipients   = @Recipients,
             @subject      = @Subject,
             @body         = @Body,
             @body_format  = 'HTML',
             @importance   = 'High';
    END

    RETURN 0;
END
GO

/* ---------- Hourly job (schedule created DISABLED; 05 enables it) ---------- */
DECLARE @OperatorName sysname, @JobOwner sysname;
SET @OperatorName = N'DBA Team';
SET @JobOwner     = SUSER_SNAME(0x01);   -- the sa login, even if renamed

IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobs WHERE name = N'DBA - Backup Health Check')
BEGIN
    EXEC msdb.dbo.sp_add_job
         @job_name = N'DBA - Backup Health Check',
         @enabled = 1,
         @description = N'Emails the DBA operator about overdue backups, a broken differential base, or non-native backups.',
         @category_name = N'Database Maintenance',
         @owner_login_name = @JobOwner,
         @notify_level_email = 2,
         @notify_email_operator_name = @OperatorName;

    EXEC msdb.dbo.sp_add_jobstep
         @job_name = N'DBA - Backup Health Check',
         @step_name = N'Check backups',
         @subsystem = N'TSQL',
         @database_name = N'master',
         @command = N'EXEC dbo.usp_CheckBackupHealth;';

    EXEC msdb.dbo.sp_add_jobschedule
         @job_name = N'DBA - Backup Health Check', @name = N'Hourly at :20',
         @enabled = 0, @freq_type = 4, @freq_interval = 1,
         @freq_subday_type = 8, @freq_subday_interval = 1,     -- every 1 hour
         @active_start_time = 2000, @active_end_time = 235959;

    EXEC msdb.dbo.sp_add_jobserver @job_name = N'DBA - Backup Health Check';
END

PRINT 'Health check installed on ' + @@SERVERNAME + '. Try: EXEC master.dbo.usp_CheckBackupHealth @SendEmail = 0;';
GO
