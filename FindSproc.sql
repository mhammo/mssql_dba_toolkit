SELECT OBJECT_NAME(id) 
    FROM SYSCOMMENTS 
    WHERE [text] LIKE '%WHILE%' 
    GROUP BY OBJECT_NAME(id)


SELECT t.name [Table], c.name [Column] FROM sys.tables t
	INNER JOIN sys.columns c on t.object_id = c.object_id
WHERE c.name like '%_Audit_PersonEmail%'

