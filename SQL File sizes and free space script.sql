use master
go
declare @dbname
sysname
set @dbname = null
if @dbname
is not null and @dbname
not in (select name from
master.dbo.sysdatabases)

begin

raiserror('You''re just one step away
from the results. please verify the database name is correct and try again. www.sqlServer-Training.com', 16,1)
end
set nocount on
if exists (select * from sysobjects where name = '#sizeinfo' and type = 'u')

drop table #sizeinfo
create table #sizeinfo
(
db_name varchar(100) not null primary key clustered,
total dec (7, 1),
data dec (7, 1),
data_used dec (7, 1),
[data (%)] dec (7, 1),
data_free dec (7, 1),
[data_free (%)]
dec (7, 1),
log dec (7, 1),
log_used dec (7, 1),
[log (%)] dec (7, 1),
log_free dec (7, 1),
[log_free (%)]
dec (7, 1),
status dec (7, 1)
)
set nocount on
insert
#sizeinfo ( db_name, log, [log (%)] , status
) exec ('dbcc sqlperf(logspace)
with no_infomsgs')
print '' print ''
if @dbname
is null

declare dbname cursor for select name from master.dbo.sysdatabases where
not status
& 32 = 32
and not status & 512
= 512 order
by name asc
else if @dbname is not null
begin
delete from
#sizeinfo where db_name <>
@dbname

declare dbname cursor for select name from master.dbo.sysdatabases where
not status
& 32 = 32
and not status & 512
= 512 and
name =
@dbname
end
open
dbname
fetch next from dbname
into @dbname
while @@fetch_status = 0
begin
----- adding .0 at the end of interger to avoid divide by zero error

exec ( ' use [' + @dbname
+ '] declare @total dec(7,1),
@data dec (7, 1),
@data_used dec (7, 1),
@data_percent dec (7, 1),
@data_free dec (7, 1),
@data_free_percent dec (7, 1),
@log dec (7, 1),
@log_used dec (7, 1),
@log_used_percent dec (7, 1),
@log_free dec (7, 1),
@log_free_percent dec (7, 1)
set @total = (select sum(convert(dec(15),size)) from sysfiles) * 8192.0 /1048576.0
set @data = (select sum(size) from sysfiles where (status & 64 = 0))* 8192.0 / 1048576.0
set @data_used = (select sum(convert(dec(15),reserved)) from sysindexes
where indid in (0, 1, 255)) * 8192.0 / 1048576.0
set
@data_percent = (@data_used * 100.0 / @data)
set @data_free = (@data - @data_used)
set @data_free_percent = (@data_free * 100.0 / @data
)
set @log = (select log from #sizeinfo where db_name = '''+@dbname+''')
set @log_used_percent = (select [log (%)] from #sizeinfo where db_name ='''+@dbname+''')
set @log_used = @log * @log_used_percent / 100.0
set @log_free = @log - @log_used
set @log_free_percent =@log_free * 100.0 / @log
update #sizeinfo set total = @total,

data = @data ,
data_used = @data_used,
[data (%)] = @data_percent,
data_free = @data_free,
[data_free (%)] = @data_free_percent,
log_used = @log_used,
log_free = @log_free,
[log_free (%)] = @log_free_percent
where db_name = '''+@dbname+'''' )

fetch next from dbname
into @dbname
end
close
dbname
deallocate
dbname
if ((select count(*) from #sizeinfo
) <> 1)
select @@servername as
'ServerName',db_name, total, data, data_used, [data (%)], data_free, [data_free (%)],
log,
log_used, [log (%)], log_free,
[log_free (%)]

from #sizeinfo order by db_name asc
else
select @@servername as
'ServerName',db_name, total, data, data_used, [data (%)], data_free, [data_free (%)],
log,
log_used, [log (%)], log_free,
[log_free (%)]

from #sizeinfo
drop table #sizeinfo