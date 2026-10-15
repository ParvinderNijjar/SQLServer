/*
================================================================================
 05_Enable_Health_Check.sql
 SQL Server 2005 SP4 - run on BOTH partners after 04, once the first native
 full backups have finished (check Job Activity Monitor).

 Runs the health check without email. If it comes back clean, enables the
 hourly 'DBA - Backup Health Check' schedule. If not, it lists the issues
 and leaves the schedule off - fix them (or wait for the fulls / for
 Commvault-era backups to drop out of the 70-minute non-native window) and
 run this again.

 On the mirror server only system databases are checked, so it should
 enable straight away.
================================================================================
*/
SET NOCOUNT ON;

DECLARE @IssueCount int,
        @Force      char(1),
        @ScheduleId int;

/* ----------------------------- CONFIG ---------------------------------- */
SET @Force = 'N';   -- 'Y' enables the schedule even if issues remain
/* ----------------------------------------------------------------------- */

EXEC master.dbo.usp_CheckBackupHealth @SendEmail = 0, @IssueCount = @IssueCount OUTPUT;

IF @IssueCount > 0 AND @Force <> 'Y'
BEGIN
    PRINT CAST(@IssueCount AS varchar(10)) + ' issue(s) listed in the results grid. Schedule NOT enabled.';
    PRINT 'Fix them (usually: wait for the initial FULL job to finish) and run this script again.';
    RETURN;
END

SELECT @ScheduleId = s.schedule_id
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobschedules js ON js.job_id = j.job_id
JOIN msdb.dbo.sysschedules s     ON s.schedule_id = js.schedule_id
WHERE j.name = N'DBA - Backup Health Check';

IF @ScheduleId IS NULL
BEGIN
    RAISERROR('Health check job or schedule not found - run 03_Backup_Health_Check.sql.', 16, 1);
    RETURN;
END

EXEC msdb.dbo.sp_update_schedule @schedule_id = @ScheduleId, @enabled = 1;
EXEC msdb.dbo.sp_update_job @job_name = N'DBA - Backup Health Check', @enabled = 1;

PRINT 'Hourly backup health check enabled on ' + @@SERVERNAME + '.';
