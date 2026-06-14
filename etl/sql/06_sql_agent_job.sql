-- 06_sql_agent_job.sql
-- Creates a SQL Server Agent job that runs ETL_Pipeline.dtsx via dtexec daily
-- at 03:00. Requires SQL Server Agent running with permission to call dtexec
-- and the Python interpreter; update @DtsxPath if the project moves.

USE msdb;
GO

-- Configuration
DECLARE @DtsxPath NVARCHAR(500) = N'C:\Users\Mateu\Github\DWH\Geoseismic_Risk_DWH\etl\ssis\SeismicDisasterDWH_ETL\SeismicDisasterDWH_ETL\ETL_Pipeline.dtsx';

-- Drop existing job if it exists (safe re-run)
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'SeismicDisasterDWH_ETL')
BEGIN
    EXEC dbo.sp_delete_job @job_name = N'SeismicDisasterDWH_ETL', @delete_unused_schedule = 1;
END

-- Create job
DECLARE @JobId UNIQUEIDENTIFIER;

EXEC dbo.sp_add_job
    @job_name       = N'SeismicDisasterDWH_ETL',
    @description    = N'Runs ETL_Pipeline.dtsx (USGS + EMDAT extraction, dimension and fact loads, bridge matching).',
    @category_name  = N'[Uncategorized (Local)]',
    @owner_login_name = N'sa',
    @enabled        = 1,
    @job_id         = @JobId OUTPUT;

-- Step 1: Run SSIS package
DECLARE @Step1Cmd NVARCHAR(1000) = N'dtexec /F "' + @DtsxPath + N'"';

EXEC dbo.sp_add_jobstep
    @job_id         = @JobId,
    @step_id        = 1,
    @step_name      = N'01_Run_ETL_Pipeline',
    @subsystem      = N'CmdExec',
    @command        = @Step1Cmd,
    @on_success_action = 1,   -- quit with success
    @on_fail_action    = 2,   -- quit with failure
    @database_name  = N'master';

-- Set starting step
EXEC dbo.sp_update_job @job_id = @JobId, @start_step_id = 1;

-- Schedule: daily at 03:00
EXEC dbo.sp_add_schedule
    @schedule_name      = N'SeismicETL_Daily_0300',
    @freq_type          = 4,       -- daily
    @freq_interval      = 1,
    @active_start_time  = 030000;  -- 03:00:00

EXEC dbo.sp_attach_schedule @job_id = @JobId, @schedule_name = N'SeismicETL_Daily_0300';

EXEC dbo.sp_add_jobserver @job_id = @JobId, @server_name = N'(local)';

PRINT N'SQL Agent job "SeismicDisasterDWH_ETL" created successfully.';
PRINT N'Manual run: EXEC msdb.dbo.sp_start_job @job_name = N''SeismicDisasterDWH_ETL'';';
GO
