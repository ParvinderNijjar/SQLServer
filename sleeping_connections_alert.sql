/*============================================================================
  Sleeping connections alert
  --------------------------------------------------------------------------
  Part 1: Logging table (keeps a history of every check, so you can see the trend)
  Part 2: Stored procedure that takes one snapshot of sleeping user sessions,
          logs it, and if the count from the monitored hosts exceeds the
          threshold, emails a report with three tables:
            1. Total sleeping connections on the instance
            2. Sleeping connections by host name
            3. Sleeping connections by date the connection was started
          Repeat alerts are held back for @AlertCooldownMinutes.
  Part 3: SQL Server Agent job that runs the procedure every 15 minutes.

  Before running, change:
    - USE [DBA] / @database_name  -> your admin/utility database
    - @ProfileName                -> your Database Mail profile
    - @Recipients                 -> who gets the alert
    - @HostList                   -> the client servers to watch (comma separated)

  Always On: deploy to every replica. Keep the admin database OUT of the
  availability group, otherwise the log insert fails on secondaries.

  Works on SQL Server 2012+ at any database compatibility level.
============================================================================*/

USE [DBA];
GO

/*----------------------------------------------------------------------------
  Part 1: Log table
----------------------------------------------------------------------------*/
IF OBJECT_ID(N'dbo.SleepingConnectionsLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.SleepingConnectionsLog
    (
          LogId           int IDENTITY(1,1) NOT NULL CONSTRAINT PK_SleepingConnectionsLog PRIMARY KEY
        , CaptureTime     datetime2(0)      NOT NULL
        , InstanceTotal   int               NOT NULL
        , MonitoredTotal  int               NOT NULL
        , OpenTranTotal   int               NOT NULL
        , Threshold       int               NOT NULL
        , AlertSent       bit               NOT NULL
    );

    CREATE NONCLUSTERED INDEX IX_SleepingConnectionsLog_CaptureTime
        ON dbo.SleepingConnectionsLog (CaptureTime) INCLUDE (AlertSent);
END;
GO

/*----------------------------------------------------------------------------
  Part 2: Procedure
----------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE dbo.usp_Alert_SleepingConnections
      @HostList              nvarchar(max)                  -- e.g. N'APPSRV01,APPSRV02,WEBSRV01'
    , @Threshold             int           = 100            -- alert when monitored-host count is ABOVE this
    , @ProfileName           sysname       = N'DBA Mail Profile'
    , @Recipients            nvarchar(max) = N'dba-team@yourcompany.com'
    , @AlertCooldownMinutes  int           = 60             -- min gap between alert emails; 0 = every run
    , @RetentionDays         int           = 30             -- how long to keep log rows
    , @Debug                 bit           = 0              -- 1 = return result sets only: no email, no logging
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @CaptureTime datetime2(0) = SYSDATETIME();

    /* Normalise the host list to ,HOST1,HOST2, so we can match with CHARINDEX.
       (Avoids STRING_SPLIT, which needs compat level 130, and avoids LIKE,
       where an underscore in a host name would act as a wildcard.) */
    DECLARE @HostListNorm nvarchar(max) =
        N',' + REPLACE(REPLACE(REPLACE(REPLACE(@HostList,
                 N' ', N''), NCHAR(9), N''), NCHAR(13), N''), NCHAR(10), N'') + N',';

    /* One snapshot of every sleeping user session on the instance, so the
       alert check and all three tables describe the same moment. */
    DECLARE @Sessions TABLE
    (
          session_id        smallint      NOT NULL PRIMARY KEY
        , host_name         nvarchar(128) NOT NULL
        , connect_time      datetime      NULL
        , open_tran_count   int           NOT NULL
        , is_monitored      bit           NOT NULL
    );

    INSERT @Sessions (session_id, host_name, connect_time, open_tran_count, is_monitored)
    SELECT  s.session_id
          , ISNULL(NULLIF(s.host_name, N''), N'(no host name)')
          , COALESCE(c.connect_time, s.login_time)   -- physical connection start time
          , s.open_transaction_count
          , CASE WHEN s.host_name IS NOT NULL
                  AND CHARINDEX(N',' + s.host_name + N',', @HostListNorm) > 0
                 THEN 1 ELSE 0 END
    FROM    sys.dm_exec_sessions AS s
    /* MIN() collapses MARS child connections to one row per session */
    OUTER APPLY (SELECT connect_time = MIN(ec.connect_time)
                 FROM   sys.dm_exec_connections AS ec
                 WHERE  ec.session_id = s.session_id) AS c
    WHERE   s.is_user_process = 1
      AND   s.status = N'sleeping'
      AND   s.session_id <> @@SPID;

    DECLARE @InstanceTotal  int = (SELECT COUNT(*) FROM @Sessions);
    DECLARE @MonitoredTotal int = (SELECT COUNT(*) FROM @Sessions WHERE is_monitored = 1);
    DECLARE @OpenTranTotal  int = (SELECT COUNT(*) FROM @Sessions WHERE open_tran_count > 0);

    /* Should we send? Over threshold AND no alert sent within the cooldown */
    DECLARE @SendAlert bit = 0;
    IF @MonitoredTotal > @Threshold
       AND NOT EXISTS (SELECT 1
                       FROM   dbo.SleepingConnectionsLog
                       WHERE  AlertSent = 1
                         AND  CaptureTime > DATEADD(MINUTE, -@AlertCooldownMinutes, @CaptureTime))
        SET @SendAlert = 1;

    IF @Debug = 1
    BEGIN
        SELECT  CaptureTime            = @CaptureTime
              , InstanceSleepingTotal  = @InstanceTotal
              , MonitoredHostsTotal    = @MonitoredTotal
              , SleepingWithOpenTran   = @OpenTranTotal
              , Threshold              = @Threshold
              , OverThreshold          = CASE WHEN @MonitoredTotal > @Threshold THEN 1 ELSE 0 END
              , WouldSendAlert         = @SendAlert;

        SELECT  host_name
              , sleeping_connections = COUNT(*)
              , monitored            = MAX(CAST(is_monitored AS int))
        FROM    @Sessions
        GROUP BY host_name
        ORDER BY MAX(CAST(is_monitored AS int)) DESC, COUNT(*) DESC;

        SELECT  date_connected       = CAST(connect_time AS date)
              , sleeping_connections = COUNT(*)
        FROM    @Sessions
        GROUP BY CAST(connect_time AS date)
        ORDER BY date_connected;
        RETURN;
    END;

    IF @SendAlert = 1
    BEGIN
        DECLARE @CaptureText varchar(19) = CONVERT(varchar(19), @CaptureTime, 120);

        /* Table 2: by host (monitored hosts first, then by count) */
        DECLARE @ByHost nvarchar(max) = CAST((
            SELECT  td = host_name, ''
                  , td = COUNT(*), ''
                  , td = CASE WHEN MAX(CAST(is_monitored AS int)) = 1 THEN 'Yes' ELSE 'No' END
            FROM    @Sessions
            GROUP BY host_name
            ORDER BY MAX(CAST(is_monitored AS int)) DESC, COUNT(*) DESC
            FOR XML PATH('tr'), TYPE
        ) AS nvarchar(max));

        /* Table 3: by date the connection was started */
        DECLARE @ByDate nvarchar(max) = CAST((
            SELECT  td = CONVERT(varchar(10), CAST(connect_time AS date), 120), ''
                  , td = COUNT(*)
            FROM    @Sessions
            GROUP BY CAST(connect_time AS date)
            ORDER BY CAST(connect_time AS date)
            FOR XML PATH('tr'), TYPE
        ) AS nvarchar(max));

        DECLARE @Tbl  nvarchar(200) =
            N'<table border="1" cellpadding="4" cellspacing="0" style="border-collapse:collapse;">';
        DECLARE @Head nvarchar(100) = N'<tr style="background:#dde4ee;">';

        DECLARE @Body nvarchar(max) =
              N'<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:10pt;">'
            + N'<h3>Sleeping connections alert on ' + @@SERVERNAME + N'</h3>'
            + N'<p>Sleeping connections from monitored hosts ('
            + CAST(@MonitoredTotal AS nvarchar(20)) + N') exceeded the threshold of '
            + CAST(@Threshold AS nvarchar(20)) + N'.</p>'

            /* Table 1: totals */
            + N'<h4>Total sleeping connections</h4>' + @Tbl
            + @Head + N'<th>Count taken at</th><th>Instance total</th><th>From monitored hosts</th>'
            + N'<th>Holding an open transaction</th><th>Threshold</th></tr>'
            + N'<tr><td>' + @CaptureText + N'</td>'
            + N'<td>' + CAST(@InstanceTotal  AS nvarchar(20)) + N'</td>'
            + N'<td>' + CAST(@MonitoredTotal AS nvarchar(20)) + N'</td>'
            + N'<td>' + CAST(@OpenTranTotal  AS nvarchar(20)) + N'</td>'
            + N'<td>' + CAST(@Threshold      AS nvarchar(20)) + N'</td></tr></table>'

            /* Table 2: by host */
            + N'<h4>Sleeping connections by host</h4>' + @Tbl
            + @Head + N'<th>Host name</th><th>Sleeping connections</th><th>Monitored</th></tr>'
            + ISNULL(@ByHost, N'') + N'</table>'

            /* Table 3: by date connected */
            + N'<h4>Sleeping connections by date connected</h4>' + @Tbl
            + @Head + N'<th>Date connected</th><th>Sleeping connections</th></tr>'
            + ISNULL(@ByDate, N'') + N'</table>'

            + N'<p style="color:#666;">Further alerts are held back for '
            + CAST(@AlertCooldownMinutes AS nvarchar(20))
            + N' minutes while the count stays above the threshold. '
            + N'History: DBA.dbo.SleepingConnectionsLog.</p>'
            + N'</body></html>';

        DECLARE @Subject nvarchar(255) =
              N'ALERT: ' + CAST(@MonitoredTotal AS nvarchar(20)) + N' sleeping connections on '
            + @@SERVERNAME + N' at ' + @CaptureText;

        EXEC msdb.dbo.sp_send_dbmail
              @profile_name = @ProfileName
            , @recipients   = @Recipients
            , @subject      = @Subject
            , @body         = @Body
            , @body_format  = 'HTML';
    END;

    /* Log every run (gives you a trend line and drives the cooldown) */
    INSERT dbo.SleepingConnectionsLog
          (CaptureTime, InstanceTotal, MonitoredTotal, OpenTranTotal, Threshold, AlertSent)
    VALUES (@CaptureTime, @InstanceTotal, @MonitoredTotal, @OpenTranTotal, @Threshold, @SendAlert);

    DELETE dbo.SleepingConnectionsLog
    WHERE  CaptureTime < DATEADD(DAY, -@RetentionDays, @CaptureTime);
END;
GO

/* Quick test without sending mail or logging:
EXEC DBA.dbo.usp_Alert_SleepingConnections
     @HostList = N'APPSRV01,APPSRV02', @Debug = 1;

-- Trend over the last day:
SELECT CaptureTime, InstanceTotal, MonitoredTotal, OpenTranTotal, AlertSent
FROM   DBA.dbo.SleepingConnectionsLog
WHERE  CaptureTime > DATEADD(DAY, -1, SYSDATETIME())
ORDER BY CaptureTime;
*/


/*============================================================================
  Part 3: SQL Agent job
============================================================================*/
USE [msdb];
GO

DECLARE @JobName sysname = N'DBA - Sleeping Connections Alert';
DECLARE @Owner   sysname = SUSER_SNAME(0x01);   -- the sa login, even if it has been renamed
DECLARE @JobId   uniqueidentifier;

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
    EXEC msdb.dbo.sp_delete_job @job_name = @JobName, @delete_unused_schedule = 1;

EXEC msdb.dbo.sp_add_job
      @job_name         = @JobName
    , @enabled          = 1
    , @description      = N'Logs sleeping connection counts and emails an alert when sleeping connections from monitored hosts exceed the threshold.'
    , @category_name    = N'[Uncategorized (Local)]'
    , @owner_login_name = @Owner
    , @job_id           = @JobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
      @job_id            = @JobId
    , @step_name         = N'Check sleeping connections'
    , @subsystem         = N'TSQL'
    , @database_name     = N'DBA'
    , @command           = N'EXEC dbo.usp_Alert_SleepingConnections
      @HostList             = N''APPSRV01,APPSRV02,WEBSRV01''
    , @Threshold            = 100
    , @ProfileName          = N''DBA Mail Profile''
    , @Recipients           = N''dba-team@yourcompany.com''
    , @AlertCooldownMinutes = 60
    , @RetentionDays        = 30;'
    , @on_success_action = 1   -- quit with success
    , @on_fail_action    = 2;  -- quit with failure

EXEC msdb.dbo.sp_add_jobschedule
      @job_id               = @JobId
    , @name                 = N'Every 15 minutes'
    , @enabled              = 1
    , @freq_type            = 4    -- daily
    , @freq_interval        = 1
    , @freq_subday_type     = 4    -- minutes
    , @freq_subday_interval = 15
    , @active_start_time    = 0;

EXEC msdb.dbo.sp_add_jobserver
      @job_id      = @JobId
    , @server_name = N'(local)';
GO
