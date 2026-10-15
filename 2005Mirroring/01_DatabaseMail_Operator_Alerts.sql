/*
================================================================================
 01_DatabaseMail_Operator_Alerts.sql
 SQL Server 2005 SP4 - run on BOTH mirroring partners (principal and mirror).

 What it does
   1. Enables Database Mail XPs.
   2. Creates a Database Mail account + profile (idempotent).
   3. Points SQL Server Agent at that profile (registry, same as SSMS does).
   4. Creates the DBA operator.
   5. Creates Agent alerts for 3041 (backup failed) and 9002 (log full)
      and wires them to the operator.
   6. Sends a test email.

 AFTER RUNNING: restart the SQL Server Agent service. Agent only picks up
 the Database Mail profile on start-up - until then job failure emails
 silently won't send.

 Edit the values in the CONFIG section only.
================================================================================
*/
SET NOCOUNT ON;

DECLARE @ProfileName    sysname,
        @AccountName    sysname,
        @FromAddress    nvarchar(256),
        @ReplyTo        nvarchar(256),
        @DisplayName    nvarchar(256),
        @SmtpServer     sysname,
        @SmtpPort       int,
        @OperatorName   sysname,
        @OperatorEmail  nvarchar(256),
        @Body           nvarchar(max);

/* ----------------------------- CONFIG ---------------------------------- */
SET @ProfileName   = N'DBA Mail';
SET @AccountName   = N'DBA Mail Account';
SET @FromAddress   = N'sqlserver@yourdomain.local';       -- <<< change
SET @ReplyTo       = N'dba-team@yourdomain.local';        -- <<< change
SET @DisplayName   = N'SQL Server ' + @@SERVERNAME;
SET @SmtpServer    = N'smtp.yourdomain.local';            -- <<< change
SET @SmtpPort      = 25;
SET @OperatorName  = N'DBA Team';
SET @OperatorEmail = N'dba-team@yourdomain.local';        -- <<< change (; separated for several)
/* ----------------------------------------------------------------------- */

/* 1. Enable Database Mail XPs */
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'Database Mail XPs', 1;     RECONFIGURE;

/* Database Mail rides on Service Broker in msdb. If it is off, mail just sits
   in the queue as 'unsent' with no error anywhere - including every alert
   these scripts set up. Enabling it needs SQL Agent stopped (exclusive
   access to msdb):  ALTER DATABASE msdb SET ENABLE_BROKER; */
IF (SELECT is_broker_enabled FROM sys.databases WHERE name = N'msdb') = 0
BEGIN
    RAISERROR('Service Broker is DISABLED in msdb - Database Mail will queue but never send. Stop SQL Agent, run ALTER DATABASE msdb SET ENABLE_BROKER; start Agent, then re-run this script.', 16, 1);
    RETURN;
END

/* 2. Account + profile */
IF NOT EXISTS (SELECT * FROM msdb.dbo.sysmail_account WHERE name = @AccountName)
    EXEC msdb.dbo.sysmail_add_account_sp
         @account_name    = @AccountName,
         @email_address   = @FromAddress,
         @replyto_address = @ReplyTo,
         @display_name    = @DisplayName,
         @mailserver_name = @SmtpServer,
         @port            = @SmtpPort;

IF NOT EXISTS (SELECT * FROM msdb.dbo.sysmail_profile WHERE name = @ProfileName)
    EXEC msdb.dbo.sysmail_add_profile_sp
         @profile_name = @ProfileName,
         @description  = N'Profile used by SQL Agent for DBA alerts';

IF NOT EXISTS (SELECT *
               FROM msdb.dbo.sysmail_profileaccount pa
               JOIN msdb.dbo.sysmail_profile p ON p.profile_id = pa.profile_id
               JOIN msdb.dbo.sysmail_account a ON a.account_id = pa.account_id
               WHERE p.name = @ProfileName AND a.name = @AccountName)
    EXEC msdb.dbo.sysmail_add_profileaccount_sp
         @profile_name    = @ProfileName,
         @account_name    = @AccountName,
         @sequence_number = 1;

/* 3. Tell SQL Agent to use Database Mail with this profile (needs Agent restart) */
EXEC master.dbo.xp_instance_regwrite
     N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
     N'UseDatabaseMail', N'REG_DWORD', 1;
EXEC master.dbo.xp_instance_regwrite
     N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
     N'DatabaseMailProfile', N'REG_SZ', @ProfileName;

/* 4. Operator */
IF NOT EXISTS (SELECT * FROM msdb.dbo.sysoperators WHERE name = @OperatorName)
    EXEC msdb.dbo.sp_add_operator
         @name          = @OperatorName,
         @enabled       = 1,
         @email_address = @OperatorEmail;
ELSE
    EXEC msdb.dbo.sp_update_operator
         @name          = @OperatorName,
         @email_address = @OperatorEmail;

/* 5. Agent alerts: 3041 = BACKUP failed, 9002 = transaction log full.
      9002 matters more now: if log backups stop, the log grows until full. */
IF NOT EXISTS (SELECT * FROM msdb.dbo.sysalerts WHERE name = N'Error 3041 - Backup failed')
BEGIN
    EXEC msdb.dbo.sp_add_alert
         @name = N'Error 3041 - Backup failed',
         @message_id = 3041, @severity = 0, @enabled = 1,
         @delay_between_responses = 300,
         @include_event_description_in = 1;
    EXEC msdb.dbo.sp_add_notification
         @alert_name = N'Error 3041 - Backup failed',
         @operator_name = @OperatorName, @notification_method = 1;
END

IF NOT EXISTS (SELECT * FROM msdb.dbo.sysalerts WHERE name = N'Error 9002 - Transaction log full')
BEGIN
    EXEC msdb.dbo.sp_add_alert
         @name = N'Error 9002 - Transaction log full',
         @message_id = 9002, @severity = 0, @enabled = 1,
         @delay_between_responses = 900,
         @include_event_description_in = 1;
    EXEC msdb.dbo.sp_add_notification
         @alert_name = N'Error 9002 - Transaction log full',
         @operator_name = @OperatorName, @notification_method = 1;
END

/* 6. Test mail (Database Mail itself - does not prove Agent is wired up;
      the Agent restart + a deliberately failed test job proves that) */
SET @Body = N'Database Mail test from ' + @@SERVERNAME + N' at ' + CONVERT(nvarchar(19), GETDATE(), 120);
EXEC msdb.dbo.sp_send_dbmail
     @profile_name = @ProfileName,
     @recipients   = @OperatorEmail,
     @subject      = N'Database Mail test',
     @body         = @Body;

PRINT 'Done. Now RESTART the SQL Server Agent service on ' + @@SERVERNAME + '.';
PRINT 'Check delivery: SELECT TOP 20 * FROM msdb.dbo.sysmail_event_log ORDER BY log_date DESC;';
