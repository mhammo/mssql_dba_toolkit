DECLARE @TableName NVARCHAR(200) = 'POS Package';

IF OBJECT_ID('tempdb..#MissingIndexes') IS NOT NULL
	DROP TABLE #MissingIndexes;

IF OBJECT_ID('tempdb..#TableCounts') IS NOT NULL
	DROP TABLE #TableCounts;

WITH a as (
SELECT 
   a.parent_object_id,
   Object_Name(a.parent_object_id) AS Table_Name
   ,b.NAME AS Column_Name
   ,b.column_id
   ,c.schema_id
FROM 
   sys.foreign_key_columns a
   ,sys.all_columns b
   ,sys.objects c
WHERE 
   a.parent_column_id = b.column_id
   AND a.parent_object_id = b.object_id
   AND b.object_id = c.object_id
   AND c.is_ms_shipped = 0
EXCEPT
SELECT 
   a.Object_id,
   Object_name(a.Object_id)
   ,b.NAME
   ,b.column_id
   ,c.schema_id
FROM 
   sys.index_columns a
   ,sys.all_columns b
   ,sys.objects c
WHERE 
   a.object_id = b.object_id
   AND a.key_ordinal = 1
   AND a.column_id = b.column_id
   AND a.object_id = c.object_id
   AND c.is_ms_shipped = 0
)

SELECT 
	a.Table_Name,
	a.Column_Name, 
	OBJECT_NAME(f.referenced_object_id) as [Referenced_Table] 
	INTO #MissingIndexes 
FROM a
	INNER JOIN sys.foreign_key_columns f ON f.parent_object_id = a.parent_object_id AND f.parent_column_id = a.column_id
	INNER JOIN sys.all_columns b ON f.referenced_object_id = b.object_id AND f.referenced_column_id = b.column_id
WHERE SCHEMA_NAME(schema_id) = 'dbo';

CREATE TABLE #TableCounts
(
	Table_Name NVARCHAR(MAX),
	Table_RowCount INT
)

DECLARE @nsql nvarchar(max) = 'INSERT INTO #TableCounts '; 

SELECT @nsql = @nsql + STUFF((SELECT DISTINCT 'UNION SELECT ''' + Table_Name + ''' AS Table_Name, ' 
												+ '(SELECT COUNT(*) FROM ' + QUOTENAME(Table_Name) + ') AS Table_RowCount ' 
					FROM #MissingIndexes
					FOR XML PATH ('')), 1,6,'');

EXEC sp_executesql @nsql;

SELECT DISTINCT *, 
'CREATE NONCLUSTERED INDEX [IDX_' + REPLACE(t.Table_Name, ' ', '_') + '_' + Column_Name + '] ON ' + QUOTENAME(t.Table_Name) + '
(
	' + QUOTENAME(Column_Name) + ' ASC
)'
 FROM #TableCounts t
	INNER JOIN #MissingIndexes m ON m.Table_Name = t.Table_Name
WHERE Table_RowCount > 50;

