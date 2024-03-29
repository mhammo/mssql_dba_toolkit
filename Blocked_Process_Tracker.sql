USE [master]
GO
EXEC sp_configure 'show advanced options', 1 ;
GO
RECONFIGURE ;
GO
-- Capture blocks longer than 5 seconds
EXEC sp_configure 'blocked process threshold', '5';
RECONFIGURE
GO
-- Create and startup an extended events session to store the blocked process reports
CREATE EVENT SESSION [blocked_process] ON SERVER 
ADD EVENT sqlserver.blocked_process_report(
    ACTION(sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.client_pid,sqlserver.database_name,sqlserver.session_id)),
ADD EVENT sqlserver.xml_deadlock_report(
    ACTION(sqlserver.client_app_name,sqlserver.client_hostname,sqlserver.client_pid,sqlserver.database_name,sqlserver.server_principal_name,sqlserver.session_id))
ADD TARGET package0.ring_buffer(SET max_memory=(8192))
WITH (MAX_MEMORY=4096 KB,EVENT_RETENTION_MODE=ALLOW_SINGLE_EVENT_LOSS,MAX_DISPATCH_LATENCY=30 SECONDS,MAX_EVENT_SIZE=0 KB,MEMORY_PARTITION_MODE=NONE,TRACK_CAUSALITY=ON,STARTUP_STATE=ON)
GO
-- Create a stored procedure to parse the extended events XML and output a table report
-- An alterred version of the Michael J. Swart's script at https://michaeljswart.com/tag/blocked-process-report/
CREATE PROCEDURE [dbo].[sp_blocks_deadlocks_viewer]
AS
SET NOCOUNT ON

DECLARE @Source nvarchar(max) = 'blocked_process', @Type nvarchar(10) =  'XESESSION';

SELECT XEvent AS DeadlockGraph
FROM (
    SELECT XEvent.query('.') AS XEvent
    FROM (
        SELECT CAST(target_data AS XML) AS TargetData
        FROM sys.dm_xe_session_targets st
        INNER JOIN sys.dm_xe_sessions s ON s.address = st.event_session_address
        WHERE s.NAME = @Source
            AND st.target_name = 'ring_buffer'
        ) AS Data
CROSS APPLY TargetData.nodes('RingBufferTarget/event[@name="xml_deadlock_report"]') AS XEventData(XEvent)
) AS source;

-- Validate @Type
IF (@Type NOT IN ('FILE', 'TABLE', 'XMLFILE', 'XESESSION'))
	RAISERROR ('The @Type parameter must be ''FILE'', ''TABLE'', ''XESESSION'' or ''XMLFILE''', 11, 1)

IF (@Source LIKE '%.trc' AND @Type <> 'FILE')
	RAISERROR ('Warning: You specified a .trc trace. You should also specify @Type = ''FILE''', 10, 1)

IF (@Source LIKE '%.xml' AND @Type <> 'XMLFILE')
	RAISERROR ('Warning: You specified a .xml trace. You should also specify @Type = ''XMLFILE''', 10, 1)

IF (@Type = 'XESESSION' AND NOT EXISTS (
	SELECT * 
	FROM sys.server_event_sessions es
	JOIN sys.server_event_session_targets est
		ON es.event_session_id = est.event_session_id
	WHERE est.name in ('event_file', 'ring_buffer')
	  AND es.name = @Source ) 
)
	RAISERROR ('Warning: The extended event session you supplied does not exist or does not have an "event_file" or "ring_buffer" target.', 10, 1);
		

CREATE TABLE #ReportsXML
(
	monitorloop nvarchar(100) NOT NULL,
	waittime INT NULL,
	endTime datetime NULL,
	blocking_spid INT NOT NULL,
	blocking_ecid INT NOT NULL,
	blocked_spid INT NOT NULL,
	blocked_ecid INT NOT NULL,
	blocked_hierarchy_string as CAST(blocked_spid as varchar(20)) + '.' + CAST(blocked_ecid as varchar(20)) + '/',
	blocking_hierarchy_string as CAST(blocking_spid as varchar(20)) + '.' + CAST(blocking_ecid as varchar(20)) + '/',
	bpReportXml xml not null,
	blocked_sqlhandle nvarchar(200) null,
	blocking_sqlhandle nvarchar(200) null,
	primary key clustered (monitorloop, blocked_spid, blocked_ecid),
	unique nonclustered (monitorloop, blocking_spid, blocking_ecid, blocked_spid, blocked_ecid)
)

DECLARE @SQL NVARCHAR(max);
DECLARE @TableSource nvarchar(max);

	DECLARE @SessionType nvarchar(max);
	DECLARE @SessionId int;
	DECLARE @SessionTargetId int;
	DECLARE @FilenamePattern nvarchar(max);

	SELECT TOP ( 1 ) 
		@SessionType = est.name,
		@SessionId = est.event_session_id,
		@SessionTargetId = est.target_id
	FROM sys.server_event_sessions es
	JOIN sys.server_event_session_targets est
		ON es.event_session_id = est.event_session_id
	WHERE est.name in ('event_file', 'ring_buffer')
		AND es.name = @Source;


		-- get data from ring buffer
		INSERT #ReportsXML(blocked_ecid,blocked_spid,blocking_ecid,blocking_spid,waitTime,
			monitorloop,bpReportXml,endTime,blocked_sqlhandle,blocking_sqlhandle)
		SELECT blocked_ecid,blocked_spid,blocking_ecid,blocking_spid,waitTime,
			COALESCE(CONVERT(nvarchar(100), bpReportEndTime, 120), cast(newid() as nvarchar(100))),
			bpReportXml,bpReportEndTime,blocked_sqlhandle,blocking_sqlhandle
		FROM sys.dm_xe_session_targets st
		JOIN sys.dm_xe_sessions s 
			ON s.address = st.event_session_address
		CROSS APPLY 
			( SELECT CAST(st.target_data AS XML) ) 
			AS TargetData ([xml])
		CROSS APPLY 
			TargetData.[xml].nodes('/RingBufferTarget/event[@name="blocked_process_report"]') 
			AS bpNodes(bpNode)
		CROSS APPLY 
			bpNode.nodes('./data[@name="blocked_process"]/value/blocked-process-report')
			AS bpReportXMLNodes(bpReportXMLNode)
		CROSS APPLY
			(
			  SELECT 
				bpReportXml = CAST(bpReportXMLNode.query('.') as xml),
				bpReportEndTime = bpNode.value('(./@timestamp)[1]', 'datetime'),
				monitorloop = bpReportXMLNode.value('(//@monitorLoop)[1]', 'nvarchar(100)'),
				waitTime = bpReportXMLNode.value('(./blocked-process/process/@waittime)[1]', 'int'),
				blocked_spid = bpReportXMLNode.value('(./blocked-process/process/@spid)[1]', 'int'),
				blocked_ecid = bpReportXMLNode.value('(./blocked-process/process/@ecid)[1]', 'int'),
				blocked_sqlhandle = bpReportXMLNode.value('(./blocked-process/process/executionStack/frame/@sqlhandle)[1]', 'nvarchar(200)'),				
				blocking_spid = bpReportXMLNode.value('(./blocking-process/process/@spid)[1]', 'int'),
				blocking_ecid = bpReportXMLNode.value('(./blocking-process/process/@ecid)[1]', 'int'),
				blocking_sqlhandle = bpReportXMLNode.value('(./blocking-process/process/executionStack/frame/@sqlhandle)[1]', 'nvarchar(200)')
			) AS bpShredded
		WHERE s.name = @Source
		OPTION (MAXDOP 1);


IF OBJECT_ID('tempdb..#sqlhandles') IS NOT NULL
	DROP TABLE #sqlhandles
;WITH handles AS 
(
	SELECT blocking_sqlhandle sqlhandle from #ReportsXML
	UNION
	SELECT blocked_sqlhandle from #ReportsXML
)
SELECT sqlhandle, t.objectid, t.text INTO #sqlhandles from handles
	CROSS APPLY sys.dm_exec_sql_text(CONVERT(varbinary(max),sqlhandle,1)) t

-- Organize and select blocked process reports
;WITH Blockheads AS
(
	SELECT blocking_spid, blocking_ecid, monitorloop, blocking_hierarchy_string, blocking_sqlhandle
	FROM #ReportsXML
	EXCEPT
	SELECT blocked_spid, blocked_ecid, monitorloop, blocked_hierarchy_string, blocked_sqlhandle
	FROM #ReportsXML
), 
Hierarchy AS
(
	SELECT monitorloop, blocking_spid as spid, blocking_ecid as ecid, 
		cast('/' + blocking_hierarchy_string as varchar(max)) as chain,
		0 as level, blocking_sqlhandle sqlhandle
	FROM Blockheads
	
	UNION ALL
	
	SELECT irx.monitorloop, irx.blocked_spid, irx.blocked_ecid,
		cast(h.chain + irx.blocked_hierarchy_string as varchar(max)),
		h.level+1, blocked_sqlhandle sqlhandle
	FROM #ReportsXML irx
	JOIN Hierarchy h
		ON irx.monitorloop = h.monitorloop
		AND irx.blocking_spid = h.spid
		AND irx.blocking_ecid = h.ecid
)
SELECT 
	ISNULL(CONVERT(nvarchar(30), irx.endTime, 120), 
		'Lead') as traceTime,	
	SPACE(4 * h.level) 
		+ CAST(h.spid as varchar(20)) 
		+ CASE h.ecid 
			WHEN 0 THEN ''
			ELSE '(' + CAST(h.ecid as varchar(20)) + ')' 
		END AS blockingTree,
	waittime waitTime,
	irx.bpReportXml,
	t.objectid,
	t.text
from Hierarchy h
left join #ReportsXML irx
	on irx.monitorloop = h.monitorloop
	and irx.blocked_spid = h.spid
	and irx.blocked_ecid = h.ecid
left join #sqlhandles t on t.sqlhandle = h.sqlhandle
order by h.monitorloop desc, h.chain

DROP TABLE #ReportsXML