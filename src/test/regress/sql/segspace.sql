--
-- Tests the spill files disk space accounting mechanism
--

-- check segspace before test
reset statement_mem;
select max(bytes) as max, min(bytes) as min from gp_toolkit.gp_workfile_mgr_used_diskspace;

--- create and populate the table

DROP TABLE IF EXISTS segspace_test_hj_skew;
CREATE TABLE segspace_test_hj_skew (i1 int, i2 int, i3 int, i4 int, i5 int, i6 int, i7 int, i8 int) DISTRIBUTED BY (i1);

set gp_autostats_mode = none;

-- many values with i1 = 1
INSERT INTO segspace_test_hj_skew SELECT 1,i,i,i,i,i,i,i FROM 
	(select generate_series(1, nsegments * 50000) as i from 
	(select count(*) as nsegments from gp_segment_configuration where role='p' and content >= 0) foo) bar;
-- some nicely distributed values
INSERT INTO segspace_test_hj_skew SELECT i,i,i,i,i,i,i,i FROM 
	(select generate_series(1, nsegments * 100000) as i from 
	(select count(*) as nsegments from gp_segment_configuration where role='p' and content >= 0) foo) bar;

ANALYZE segspace_test_hj_skew;

--
--  Testing that query cancelation during spilling updates the accounting
--

------------ Interrupting SELECT query that spills -------------------

-- enable the fault injector
--start_ignore
\! gpfaultinjector -f exec_hashjoin_new_batch -y reset --seg_dbid 2
\! gpfaultinjector -f exec_hashjoin_new_batch -y interrupt --seg_dbid 2
--end_ignore

set gp_workfile_type_hashjoin=buffile;
set statement_mem=2048;
set gp_autostats_mode = none;
set gp_hashjoin_metadata_memory_percent=0;

begin;
SELECT t1.* FROM segspace_test_hj_skew AS t1, segspace_test_hj_skew AS t2 WHERE t1.i1=t2.i2;
rollback;

-- check used segspace after test
select max(bytes) as max, min(bytes) as min from gp_toolkit.gp_workfile_mgr_used_diskspace;

-- Run the test without fault injection
begin;
-- Doing select count so output file doesn't have 75000 rows.
select count(*) from 
(SELECT t1.* FROM segspace_test_hj_skew AS t1, segspace_test_hj_skew AS t2 WHERE t1.i1=t2.i2) temp;
rollback;

-- check used segspace after test
reset statement_mem;
select max(bytes) as max, min(bytes) as min from gp_toolkit.gp_workfile_mgr_used_diskspace;


------------ Interrupting INSERT INTO query that spills -------------------

drop table if exists segspace_t1_created;
create table segspace_t1_created (i1 int, i2 int, i3 int, i4 int, i5 int, i6 int, i7 int, i8 int) DISTRIBUTED BY (i1);

set gp_workfile_type_hashjoin=buffile;
set statement_mem=2048;
set gp_autostats_mode = none;
set gp_hashjoin_metadata_memory_percent=0;

-- enable the fault injector
--start_ignore
\! gpfaultinjector -f exec_hashjoin_new_batch -y reset --seg_dbid 2
\! gpfaultinjector -f exec_hashjoin_new_batch -y interrupt --seg_dbid 2
--end_ignore

begin;

insert into segspace_t1_created
SELECT t1.* FROM segspace_test_hj_skew AS t1, segspace_test_hj_skew AS t2 WHERE t1.i1=t2.i2;

rollback;

-- check used segspace after test
select max(bytes) as max, min(bytes) as min from gp_toolkit.gp_workfile_mgr_used_diskspace;

-- Run the test without fault injection
begin;

insert into segspace_t1_created
SELECT t1.* FROM segspace_test_hj_skew AS t1, segspace_test_hj_skew AS t2 WHERE t1.i1=t2.i2;

rollback;

-- check used segspace after test
reset statement_mem;
select max(bytes) as max, min(bytes) as min from gp_toolkit.gp_workfile_mgr_used_diskspace;

--start_ignore
drop table if exists segspace_t1_created;
--end_ignore

------------ Interrupting CREATE TABLE AS query that spills -------------------

drop table if exists segspace_t1_created;
set gp_workfile_type_hashjoin=buffile;
set statement_mem=2048;
set gp_autostats_mode = none;
set gp_hashjoin_metadata_memory_percent=0;

-- enable the fault injector
--start_ignore
\! gpfaultinjector -f exec_hashjoin_new_batch -y reset --seg_dbid 2
\! gpfaultinjector -f exec_hashjoin_new_batch -y interrupt --seg_dbid 2
--end_ignore

begin;

create table segspace_t1_created AS
SELECT t1.* FROM segspace_test_hj_skew AS t1, segspace_test_hj_skew AS t2 WHERE t1.i1=t2.i2;

rollback;

-- check used segspace after test
select max(bytes) as max, min(bytes) as min from gp_toolkit.gp_workfile_mgr_used_diskspace;

-- Run the test without fault injection
begin;

create table segspace_t1_created AS
SELECT t1.* FROM segspace_test_hj_skew AS t1, segspace_test_hj_skew AS t2 WHERE t1.i1=t2.i2;

rollback;

-- check used segspace after test
reset statement_mem;
select max(bytes) as max, min(bytes) as min from gp_toolkit.gp_workfile_mgr_used_diskspace;


------------ workfile_limit_per_segment leak check during ERROR on UPDATE with CTE and MK_SORT -------------------

drop table if exists testsisc;
drop table if exists foo;

create table testsisc (i1 int, i2 int, i3 int, i4 int);
insert into testsisc select i, i % 1000, i % 100000, i % 75 from
	(select generate_series(1, nsegments * 100000) as i from
	(select count(*) as nsegments from gp_segment_configuration where role='p' and content >= 0) foo) bar;

create table foo (i int, j int);

set statement_mem=1024; -- 1mb for 3 segment to get leak.
set gp_resqueue_print_operator_memory_limits=on;
set gp_enable_mk_sort=on;
set gp_cte_sharing=on;

-- enable the fault injector
--start_ignore
\! gpfaultinjector -f workfile_write_failure -y reset --seg_dbid 2
\! gpfaultinjector -f workfile_write_failure -y error --seg_dbid 2
--end_ignore

-- LEAK in UPDATE: update with sisc xslice sort
update foo set j=m.cc1 from (
  with ctesisc as
    (select * from testsisc order by i2)
  select t1.i1 as cc1, t1.i2 as cc2
  from ctesisc as t1, ctesisc as t2
  where t1.i1 = t2.i2 ) as m;

select max(bytes) as max, min(bytes) as min from gp_toolkit.gp_workfile_mgr_used_diskspace;

-- Run the test without fault injection
-- LEAK in UPDATE: update with sisc xslice sort
update foo set j=m.cc1 from (
  with ctesisc as
    (select * from testsisc order by i2)
  select t1.i1 as cc1, t1.i2 as cc2
  from ctesisc as t1, ctesisc as t2
  where t1.i1 = t2.i2 ) as m;
  
select max(bytes) as max, min(bytes) as min from gp_toolkit.gp_workfile_mgr_used_diskspace;

reset statement_mem;
reset gp_resqueue_print_operator_memory_limits;
reset gp_enable_mk_sort;
reset gp_cte_sharing;

------------ workfile_limit_per_segment leak check during ERROR on DELETE with APPEND-ONLY table -------------------

drop table if exists testsisc;
drop table if exists foo;

create table testsisc (i1 int, i2 int, i3 int, i4 int) WITH (appendonly=true, compresstype=zlib) ;
insert into testsisc select i, i % 1000, i % 100000, i % 75 from
    (select generate_series(1, nsegments * 100000) as i from
	(select count(*) as nsegments from gp_segment_configuration where role='p' and content >= 0) foo) bar;

create table foo (i int, j int) WITH (appendonly=true, compresstype=zlib);
insert into foo select i, i % 1000 from
    (select generate_series(1, nsegments * 100000) as i from
	(select count(*) as nsegments from gp_segment_configuration where role='p' and content >= 0) foo) bar;


set statement_mem=1024; -- 1mb for 3 segment to get leak.

-- enable the fault injector
--start_ignore
\! gpfaultinjector -f workfile_write_failure -y reset --seg_dbid 2
\! gpfaultinjector -f workfile_write_failure -y error --seg_dbid 2
--end_ignore

-- LEAK in DELETE with APPEND ONLY tables
delete from testsisc using (
  select *
  from foo
) src  where testsisc.i1 = src.i;

select max(bytes) as max, min(bytes) as min from gp_toolkit.gp_workfile_mgr_used_diskspace;

-- Run the test without fault injection
-- LEAK in DELETE with APPEND ONLY tables
delete from testsisc using (
  select *
  from foo
) src  where testsisc.i1 = src.i;

reset statement_mem;
select max(bytes) as max, min(bytes) as min from gp_toolkit.gp_workfile_mgr_used_diskspace;

------------ workfile_limit_per_segment leak check during UPDATE of SORT -------------------

drop table if exists testsort;
create table testsort (i1 int, i2 int, i3 int, i4 int);
insert into testsort select i, i % 1000, i % 100000, i % 75 from generate_series(0,1000000) i;

set statement_mem="1MB";
set gp_enable_mk_sort=off;

drop table if exists foo;
create table foo (c int, d int);

-- enable the fault injector
--start_ignore
\! gpfaultinjector -f workfile_write_failure -y reset --seg_dbid 2
\! gpfaultinjector -f workfile_write_failure -y error --seg_dbid 2
--end_ignore

-- expect to see leak if we hit error
update foo set d = i1 from (select i1,i2 from testsort order by i2) x;

-- check counter leak
select max(bytes) as max, min(bytes) as min from gp_toolkit.gp_workfile_mgr_used_diskspace;

-- Run the test without fault injection
-- expect to see leak if we hit error
update foo set d = i1 from (select i1,i2 from testsort order by i2) x;

-- check counter leak
select max(bytes) as max, min(bytes) as min from gp_toolkit.gp_workfile_mgr_used_diskspace;

------------ workfile_limit_per_segment leak check during UPDATE of SHARE_SORT_XSLICE -------------------

drop table if exists testsisc;
create table testsisc (i1 int, i2 int, i3 int, i4 int);
insert into testsisc select i, i % 1000, i % 100000, i % 75 from generate_series(0,1000000) i;

set statement_mem="1MB";
set gp_enable_mk_sort=off;
set gp_cte_sharing=on;

drop table if exists foo;
create table foo (c int, d int);
-- expect to see leak if we hit error

-- enable the fault injector
--start_ignore
\! gpfaultinjector -f workfile_write_failure -y reset --seg_dbid 2
\! gpfaultinjector -f workfile_write_failure -y error --seg_dbid 2
--end_ignore

update foo set d = i1 from (with ctesisc as (select * from testsisc order by i2)
select * from
(select count(*) from ctesisc) x(a), ctesisc
where x.a = ctesisc.i1) y;

-- check counter leak
select max(bytes) as max, min(bytes) as min from gp_toolkit.gp_workfile_mgr_used_diskspace;

-- Run the test without fault injection
update foo set d = i1 from (with ctesisc as (select * from testsisc order by i2)
select * from
(select count(*) from ctesisc) x(a), ctesisc
where x.a = ctesisc.i1) y;

-- check counter leak
select max(bytes) as max, min(bytes) as min from gp_toolkit.gp_workfile_mgr_used_diskspace;

