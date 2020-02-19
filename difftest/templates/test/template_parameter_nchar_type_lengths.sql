/*
executionMasks:
  a_valid_bitmask: 1

--@myParam1 nvarchar
--@myParam2 nvarchar(13)
--@myParam3 nvarchar(257)
--@myParam4 nvarchar(7003)
--@myParam5 nvarchar
--@myParam6 nvarchar
--@myParam7 nvarchar(max)


*/
  select 
    -- this relies on the knowledge that epiquery prepends a comment to the exeucting query that contains the
    -- template path information. So we're taking everything up to the template path that epi is prepending
    -- thus in the case of a parameterized query (executed via sp_executesql) this first portion will be the param 
    -- declaration
    LEFT(st.text, CHARINDEX('-- ', st.text)-1) queryParamText
  from
    sys.dm_exec_requests as er
    cross apply sys.dm_exec_query_plan(er.plan_handle) as qp
    cross apply sys.dm_exec_sql_text(er.plan_handle) as st
  where 
   session_id = @@spid