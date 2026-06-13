-- =============================================================================
-- 06_sql_agent_job.sql
-- Creates a SQL Server Agent job that orchestrates the full ETL pipeline.
-- This serves as both the runtime scheduler and the SSIS-equivalent
-- when SSIS packages are not deployed.
--
-- Job steps (run sequentially, fail-on-error):
--   Step 1 – Extract USGS        (CmdExec: python extract_usgs.py)
--   Step 2 – Extract EMDAT       (CmdExec: python extract_emdat.py)
--   Step 3 – Load DimGeography   (T-SQL: EXEC usp_Load_DimGeography)
--   Step 4 – Load FactSeismic    (T-SQL: EXEC usp_Load_FactSeismic)
--   Step 5 – Load FactDisaster   (T-SQL: EXEC usp_Load_FactDisaster)
--   Step 6 – Build Bridge        (T-SQL: EXEC usp_Build_BridgeDisasterSeismic)
--
-- Schedule: daily at 03:00 (after USGS daily update, before EMDAT weekly)
--
-- Prerequisites:
--   SQL Server Agent service must be running.
--   SQL Server Agent service account must have permission to execute Python.
--   Update @PythonPath to match your installation.
-- =============================================================================

USE msdb;
GO

-- ---------------------------------------------------------------------------
-- Configuration – adjust these two variables before running
-- ---------------------------------------------------------------------------
DECLARE @PythonPath NVARCHAR(500) = N'C:\Users\Mateu\Github\DWH\Geoseismic_Risk_DWH\etl\python';
DECLARE @PythonExe  NVARCHAR(500) = N'python';   -- or full path e.g. C:\Python311\python.exe

-- ---------------------------------------------------------------------------
-- Drop existing job if it exists (safe re-run)
-- ---------------------------------------------------------------------------
IF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name = N'SeismicDisasterDWH_ETL')
BEGIN
    EXEC dbo.sp_delete_job @job_name = N'SeismicDisasterDWH_ETL', @delete_unused_schedule = 1;
END

-- ---------------------------------------------------------------------------
-- Create job
-- ---------------------------------------------------------------------------
DECLARE @JobId UNIQUEIDENTIFIER;

EXEC dbo.sp_add_job
    @job_name       = N'SeismicDisasterDWH_ETL',
    @description    = N'Full ETL pipeline: USGS + EMDAT extraction, dimension and fact loads, bridge matching.',
    @category_name  = N'[Uncategorized (Local)]',
    @owner_login_name = N'sa',
    @enabled        = 1,
    @job_id         = @JobId OUTPUT;

-- ---------------------------------------------------------------------------
-- Step 1: Extract USGS (Python)
-- ---------------------------------------------------------------------------
EXEC dbo.sp_add_jobstep
    @job_id         = @JobId,
    @step_id        = 1,
    @step_name      = N'01_Extract_USGS',
    @subsystem      = N'CmdExec',
    @command        = N'python "$(ESCAPE_SQUOTE(PythonPath))\extract_usgs.py"',
    @on_success_action = 3,   -- go to next step
    @on_fail_action    = 2,   -- quit with failure
    @database_name  = N'master';

-- Replace token with actual path (tokens not supported in CmdExec, so hardcode)
DECLARE @Step1Cmd NVARCHAR(1000) = @PythonExe + N' "' + @PythonPath + N'\extract_usgs.py"';
EXEC dbo.sp_update_jobstep
    @job_id = @JobId, @step_id = 1,
    @command = @Step1Cmd;

-- ---------------------------------------------------------------------------
-- Step 2: Extract EMDAT (Python) – allowed to fail if file not present
-- ---------------------------------------------------------------------------
EXEC dbo.sp_add_jobstep
    @job_id         = @JobId,
    @step_id        = 2,
    @step_name      = N'02_Extract_EMDAT',
    @subsystem      = N'CmdExec',
    @command        = N'placeholder',
    @on_success_action = 3,   -- go to next step
    @on_fail_action    = 3,   -- continue even if EMDAT file missing
    @database_name  = N'master';

DECLARE @Step2Cmd NVARCHAR(1000) = @PythonExe + N' "' + @PythonPath + N'\extract_emdat.py"';
EXEC dbo.sp_update_jobstep
    @job_id = @JobId, @step_id = 2,
    @command = @Step2Cmd;

-- ---------------------------------------------------------------------------
-- Step 3: Load DimGeography
-- ---------------------------------------------------------------------------
EXEC dbo.sp_add_jobstep
    @job_id         = @JobId,
    @step_id        = 3,
    @step_name      = N'03_Load_DimGeography',
    @subsystem      = N'TSQL',
    @command        = N'EXEC dbo.usp_Load_DimGeography;',
    @database_name  = N'SeismicDisasterDWH',
    @on_success_action = 3,
    @on_fail_action    = 2;

-- ---------------------------------------------------------------------------
-- Step 4: Load FactSeismic
-- ---------------------------------------------------------------------------
EXEC dbo.sp_add_jobstep
    @job_id         = @JobId,
    @step_id        = 4,
    @step_name      = N'04_Load_FactSeismic',
    @subsystem      = N'TSQL',
    @command        = N'EXEC dbo.usp_Load_FactSeismic;',
    @database_name  = N'SeismicDisasterDWH',
    @on_success_action = 3,
    @on_fail_action    = 2;

-- ---------------------------------------------------------------------------
-- Step 5: Load FactDisaster
-- ---------------------------------------------------------------------------
EXEC dbo.sp_add_jobstep
    @job_id         = @JobId,
    @step_id        = 5,
    @step_name      = N'05_Load_FactDisaster',
    @subsystem      = N'TSQL',
    @command        = N'EXEC dbo.usp_Load_FactDisaster;',
    @database_name  = N'SeismicDisasterDWH',
    @on_success_action = 3,
    @on_fail_action    = 2;

-- ---------------------------------------------------------------------------
-- Step 6: Build Bridge
-- ---------------------------------------------------------------------------
EXEC dbo.sp_add_jobstep
    @job_id         = @JobId,
    @step_id        = 6,
    @step_name      = N'06_Build_Bridge',
    @subsystem      = N'TSQL',
    @command        = N'EXEC dbo.usp_Build_BridgeDisasterSeismic;',
    @database_name  = N'SeismicDisasterDWH',
    @on_success_action = 1,   -- quit with success
    @on_fail_action    = 2;

-- Set starting step
EXEC dbo.sp_update_job @job_id = @JobId, @start_step_id = 1;

-- ---------------------------------------------------------------------------
-- Schedule: daily at 03:00
-- ---------------------------------------------------------------------------
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
