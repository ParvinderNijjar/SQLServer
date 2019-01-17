UPDATE Catalog
SET Hidden = 1
WHERE ItemID IN
(
SELECT ItemID
FROM Catalog
WHERE Path like '/Example/directory/SQL2005/%'
AND 
( Type IN (2,5) OR Type In (1) AND [Name] = 'DataSources')
AND [Name] <> 'performance_dashboard_main'
)
