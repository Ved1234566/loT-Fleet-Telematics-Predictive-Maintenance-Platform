-- fleet db setup: integration, stages, raw tables, pipes, streams, and tasks
-- co-authored with coco

use role accountadmin;

create or replace database fleet_db;

create schema fleet_db.setup_schema;

use database fleet_db;
use warehouse compute_wh;

-- note: storage integration is account-level, so it survives "create or replace database".
-- only run this block the first time, or if fleet_s3_int does not already exist.

-- create or replace storage integration fleet_s3_int
-- type = external_stage
-- storage_provider = s3
-- enabled = true
-- storage_aws_role_arn = 'arn:aws:iam::363437154840:role/vehical_snowflake'
-- storage_allowed_locations = ('s3://bigdata1ved/vehical_project_snowflake/');

-- desc integration fleet_s3_int;

create or replace file format fleet_db.setup_schema.csv_format
type = csv
skip_header = 1
field_optionally_enclosed_by = '"';

create or replace file format fleet_db.setup_schema.json_format
type = json
strip_outer_array = false;

create or replace stage fleet_db.setup_schema.vehicles_stage
url = 's3://bigdata1ved/Vehical_project_snowflake/CSV_FILES/'
storage_integration = fleet_s3_int
file_format = fleet_db.setup_schema.csv_format;

create or replace stage fleet_db.setup_schema.telemetry_stage
url = 's3://bigdata1ved/Vehical_project_snowflake/JSON_FILES/'
storage_integration = fleet_s3_int
file_format = fleet_db.setup_schema.json_format;

-- fix: maintenance_stage was referenced but never created
create or replace stage fleet_db.setup_schema.maintenance_stage
url = 's3://bigdata1ved/Vehical_project_snowflake/CSV_FILES/'
storage_integration = fleet_s3_int
file_format = fleet_db.setup_schema.csv_format;

list @fleet_db.setup_schema.vehicles_stage;
list @fleet_db.setup_schema.telemetry_stage;
list @fleet_db.setup_schema.maintenance_stage;

-- ============ raw landing tables ============

create or replace table fleet_db.setup_schema.vehicles (
    vehicle_id string,
    vin string,
    registration_no string,
    make string,
    model string,
    year int,
    depot string,
    status string,
    odometer_km int,
    fuel_type string,
    last_updated date,
    load_ts timestamp_ntz default current_timestamp()
);

create or replace table fleet_db.setup_schema.maintenance (
    work_order_id string,
    vehicle_id string,
    service_date date,
    work_type string,
    technician string,
    labour_hours float,
    parts_cost_inr number,
    downtime_hours float,
    notes string,
    load_ts timestamp_ntz default current_timestamp()
);

create or replace table fleet_db.setup_schema.telemetry_raw (
    data variant,
    load_ts timestamp_ntz default current_timestamp()
);

-- ============ copy into ============

copy into fleet_db.setup_schema.vehicles
(vehicle_id, vin, registration_no, make, model, year, depot, status, odometer_km, fuel_type, last_updated)
from @fleet_db.setup_schema.vehicles_stage
file_format = (format_name = fleet_db.setup_schema.csv_format)
pattern = '.*vehicles_master.*[.]csv'
on_error = 'continue';

copy into fleet_db.setup_schema.telemetry_raw (data)
from @fleet_db.setup_schema.telemetry_stage
file_format = (format_name = fleet_db.setup_schema.json_format)
pattern = '.*telemetry_batch.*[.]json'
on_error = 'continue';

-- fix: maintenance was never actually loaded
copy into fleet_db.setup_schema.maintenance
(work_order_id, vehicle_id, service_date, work_type, technician, labour_hours, parts_cost_inr, downtime_hours, notes)
from @fleet_db.setup_schema.maintenance_stage
file_format = (format_name = fleet_db.setup_schema.csv_format)
pattern = '.*maintenance_log.*[.]csv'
on_error = 'continue';

select count(*) from fleet_db.setup_schema.vehicles;
select count(*) from fleet_db.setup_schema.maintenance;

-- ============ table from raw json ============

-- fix: added gps.lat, gps.lon, coolant_ok, dtc_codes (were missing before)
create or replace table fleet_db.setup_schema.telemetry as
select
    data:vehicle_id::string        as vehicle_id,
    data:event_ts::timestamp_ntz   as event_ts,
    data:gps.lat::float            as gps_lat,
    data:gps.lon::float            as gps_lon,
    data:speed_kmph::float         as speed_kmph,
    data:engine_temp_c::float      as engine_temp_c,
    data:rpm::int                  as rpm,
    data:fuel_pct::float           as fuel_pct,
    data:coolant_ok::boolean       as coolant_ok,
    data:dtc_codes                 as dtc_codes,
    data:harsh_braking::boolean    as harsh_braking
from fleet_db.setup_schema.telemetry_raw;

-- ============ pipes ============

create or replace pipe fleet_db.setup_schema.vehicles_pipe
auto_ingest = true
as
copy into fleet_db.setup_schema.vehicles
(vehicle_id, vin, registration_no, make, model, year, depot, status, odometer_km, fuel_type, last_updated)
from @fleet_db.setup_schema.vehicles_stage
file_format = (format_name = fleet_db.setup_schema.csv_format)
pattern = '.*vehicles_master.*[.]csv';

create or replace pipe fleet_db.setup_schema.telemetry_pipe
auto_ingest = true
as
copy into fleet_db.setup_schema.telemetry_raw (data)
from @fleet_db.setup_schema.telemetry_stage
file_format = (format_name = fleet_db.setup_schema.json_format)
pattern = '.*telemetry_batch.*[.]json';

-- fix: maintenance pipe was missing too, so v2/june loads could never auto-ingest
create or replace pipe fleet_db.setup_schema.maintenance_pipe
auto_ingest = true
as
copy into fleet_db.setup_schema.maintenance
(work_order_id, vehicle_id, service_date, work_type, technician, labour_hours, parts_cost_inr, downtime_hours, notes)
from @fleet_db.setup_schema.maintenance_stage
file_format = (format_name = fleet_db.setup_schema.csv_format)
pattern = '.*maintenance_log.*[.]csv';

-- ============ streams ============

-- fix: stream now points directly at the vehicles table itself instead of a
-- one-time static snapshot (vehicles_raw), which never updated and broke cdc
create or replace stream fleet_db.setup_schema.stream_vehicles
on table fleet_db.setup_schema.vehicles;

create or replace stream fleet_db.setup_schema.stream_telemetry
on table fleet_db.setup_schema.telemetry_raw
append_only = true;

create or replace stream fleet_db.setup_schema.stream_maintenance
on table fleet_db.setup_schema.maintenance;

-- ============ processed tables ============

create or replace table fleet_db.setup_schema.vehicles_processed (
    vehicle_id string,
    vin string,
    registration_no string,
    make string,
    model string,
    year int,
    depot string,
    status string,
    odometer_km int,
    fuel_type string,
    last_updated date
);

create or replace table fleet_db.setup_schema.telemetry_processed (
    vehicle_id string,
    event_ts timestamp_ntz,
    speed_kmph float,
    engine_temp_c float,
    rpm int,
    fuel_pct float,
    harsh_braking boolean
);

create or replace table fleet_db.setup_schema.maintenance_processed (
    work_order_id string,
    vehicle_id string,
    service_date date,
    work_type string,
    technician string,
    labour_hours float,
    parts_cost_inr number,
    downtime_hours float,
    notes string
);

-- ============ tasks ============

-- fix: removed the plain-insert version of vehicles_task that used to sit here.
-- it was dead code -- the "merge" version further down always overwrote it
-- before it was ever resumed, so having both was just confusing.

create or replace task fleet_db.setup_schema.telemetry_task
warehouse = compute_wh
schedule = '5 minute'
as
insert into fleet_db.setup_schema.telemetry_processed
select
    data:vehicle_id::string,
    data:event_ts::timestamp_ntz,
    data:speed_kmph::float,
    data:engine_temp_c::float,
    data:rpm::int,
    data:fuel_pct::float,
    data:harsh_braking::boolean
from fleet_db.setup_schema.stream_telemetry;

create or replace task fleet_db.setup_schema.maintenance_task
warehouse = compute_wh
schedule = '5 minute'
as
insert into fleet_db.setup_schema.maintenance_processed
select work_order_id, vehicle_id, service_date, work_type, technician, labour_hours, parts_cost_inr, downtime_hours, notes
from fleet_db.setup_schema.stream_maintenance;

create or replace task fleet_db.setup_schema.vehicles_task
warehouse = compute_wh
schedule = '5 minute'
as
merge into fleet_db.setup_schema.vehicles_processed as tgt
using
(select vehicle_id, vin, registration_no, make, model, year, depot, status, odometer_km,
    fuel_type, last_updated from fleet_db.setup_schema.stream_vehicles) as src
on tgt.vehicle_id = src.vehicle_id
when matched then
update set
    tgt.vin = src.vin,
    tgt.registration_no = src.registration_no,
    tgt.make = src.make,
    tgt.model = src.model,
    tgt.year = src.year,
    tgt.depot = src.depot,
    tgt.status = src.status,
    tgt.odometer_km = src.odometer_km,
    tgt.fuel_type = src.fuel_type,
    tgt.last_updated = src.last_updated
when not matched then
insert (vehicle_id, vin, registration_no, make, model, year, depot, status, odometer_km, fuel_type, last_updated)
values (src.vehicle_id, src.vin, src.registration_no, src.make, src.model, src.year, src.depot, src.status, src.odometer_km, src.fuel_type, src.last_updated);

alter task fleet_db.setup_schema.vehicles_task suspend;
alter task fleet_db.setup_schema.telemetry_task suspend;
alter task fleet_db.setup_schema.maintenance_task suspend;

alter task fleet_db.setup_schema.vehicles_task resume;
alter task fleet_db.setup_schema.telemetry_task resume;
alter task fleet_db.setup_schema.maintenance_task resume;

-- ============ checks ============

-- note: time travel only works after the table has existed for the requested
-- duration, so this will fail right after a fresh "create or replace database".
-- select *
-- from fleet_db.setup_schema.vehicles
-- at(timestamp => dateadd(minute, -1, current_timestamp()));

select * from fleet_db.setup_schema.vehicles;
select * from fleet_db.setup_schema.maintenance;
select * from fleet_db.setup_schema.telemetry;

-- - 3. how many vehicles per depot
select depot, count(*) as vehicle_count
from fleet_db.setup_schema.vehicles
group by depot
order by vehicle_count desc;

select vehicle_id, round(avg(engine_temp_c),2) as avg_temp, max(speed_kmph) as max_speed
from fleet_db.setup_schema.telemetry
group by vehicle_id
order by avg_temp desc;

select *
from table(information_schema.task_history())
order by scheduled_time desc
limit 20;
