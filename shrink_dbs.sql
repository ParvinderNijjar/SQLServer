-- Declare variables
DECLARE @DatabaseName NVARCHAR(128);
DECLARE @SQL NVARCHAR(MAX);
DECLARE @TargetSizeMB INT = 10240; -- 10GB in MB

-- Create a cursor to iterate through all user databases
DECLARE db_cursor CURSOR FOR
SELECT name
FROM sys.databases
WHERE database_id > 4 -- Exclude system databases (master, model, msdb, tempdb)
AND state = 0; -- Only online databases

-- Open the cursor
OPEN db_cursor;

-- Fetch the first database name
FETCH NEXT FROM db_cursor INTO @DatabaseName;

-- Loop through all databases
WHILE @@FETCH_STATUS = 0
BEGIN
    -- Generate the shrink command if database size is greater than target
    SET @SQL = '
    DECLARE @CurrentSizeMB INT;
    SELECT @CurrentSizeMB = SUM(size) * 8 / 1024
    FROM ' + QUOTENAME(@DatabaseName) + '.sys.database_files;
    
    IF @CurrentSizeMB > ' + CAST(@TargetSizeMB AS NVARCHAR) + '
    BEGIN
        PRINT ''Shrinking database ' + QUOTENAME(@DatabaseName) + ' to ' + CAST(@TargetSizeMB AS NVARCHAR) + ' MB'';
        DBCC SHRINKDATABASE (N''' + @DatabaseName + ''', ' + CAST(@TargetSizeMB AS NVARCHAR) + ');
    END
    ELSE
    BEGIN
        PRINT ''Database ' + QUOTENAME(@DatabaseName) + ' is already smaller than ' + CAST(@TargetSizeMB AS NVARCHAR) + ' MB'';
    END
    ';
    
    -- Execute the dynamic SQL
    EXEC sp_executesql @SQL;
    
    -- Fetch the next database name
    FETCH NEXT FROM db_cursor INTO @DatabaseName;
END

-- Clean up
CLOSE db_cursor;
DEALLOCATE db_cursor;
