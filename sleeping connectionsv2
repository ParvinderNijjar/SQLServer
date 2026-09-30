/*============================================================================
  Connection monitoring: 5-minute snapshots, throttled warning, daily summary
  --------------------------------------------------------------------------
  Part 1  Tables
          dbo.ConnectionSnapshot        one row per 5-minute run (counts)
          dbo.ConnectionSnapshotDetail  one row per connection per run
  Part 2  dbo.usp_Connections_Collect
          - logs every user connection
          - emails a warning if sleeping connections > @Threshold
          - no more than 1 warning per @AlertCooldownMinutes (60, measured in UTC)
          - only between @AlertStartTime (08:00) and @AlertEndTime (18:00) UK time
  Part 3  dbo.usp_Connections_DailySummary
          - emails yesterday's snapshots: time, sleeping, non-sleeping, total
  Part 4  Agent jobs
          - DBA - Connection Snapshot       every 5 minutes
          - DBA - Connection Daily Summary  daily at 08:00
          (removes the earlier "DBA - Sleeping Connections Alert" job)

  Before running, change:
    - USE [DBA] and @database_name in the job steps -> your admin database
    - @ProfileName / @Recipients in both job steps
    - @HostList in the snapshot job step (NULL = count sleeping from all hosts)
    - @OperatorName in Part 4 (job-failure notifications; skipped if it doesn't exist)

  Time handling
    - Business hours and report days use @TimeZone ('GMT Standard Time' = UK,
      follows BST) regardless of the Windows clock, so a server on UTC still
      warns 08:00-18:00 UK time.
    - The 1-per-hour throttle uses UTC, so the October/March clock changes
      can't double up or suppress warnings.

  Other notes
    - Always On: deploy on every replica, keep the DBA database OUT of the AG.
    - SIMPLE recovery on the DBA database is recommended.
    - Requires SQL Server 2016 SP1+ (CREATE OR ALTER, AT TIME ZONE).
    - Safe to re-run: tables are created/upgraded in place, jobs are recreated.
============================================================================*/

USE [DBA];
GO

/*----------------------------------------------------------------------------
  Part 1: Tables
----------------------------------------------------------------------------*/
IF OBJECT_ID(N'dbo.ConnectionSnapshot', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ConnectionSnapshot
    (
          SnapshotId               int IDENTITY(1,1) NOT NULL
              CONSTRAINT PK_ConnectionSnapshot PRIMARY KEY CLUSTERED
        , CaptureTime              datetime2(0) NOT NULL   -- local (@TimeZone) time
        , TotalConnections         int          NOT NULL
        , SleepingConnections      int          NOT NULL
        , NonSleepingConnections   int          NOT NULL
        , AlertSleepingConnections int          NOT NULL   -- sleeping from @HostList (or all hosts)
        , SleepingWithOpenTran     int          NOT NULL
        , Threshold                int          NOT NULL
        , AlertSent                bit          NOT NULL
              CONSTRAINT DF_ConnectionSnapshot_AlertSent DEFAULT (0)
        , CaptureTimeUtc           datetime2(0) NULL
    );

    CREATE NONCLUSTERED INDEX IX_ConnectionSnapshot_CaptureTime
        ON dbo.ConnectionSnapshot (CaptureTime) INCLUDE (AlertSent);
END;
GO

/* Upgrade a table created by the previous version of this script */
IF COL_LENGTH(N'dbo.ConnectionSnapshot', N'CaptureTimeUtc') IS NULL
    ALTER TABLE dbo.ConnectionSnapshot ADD CaptureTimeUtc datetime2(0) NULL;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID(N'dbo.ConnectionSnapshot')
                 AND name = N'IX_ConnectionSnapshot_CaptureTimeUtc')
    CREATE NONCLUSTERED INDEX IX_ConnectionSnapshot_CaptureTimeUtc
        ON dbo.ConnectionSnapshot (CaptureTimeUtc) INCLUDE (AlertSent);
GO

IF OBJECT_ID(N'dbo.ConnectionSnapshotDetail', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.ConnectionSnapshotDetail
    (
          SnapshotId            int           NOT NULL
        , SessionId             smallint      NOT NULL
        , Status                nvarchar(30)  NOT NULL
        , HostName              nvarchar(128) NULL
        , ProgramName           nvarchar(128) NULL
        , LoginName             nvarchar(128) NULL
        , DatabaseName          nvarchar(128) NULL
        , ClientAddress         varchar(48)   NULL
        , ConnectTime           datetime      NULL
        , LoginTime             datetime      NULL
        , LastRequestStartTime  datetime      NULL
        , LastRequestEndTime    datetime      NULL
        , OpenTranCount         int           NOT NULL
        , IsAlertHost           bit           NOT NULL
        , CONSTRAINT PK_ConnectionSnapshotDetail PRIMARY KEY CLUSTERED (SnapshotId, SessionId)
    );
END;
GO

/*----------------------------------------------------------------------------
  Part 2: Collector + warning email (runs every 5 minutes)
----------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE dbo.usp_Connections_Collect
      @ProfileName            sysname
    , @Recipients             nvarchar(max)
    , @HostList               nvarchar(max) = NULL      -- e.g. N'APPSRV01,APPSRV02'; NULL = all hosts
    , @Threshold              int           = 100       -- warn when sleeping connections are ABOVE this
    , @AlertCooldownMinutes   int           = 60        -- max 1 warning per this many minutes
    , @AlertStartTime         time(0)       = '08:00'   -- warnings only from this time...
    , @AlertEndTime           time(0)       = '18:00'   -- ...up to (not including) this time
    , @TimeZone               sysname       = N'GMT Standard Time'
    , @DetailRetentionDays    int           = 14
    , @SnapshotRetentionDays  int           = 90
    , @Debug                  bit           = 0         -- 1 = show results only: no logging, no email
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /* One instant, expressed two ways */
    DECLARE @Now          datetimeoffset(0) = SYSDATETIMEOFFSET();
    DECLARE @CaptureUtc   datetime2(0)      = CAST(SWITCHOFFSET(@Now, '+00:00') AS datetime2(0));
    DECLARE @CaptureTime  datetime2(0)      = CAST(@Now AT TIME ZONE @TimeZone AS datetime2(0));
    DECLARE @CaptureClock time(0)           = CAST(@CaptureTime AS time(0));

    IF @SnapshotRetentionDays < @DetailRetentionDays
        SET @SnapshotRetentionDays = @DetailRetentionDays;   -- never orphan detail rows

    /* ,HOST1,HOST2,  - matched with CHARINDEX (no STRING_SPLIT / LIKE wildcard issues) */
    DECLARE @HostListNorm nvarchar(max) =
        CASE WHEN NULLIF(LTRIM(RTRIM(@HostList)), N'') IS NULL THEN NULL
             ELSE N',' + REPLACE(REPLACE(REPLACE(REPLACE(@HostList,
                         N' ', N''), NCHAR(9), N''), NCHAR(13), N''), NCHAR(10), N'') + N','
        END;

    /* ---- Snapshot every user connection ---------------------------------- */
    CREATE TABLE #Conn
    (
          SessionId             smallint      NOT NULL PRIMARY KEY
        , Status                nvarchar(30)  NOT NULL
        , HostName              nvarchar(128) NULL
        , ProgramName           nvarchar(128) NULL
        , LoginName             nvarchar(128) NULL
        , DatabaseName          nvarchar(128) NULL
        , ClientAddress         varchar(48)   NULL
        , ConnectTime           datetime      NULL
        , LoginTime             datetime      NULL
        , LastRequestStartTime  datetime      NULL
        , LastRequestEndTime    datetime      NULL
        , OpenTranCount         int           NOT NULL
        , IsAlertHost           bit           NOT NULL
    );

    INSERT #Conn
    SELECT  s.session_id
          , s.status
          , s.host_name
          , s.program_name
          , s.login_name
          , DB_NAME(s.database_id)
          , c.client_net_address
          , COALESCE(c.connect_time, s.login_time)
          , s.login_time
          , s.last_request_start_time
          , s.last_request_end_time
          , s.open_transaction_count
          , CASE WHEN @HostListNorm IS NULL THEN 1
                 WHEN s.host_name IS NOT NULL
                  AND CHARINDEX(N',' + s.host_name + N',', @HostListNorm) > 0 THEN 1
                 ELSE 0 END
    FROM    sys.dm_exec_sessions AS s
    /* One connection row per session. Prefer the physical connection, but fall
       back to a MARS logical connection so MARS sessions keep their details. */
    OUTER APPLY (SELECT TOP (1) ec.connect_time, ec.client_net_address
                 FROM   sys.dm_exec_connections AS ec
                 WHERE  ec.session_id = s.session_id
                 ORDER BY CASE WHEN ec.parent_connection_id IS NULL THEN 0 ELSE 1 END,
                          ec.connect_time) AS c
    WHERE   s.is_user_process = 1
      AND   s.session_id <> @@SPID;                          -- not this job

    DECLARE @Total          int = (SELECT COUNT(*) FROM #Conn);
    DECLARE @Sleeping       int = (SELECT COUNT(*) FROM #Conn WHERE Status = N'sleeping');
    DECLARE @NonSleeping    int = @Total - @Sleeping;
    DECLARE @AlertSleeping  int = (SELECT COUNT(*) FROM #Conn WHERE Status = N'sleeping' AND IsAlertHost = 1);
    DECLARE @OpenTran       int = (SELECT COUNT(*) FROM #Conn WHERE Status = N'sleeping' AND OpenTranCount > 0);

    /* ---- Should a warning go out? ---------------------------------------- */
    DECLARE @InHours     bit = CASE WHEN @CaptureClock >= @AlertStartTime
                                     AND @CaptureClock <  @AlertEndTime THEN 1 ELSE 0 END;
    DECLARE @RecentAlert bit = CASE WHEN EXISTS (
                                        SELECT 1 FROM dbo.ConnectionSnapshot
                                        WHERE  AlertSent = 1
                                          AND  CaptureTimeUtc > DATEADD(MINUTE, -@AlertCooldownMinutes, @CaptureUtc))
                                    THEN 1 ELSE 0 END;
    DECLARE @SendAlert   bit = CASE WHEN @AlertSleeping > @Threshold
                                     AND @InHours = 1
                                     AND @RecentAlert = 0 THEN 1 ELSE 0 END;

    IF @Debug = 1
    BEGIN
        SELECT  CaptureTime            = @CaptureTime
              , CaptureTimeUtc         = @CaptureUtc
              , TotalConnections       = @Total
              , SleepingConnections    = @Sleeping
              , NonSleepingConnections = @NonSleeping
              , AlertSleeping          = @AlertSleeping
              , SleepingWithOpenTran   = @OpenTran
              , Threshold              = @Threshold
              , InAlertHours           = @InHours
              , AlertSentInCooldown    = @RecentAlert
              , WouldSendAlert         = @SendAlert;
        SELECT * FROM #Conn ORDER BY Status, HostName;
        RETURN;
    END;

    /* ---- Log it (committed before any email, so a mail failure never loses data) */
    DECLARE @SnapshotId int;

    BEGIN TRAN;
        INSERT dbo.ConnectionSnapshot
              (CaptureTime, CaptureTimeUtc, TotalConnections, SleepingConnections, NonSleepingConnections,
               AlertSleepingConnections, SleepingWithOpenTran, Threshold, AlertSent)
        VALUES (@CaptureTime, @CaptureUtc, @Total, @Sleeping, @NonSleeping,
                @AlertSleeping, @OpenTran, @Threshold, 0);

        SET @SnapshotId = SCOPE_IDENTITY();

        INSERT dbo.ConnectionSnapshotDetail
              (SnapshotId, SessionId, Status, HostName, ProgramName, LoginName, DatabaseName,
               ClientAddress, ConnectTime, LoginTime, LastRequestStartTime, LastRequestEndTime,
               OpenTranCount, IsAlertHost)
        SELECT @SnapshotId, SessionId, Status, HostName, ProgramName, LoginName, DatabaseName,
               ClientAddress, ConnectTime, LoginTime, LastRequestStartTime, LastRequestEndTime,
               OpenTranCount, IsAlertHost
        FROM   #Conn;
    COMMIT;

    /* ---- Housekeeping (before the email, so a mail failure doesn't stop it) */
    DECLARE @DetailCutoffId int =
        (SELECT MAX(SnapshotId) FROM dbo.ConnectionSnapshot
         WHERE  CaptureTime < DATEADD(DAY, -@DetailRetentionDays, @CaptureTime));
    DECLARE @SnapshotCutoffId int =
        (SELECT MAX(SnapshotId) FROM dbo.ConnectionSnapshot
         WHERE  CaptureTime < DATEADD(DAY, -@SnapshotRetentionDays, @CaptureTime));

    IF @DetailCutoffId IS NOT NULL
        DELETE dbo.ConnectionSnapshotDetail WHERE SnapshotId <= @DetailCutoffId;   -- clustered range seek

    IF @SnapshotCutoffId IS NOT NULL
        DELETE dbo.ConnectionSnapshot WHERE SnapshotId <= @SnapshotCutoffId;

    /* ---- Warning email ---------------------------------------------------- */
    IF @SendAlert = 1
    BEGIN
        DECLARE @CaptureText varchar(19) = CONVERT(varchar(19), @CaptureTime, 120);
        DECLARE @Tbl  nvarchar(200) =
            N'<table border="1" cellpadding="4" cellspacing="0" style="border-collapse:collapse;">';
        DECLARE @Head nvarchar(100) = N'<tr style="background:#dde4ee;">';

        /* Sleeping by host */
        DECLARE @ByHost nvarchar(max) = CAST((
            SELECT  td = ISNULL(NULLIF(HostName, N''), N'(no host name)'), ''
                  , td = COUNT(*), ''
                  , td = CASE WHEN MAX(CAST(IsAlertHost AS int)) = 1 THEN 'Yes' ELSE 'No' END
            FROM    #Conn
            WHERE   Status = N'sleeping'
            GROUP BY ISNULL(NULLIF(HostName, N''), N'(no host name)')
            ORDER BY MAX(CAST(IsAlertHost AS int)) DESC, COUNT(*) DESC
            FOR XML PATH('tr'), TYPE) AS nvarchar(max));

        /* Sleeping by date connected */
        DECLARE @ByDate nvarchar(max) = CAST((
            SELECT  td = CONVERT(varchar(10), CAST(ConnectTime AS date), 120), ''
                  , td = COUNT(*)
            FROM    #Conn
            WHERE   Status = N'sleeping'
            GROUP BY CAST(ConnectTime AS date)
            ORDER BY CAST(ConnectTime AS date)
            FOR XML PATH('tr'), TYPE) AS nvarchar(max));

        DECLARE @Body nvarchar(max) =
              N'<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:10pt;">'
            + N'<h3>Sleeping connections warning on ' + @@SERVERNAME + N'</h3>'
            + N'<p>' + CAST(@AlertSleeping AS nvarchar(20)) + N' sleeping connections'
            + CASE WHEN @HostListNorm IS NULL THEN N'' ELSE N' from monitored hosts' END
            + N' - threshold is ' + CAST(@Threshold AS nvarchar(20)) + N'.</p>'

            + N'<h4>Totals</h4>' + @Tbl
            + @Head + N'<th>Count taken at</th><th>Sleeping (instance)</th>'
            + N'<th>Sleeping (alert hosts)</th><th>Sleeping with open transaction</th>'
            + N'<th>Non-sleeping</th><th>Total connections</th></tr>'
            + N'<tr><td>' + @CaptureText + N'</td>'
            + N'<td>' + CAST(@Sleeping      AS nvarchar(20)) + N'</td>'
            + N'<td>' + CAST(@AlertSleeping AS nvarchar(20)) + N'</td>'
            + N'<td>' + CAST(@OpenTran      AS nvarchar(20)) + N'</td>'
            + N'<td>' + CAST(@NonSleeping   AS nvarchar(20)) + N'</td>'
            + N'<td>' + CAST(@Total         AS nvarchar(20)) + N'</td></tr></table>'

            + N'<h4>Sleeping connections by host</h4>' + @Tbl
            + @Head + N'<th>Host name</th><th>Sleeping connections</th><th>Alert host</th></tr>'
            + ISNULL(@ByHost, N'') + N'</table>'

            + N'<h4>Sleeping connections by date connected</h4>' + @Tbl
            + @Head + N'<th>Date connected</th><th>Sleeping connections</th></tr>'
            + ISNULL(@ByDate, N'') + N'</table>'

            + N'<p style="color:#666;">Max one warning per '
            + CAST(@AlertCooldownMinutes AS nvarchar(20)) + N' minutes, sent only between '
            + CONVERT(varchar(5), @AlertStartTime, 108) + N' and '
            + CONVERT(varchar(5), @AlertEndTime, 108) + N' UK time. Snapshot ID '
            + CAST(@SnapshotId AS nvarchar(20)) + N' in DBA.dbo.ConnectionSnapshotDetail.</p>'
            + N'</body></html>';

        DECLARE @Subject nvarchar(255) =
              N'WARNING: ' + CAST(@AlertSleeping AS nvarchar(20)) + N' sleeping connections on '
            + @@SERVERNAME + N' at ' + @CaptureText;

        /* sp_send_dbmail only QUEUES the mail. A bad profile or recipient fails
           here (job fails, cooldown not started); an SMTP failure happens later
           and shows up in msdb.dbo.sysmail_faileditems - reported in the daily summary. */
        EXEC msdb.dbo.sp_send_dbmail
              @profile_name = @ProfileName
            , @recipients   = @Recipients
            , @subject      = @Subject
            , @body         = @Body
            , @body_format  = 'HTML';

        UPDATE dbo.ConnectionSnapshot SET AlertSent = 1 WHERE SnapshotId = @SnapshotId;
    END;
END;
GO

/*----------------------------------------------------------------------------
  Part 3: Daily summary (runs once a day, reports on the previous UK day)
----------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE dbo.usp_Connections_DailySummary
      @ProfileName  sysname
    , @Recipients   nvarchar(max)
    , @ReportDate   date    = NULL                  -- NULL = yesterday (UK)
    , @TimeZone     sysname = N'GMT Standard Time'
    , @Debug        bit     = 0                     -- 1 = return the data, don't email
AS
BEGIN
    SET NOCOUNT ON;

    SET @ReportDate = ISNULL(@ReportDate,
        DATEADD(DAY, -1, CAST(SYSDATETIMEOFFSET() AT TIME ZONE @TimeZone AS date)));

    DECLARE @From datetime2(0) = CAST(@ReportDate AS datetime2(0));
    DECLARE @To   datetime2(0) = DATEADD(DAY, 1, @From);

    /* 288 normally; 276 / 300 on the clock-change days */
    DECLARE @Expected int =
        DATEDIFF(MINUTE, @From AT TIME ZONE @TimeZone, @To AT TIME ZONE @TimeZone) / 5;

    DECLARE @Snapshots      int
          , @AvgSleeping    int
          , @AvgNonSleeping int
          , @OverThreshold  int
          , @AlertsSent     int;

    SELECT  @Snapshots      = COUNT(*)
          , @AvgSleeping    = AVG(SleepingConnections)
          , @AvgNonSleeping = AVG(NonSleepingConnections)
          , @OverThreshold  = SUM(CASE WHEN AlertSleepingConnections > Threshold THEN 1 ELSE 0 END)
          , @AlertsSent     = SUM(CAST(AlertSent AS int))
    FROM    dbo.ConnectionSnapshot
    WHERE   CaptureTime >= @From AND CaptureTime < @To;

    DECLARE @PeakSleeping int, @PeakTime datetime2(0);
    SELECT TOP (1) @PeakSleeping = SleepingConnections, @PeakTime = CaptureTime
    FROM   dbo.ConnectionSnapshot
    WHERE  CaptureTime >= @From AND CaptureTime < @To
    ORDER BY SleepingConnections DESC, SnapshotId;

    /* Warnings that were queued but that Database Mail failed to deliver */
    DECLARE @FailedMail int =
        (SELECT COUNT(*) FROM msdb.dbo.sysmail_faileditems
         WHERE  send_request_date >= DATEADD(HOUR, -24, GETDATE())
           AND  subject LIKE N'WARNING: % sleeping connections on %');

    IF @Debug = 1
    BEGIN
        SELECT ReportDate = @ReportDate, Snapshots = @Snapshots, ExpectedSnapshots = @Expected,
               PeakSleeping = @PeakSleeping, PeakTime = @PeakTime,
               AvgSleeping = @AvgSleeping, AvgNonSleeping = @AvgNonSleeping,
               SnapshotsOverThreshold = @OverThreshold, WarningsSent = @AlertsSent,
               WarningMailFailures24h = @FailedMail;
        SELECT CaptureTime, SleepingConnections, NonSleepingConnections, TotalConnections,
               AlertSleepingConnections, Threshold, AlertSent
        FROM   dbo.ConnectionSnapshot
        WHERE  CaptureTime >= @From AND CaptureTime < @To
        ORDER BY SnapshotId;
        RETURN;
    END;

    DECLARE @DateText varchar(10) = CONVERT(varchar(10), @ReportDate, 120);
    DECLARE @Tbl  nvarchar(200) =
        N'<table border="1" cellpadding="4" cellspacing="0" style="border-collapse:collapse;">';
    DECLARE @Head nvarchar(100) = N'<tr style="background:#dde4ee;">';
    DECLARE @Body nvarchar(max);

    IF ISNULL(@Snapshots, 0) = 0
    BEGIN
        /* No data at all usually means the snapshot job isn't running - worth knowing */
        SET @Body = N'<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:10pt;">'
                  + N'<h3>Connection summary for ' + @@SERVERNAME + N' - ' + @DateText + N'</h3>'
                  + N'<p style="color:#b00;"><b>No snapshots were recorded for this day.</b> '
                  + N'Check the "DBA - Connection Snapshot" job.</p></body></html>';
    END
    ELSE
    BEGIN
        /* One row per 5-minute snapshot, in true time order (SnapshotId), so the
           repeated 01:00-01:55 hour in October stays in sequence.
           Rows over the warning threshold are shaded. */
        DECLARE @Rows nvarchar(max) = CAST((
            SELECT  [@style] = CASE WHEN AlertSleepingConnections > Threshold
                                    THEN 'background:#fde2e1;' END
                  , td = CONVERT(varchar(5), CAST(CaptureTime AS time), 108), ''
                  , td = SleepingConnections, ''
                  , td = NonSleepingConnections, ''
                  , td = TotalConnections
            FROM    dbo.ConnectionSnapshot
            WHERE   CaptureTime >= @From AND CaptureTime < @To
            ORDER BY SnapshotId
            FOR XML PATH('tr'), TYPE) AS nvarchar(max));

        SET @Body =
              N'<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:10pt;">'
            + N'<h3>Connection summary for ' + @@SERVERNAME + N' - ' + @DateText + N'</h3>'

            + N'<h4>Overview</h4>' + @Tbl
            + N'<tr><td>Peak sleeping connections</td><td>' + CAST(@PeakSleeping AS nvarchar(20))
            + N' at ' + CONVERT(varchar(5), CAST(@PeakTime AS time), 108) + N'</td></tr>'
            + N'<tr><td>Average sleeping</td><td>'     + CAST(@AvgSleeping    AS nvarchar(20)) + N'</td></tr>'
            + N'<tr><td>Average non-sleeping</td><td>' + CAST(@AvgNonSleeping AS nvarchar(20)) + N'</td></tr>'
            + N'<tr><td>Snapshots over threshold</td><td>' + CAST(@OverThreshold AS nvarchar(20)) + N'</td></tr>'
            + N'<tr><td>Warning emails sent</td><td>'  + CAST(@AlertsSent     AS nvarchar(20)) + N'</td></tr>'
            + CASE WHEN @FailedMail > 0
                   THEN N'<tr style="background:#fde2e1;"><td>Warning emails that failed to deliver (last 24h)</td><td>'
                      + CAST(@FailedMail AS nvarchar(20)) + N'</td></tr>'
                   ELSE N'' END
            + CASE WHEN @Snapshots < @Expected
                   THEN N'<tr style="background:#fde2e1;">' ELSE N'<tr>' END
            + N'<td>Snapshots recorded</td><td>' + CAST(@Snapshots AS nvarchar(20))
            + N' of ' + CAST(@Expected AS nvarchar(20)) + N' expected</td></tr></table>'

            + N'<h4>Connections every 5 minutes</h4>'
            + N'<p style="color:#666;">Rows shaded red were over the warning threshold. Times are UK time.</p>'
            + @Tbl
            + @Head + N'<th>Time</th><th>Sleeping</th><th>Non-sleeping</th><th>Total</th></tr>'
            + ISNULL(@Rows, N'') + N'</table>'
            + N'</body></html>';
    END;

    DECLARE @Subject nvarchar(255) =
        N'Daily connection summary: ' + @@SERVERNAME + N' - ' + @DateText;

    EXEC msdb.dbo.sp_send_dbmail
          @profile_name = @ProfileName
        , @recipients   = @Recipients
        , @subject      = @Subject
        , @body         = @Body
        , @body_format  = 'HTML';
END;
GO

/* Tests (no email, no logging):
EXEC DBA.dbo.usp_Connections_Collect
     @ProfileName = N'DBA Mail Profile', @Recipients = N'x', @HostList = N'APPSRV01,APPSRV02', @Debug = 1;

EXEC DBA.dbo.usp_Connections_DailySummary
     @ProfileName = N'DBA Mail Profile', @Recipients = N'x', @ReportDate = '2026-09-30', @Debug = 1;
*/

/* Optional: remove objects from the first version
DROP PROCEDURE IF EXISTS dbo.usp_Alert_SleepingConnections;
DROP TABLE IF EXISTS dbo.SleepingConnectionsLog;
*/


/*============================================================================
  Part 4: Agent jobs
============================================================================*/
USE [msdb];
GO

DECLARE @Owner        sysname = SUSER_SNAME(0x01);   -- sa login by SID, even if renamed
DECLARE @OperatorName sysname = N'DBA Team';         -- emailed if either job fails
DECLARE @JobId        uniqueidentifier;

/* Replace the earlier single-purpose job */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - Sleeping Connections Alert')
    EXEC msdb.dbo.sp_delete_job @job_name = N'DBA - Sleeping Connections Alert', @delete_unused_schedule = 1;

/* ---- Job 1: snapshot every 5 minutes ------------------------------------ */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - Connection Snapshot')
    EXEC msdb.dbo.sp_delete_job @job_name = N'DBA - Connection Snapshot', @delete_unused_schedule = 1;

EXEC msdb.dbo.sp_add_job
      @job_name         = N'DBA - Connection Snapshot'
    , @enabled          = 1
    , @description      = N'Logs all user connections every 5 minutes and sends a throttled warning when sleeping connections exceed the threshold (08:00-18:00 UK, max 1 per hour).'
    , @category_name    = N'[Uncategorized (Local)]'
    , @owner_login_name = @Owner
    , @job_id           = @JobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
      @job_id            = @JobId
    , @step_name         = N'Collect connections'
    , @subsystem         = N'TSQL'
    , @database_name     = N'DBA'
    , @command           = N'EXEC dbo.usp_Connections_Collect
      @ProfileName          = N''DBA Mail Profile''
    , @Recipients           = N''dba-team@yourcompany.com''
    , @HostList             = N''APPSRV01,APPSRV02,WEBSRV01''   -- NULL for all hosts
    , @Threshold            = 100
    , @AlertCooldownMinutes = 60
    , @AlertStartTime       = ''08:00''
    , @AlertEndTime         = ''18:00''
    , @TimeZone             = N''GMT Standard Time'';'
    , @on_success_action = 1
    , @on_fail_action    = 2;

EXEC msdb.dbo.sp_add_jobschedule
      @job_id               = @JobId
    , @name                 = N'Every 5 minutes'
    , @enabled              = 1
    , @freq_type            = 4      -- daily
    , @freq_interval        = 1
    , @freq_subday_type     = 4      -- minutes
    , @freq_subday_interval = 5
    , @active_start_time    = 0;

EXEC msdb.dbo.sp_add_jobserver @job_id = @JobId, @server_name = N'(local)';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = @OperatorName)
    EXEC msdb.dbo.sp_update_job @job_id = @JobId,
         @notify_level_email = 2, @notify_email_operator_name = @OperatorName;   -- on failure

/* ---- Job 2: daily summary at 08:00 -------------------------------------- */
SET @JobId = NULL;

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'DBA - Connection Daily Summary')
    EXEC msdb.dbo.sp_delete_job @job_name = N'DBA - Connection Daily Summary', @delete_unused_schedule = 1;

EXEC msdb.dbo.sp_add_job
      @job_name         = N'DBA - Connection Daily Summary'
    , @enabled          = 1
    , @description      = N'Emails the previous day''s 5-minute connection snapshots (sleeping / non-sleeping).'
    , @category_name    = N'[Uncategorized (Local)]'
    , @owner_login_name = @Owner
    , @job_id           = @JobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
      @job_id            = @JobId
    , @step_name         = N'Send daily summary'
    , @subsystem         = N'TSQL'
    , @database_name     = N'DBA'
    , @command           = N'EXEC dbo.usp_Connections_DailySummary
      @ProfileName = N''DBA Mail Profile''
    , @Recipients  = N''dba-team@yourcompany.com''
    , @TimeZone    = N''GMT Standard Time'';'
    , @on_success_action = 1
    , @on_fail_action    = 2;

EXEC msdb.dbo.sp_add_jobschedule
      @job_id            = @JobId
    , @name              = N'Daily 08:00'
    , @enabled           = 1
    , @freq_type         = 4        -- daily
    , @freq_interval     = 1
    , @freq_subday_type  = 1        -- once at the start time
    , @active_start_time = 80000;   -- 08:00:00 (server clock)

EXEC msdb.dbo.sp_add_jobserver @job_id = @JobId, @server_name = N'(local)';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = @OperatorName)
    EXEC msdb.dbo.sp_update_job @job_id = @JobId,
         @notify_level_email = 2, @notify_email_operator_name = @OperatorName;
GO
