/*
================================================================================
 03_Backup_Health_Check.sql
 SQL Server 2005 SP4 - run on BOTH mirroring partners.

 Job-failure emails (from 02) tell you when a backup job FAILS. They don't
 tell you when backups silently STOP: a disabled job or schedule, Agent not
 running, a database skipped, a new database never picked up. This catches
 those by reading msdb backup history and emailing when any ONLINE user
 database is overdue.

 Creates
   master.dbo.usp_CheckBackupHealth
   Job 'DBA - Backup Health Check' (hourly, created DISABLED - 04 enables it)

 Thresholds (defaults, set for weekly full / daily diff / 15 min log):
   full          older than 200 hours (8 days + slack)
   full or diff  older than 26 hours
   log           older than 45 minutes (FULL / BULK_LOGGED databases only)

 Mirroring: only ONLINE databases are checked, so the mirror side checks
 nothing and the principal checks everything. Backup history is per server,
 so straight after a failover the new principal will report "No full backup
 on this server" until the FULL job runs there - which is what you want:
 take a full on the new principal after any failover.

 Run manually any time:  EXEC master.dbo.usp_CheckBackupHealth @SendEmail = 0;
================================================================================
*/
USE master;
GO

IF OBJECT_ID(N'dbo.usp_CheckBackupHealth', N'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_CheckBackupHealth;
GO

CREATE PROCEDURE dbo.usp_CheckBackupHealth
    @FullHours    int           = 200,
    @DiffHours    int           = 26,
    @LogMinutes   int           = 45,
    @ProfileName  sysname       = N'DBA Mail',
    @OperatorName sysname       = N'DBA Team',
    @Recipients   nvarchar(max) = NULL,      -- NULL = use the operator's email address
    @SendEmail    bit           = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now        datetime,
            @ServerName sysname,
            @Count      int,
            @Rows       nvarchar(max),
            @Body       nvarchar(max),
            @Subject    nvarchar(255);

    SET @Now        = GETDATE();
    SET @ServerName = CAST(SERVERPROPERTY('ServerName') AS sysname);

    CREATE TABLE #Health
    (
        DatabaseName   sysname       NOT NULL,
        RecoveryModel  nvarchar(60)  NOT NULL,
        LastFull       datetime      NULL,
        LastFullOrDiff datetime      NULL,
        LastLog        datetime      NULL,
        Issue          nvarchar(400) NULL
    );

    INSERT INTO #Health (DatabaseName, RecoveryModel, LastFull, LastFullOrDiff, LastLog)
    SELECT d.name,
           d.recovery_model_desc,
           MAX(CASE WHEN b.type = 'D'         THEN b.backup_finish_date END),
           MAX(CASE WHEN b.type IN ('D', 'I') THEN b.backup_finish_date END),
           MAX(CASE WHEN b.type = 'L'         THEN b.backup_finish_date END)
    FROM sys.databases d
    LEFT JOIN msdb.dbo.backupset b
           ON  b.database_name = d.name
           AND b.is_copy_only  = 0
           AND b.server_name   = @ServerName
    WHERE d.database_id > 4                                  -- user databases
      AND d.state_desc = N'ONLINE'                           -- skips mirror (RESTORING), offline etc.
      AND d.source_database_id IS NULL                       -- skips database snapshots
      AND d.create_date < DATEADD(mi, -@LogMinutes, @Now)   -- give brand-new databases one log cycle
    GROUP BY d.name, d.recovery_model_desc;

    UPDATE #Health
    SET Issue =
          CASE WHEN LastFull IS NULL
                    THEN N'No full backup on this server. '
               WHEN LastFull < DATEADD(hh, -@FullHours, @Now)
                    THEN N'Full older than ' + CAST(@FullHours AS nvarchar(10)) + N'h. '
               ELSE N'' END
        + CASE WHEN LastFullOrDiff IS NOT NULL AND LastFullOrDiff < DATEADD(hh, -@DiffHours, @Now)
                    THEN N'No full/diff in ' + CAST(@DiffHours AS nvarchar(10)) + N'h. '
               ELSE N'' END
        + CASE WHEN RecoveryModel <> N'SIMPLE'
                AND (LastLog IS NULL OR LastLog < DATEADD(mi, -@LogMinutes, @Now))
                    THEN N'No log backup in ' + CAST(@LogMinutes AS nvarchar(10)) + N' min. '
               ELSE N'' END;

    DELETE FROM #Health WHERE Issue = N'';

    SELECT @Count = COUNT(*) FROM #Health;

    -- Result set for manual runs
    SELECT DatabaseName, RecoveryModel, LastFull, LastFullOrDiff, LastLog, Issue
    FROM #Health
    ORDER BY DatabaseName;

    IF @Count = 0
    BEGIN
        PRINT 'All ONLINE user databases on ' + @ServerName + ' are within backup thresholds.';
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
                   td = RecoveryModel, '',
                   td = ISNULL(CONVERT(nvarchar(19), LastFull, 120), N'never'), '',
                   td = ISNULL(CONVERT(nvarchar(19), LastFullOrDiff, 120), N'never'), '',
                   td = ISNULL(CONVERT(nvarchar(19), LastLog, 120), N'never'), '',
                   td = Issue
            FROM #Health
            ORDER BY DatabaseName
            FOR XML PATH('tr'), TYPE) AS nvarchar(max));

        SET @Body =
              N'<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:10pt">'
            + N'<p><b>' + CAST(@Count AS nvarchar(10)) + N'</b> database(s) on <b>' + @ServerName
            + N'</b> are outside backup thresholds (checked ' + CONVERT(nvarchar(19), @Now, 120) + N').</p>'
            + N'<table border="1" cellpadding="4" cellspacing="0" style="border-collapse:collapse;font-size:10pt">'
            + N'<tr style="background:#ddd"><th>Database</th><th>Recovery</th><th>Last full</th>'
            + N'<th>Last full/diff</th><th>Last log</th><th>Issue</th></tr>'
            + ISNULL(@Rows, N'')
            + N'</table>'
            + N'<p>Check:</p><ul>'
            + N'<li>SQL Agent is running, and the DatabaseBackup jobs and schedules are enabled.</li>'
            + N'<li>Job history and output files of the DatabaseBackup jobs.</li>'
            + N'<li>Errors: SELECT TOP 50 * FROM master.dbo.CommandLog WHERE ErrorNumber &lt;&gt; 0 ORDER BY ID DESC</li>'
            + N'<li>Free space on X:\backup.</li>'
            + N'<li>If mirroring failed over recently, run job ''DatabaseBackup - USER_DATABASES - FULL'' on this server.</li>'
            + N'</ul></body></html>';

        SET @Subject = N'[' + @ServerName + N'] Backup health check: '
                     + CAST(@Count AS nvarchar(10)) + N' database(s) need attention';

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

/* ---------- Hourly job (created DISABLED; 04_Cutover.sql enables it) ---------- */
DECLARE @OperatorName sysname, @JobOwner sysname;
SET @OperatorName = N'DBA Team';
SET @JobOwner     = SUSER_SNAME(0x01);   -- the sa login, even if renamed

IF NOT EXISTS (SELECT * FROM msdb.dbo.sysjobs WHERE name = N'DBA - Backup Health Check')
BEGIN
    EXEC msdb.dbo.sp_add_job
         @job_name = N'DBA - Backup Health Check',
         @enabled = 1,
         @description = N'Emails the DBA operator when any ONLINE user database is overdue for a full, diff or log backup.',
         @category_name = N'Database Maintenance',
         @owner_login_name = @JobOwner,
         @notify_level_email = 2,
         @notify_email_operator_name = @OperatorName;

    EXEC msdb.dbo.sp_add_jobstep
         @job_name = N'DBA - Backup Health Check',
         @step_name = N'Check backup history',
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
