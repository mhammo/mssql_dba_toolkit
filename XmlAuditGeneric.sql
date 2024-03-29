ALTER FUNCTION EcorysAPI.GenerateAuditXml (
	@OldXml XML, 
	@NewXml XML, 
	@SchemaName nvarchar(50),
	@TableName nvarchar(50),
	@MaxColumnLength int = 500 --If a column has a text type above this length, don't audit it
)
RETURNS XML
AS
BEGIN
	DECLARE 
		@AuditXml XML,
		@TableId INT,
		@Id nvarchar(50);

	SELECT @TableId = object_id 
		FROM sys.tables t
	WHERE name = @TableName 
		AND SCHEMA_NAME(schema_id) = @SchemaName;

	SELECT @Id = r.value('(.)', 'nvarchar(50)') 
	FROM @OldXml.nodes('*') AS records(r)
		INNER JOIN sys.columns c ON c.name = r.value('fn:local-name(.)', 'nvarchar(50)') AND c.object_id = @TableId
	WHERE is_identity = 1;
	
	;WITH oldValues AS (
		select distinct 
			r.value('fn:local-name(.)', 'nvarchar(50)') as xmlName,
			r.value('(.)', 'nvarchar(50)') as xmlValue
		FROM
			@OldXml.nodes('*') AS records(r)
	)
	,newValues AS (
		select distinct 
			r.value('fn:local-name(.)', 'nvarchar(50)') as xmlName,
			r.value('(.)', 'nvarchar(50)') as xmlValue
		FROM
			@NewXml.nodes('*') AS records(r)
	)
	,columnNames AS (
		SELECT xmlName FROM oldValues
		UNION
		SELECT xmlName FROM newValues
	)
	-- If it's a binary, or over a specific field length, don't audit it
	,invalidColumns AS (
		SELECT o.xmlName FROM columnNames o
			INNER JOIN sys.columns c ON c.name = xmlName AND c.object_id = @TableId
			inner join sys.types t on c.user_type_id = t.user_type_id
		WHERE t.name IN ('varbinary', 'binary', 'image') OR c.max_length > @MaxColumnLength
	)

	SELECT @AuditXml = (SELECT @TableName as [AuditData/@TableName], 
							@Id as [AuditData/@Id], 
							GETDATE() as [AuditData/@AuditDate],
							CASE WHEN @OldXML IS NULL THEN 'INSERT'
								WHEN @NewXml IS NULL THEN 'DELETE'
								ELSE 'UPDATE'
							END AS [AuditData/@Type],
							CAST(CASE WHEN @NewXML IS NOT NULL THEN
										(SELECT n.xmlName as [Column/@ColumnName],		
												o.xmlValue [Column/@OldValue], 
												n.xmlValue [Column/@NewValue] 
										FROM newValues n
											LEFT JOIN oldValues o ON o.xmlName = n.xmlName
											LEFT JOIN invalidColumns i ON i.xmlName = n.xmlName
										WHERE (o.xmlValue != n.xmlValue OR o.xmlValue IS NULL) AND i.xmlName IS NULL
										FOR XML PATH(''))
									ELSE
										(SELECT o.xmlName as [Column/@ColumnName],		
												o.xmlValue [Column/@OldValue]
										FROM oldValues o
											LEFT JOIN invalidColumns i ON i.xmlName = o.xmlName
										WHERE i.xmlName IS NULL
										FOR XML PATH(''))
									END AS XML) as [AuditData]
					FOR XML PATH(''))

	RETURN @AuditXml;
END;
GO

DECLARE @OldXml XML, @NewXml XML, @SchemaName nvarchar(50) = 'EcorysAPI', @TableName nvarchar(50) = 'EmailPersonAudit';

SELECT 
	@OldXml = (SELECT *
			FROM [SKNTrainv67].[EcorysAPI].[EmailPersonAudit]
			WHERE Id = 1
			FOR XML PATH('')),
	@NewXml = (SELECT *
			FROM [SKNTrainv67].[EcorysAPI].[EmailPersonAudit]
			WHERE Id = 25
			FOR XML PATH(''))

SELECT EcorysAPI.GenerateAuditXml(@OldXml, @NewXml, @SchemaName, @TableName, 500)