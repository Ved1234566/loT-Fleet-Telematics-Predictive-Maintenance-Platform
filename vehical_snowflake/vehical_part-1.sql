use role accountadmin;

create or replace database fleet_db;

create schema fleet_db.setup_schema;

use database fleet_db;
use warehouse compute_wh;

-- drop integration fleet_s3_int;

create or replace storage integration fleet_s3_int
type = external_stage
storage_provider = s3
enabled = true
storage_aws_role_arn = 'arn:aws:iam::363437154840:role/Vehical_snowflake'
storage_allowed_locations = ('s3://bigdata1ved/Vehical_project_snowflake/');

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


list @fleet_db.setup_schema.vehicles_stage;
list @fleet_db.setup_schema.telemetry_stage;
-- list @fleet_db.setup_schema.maintenance_stage;

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
on_error = 'CONTINUE';


copy into fleet_db.setup_schema.telemetry_raw (data)
from @fleet_db.setup_schema.telemetry_stage
file_format = (format_name = fleet_db.setup_schema.json_format)
pattern = '.*telemetry_batch.*[.]json'
on_error = 'CONTINUE';

select count(*) from fleet_db.setup_schema.vehicles;
select count(*) from fleet_db.setup_schema.maintenance;


-- ============ typed table from raw json ============

create or replace table fleet_db.setup_schema.telemetry as
select
    data:vehicle_id::string as vehicle_id,
    data:event_ts::timestamp_ntz as event_ts,
    data:speed_kmph::float as speed_kmph,
    data:engine_temp_c::float as engine_temp_c,
    data:rpm::int as rpm,
    data:fuel_pct::float as fuel_pct,
    data:harsh_braking::boolean as harsh_braking
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

create or replace table fleet_db.setup_schema.vehicles_raw as
select * from fleet_db.setup_schema.vehicles;

-- ============ streams ============

create or replace stream fleet_db.setup_schema.stream_vehicles
on table fleet_db.setup_schema.vehicles_raw;

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

create or replace task fleet_db.setup_schema.vehicles_task
warehouse = compute_wh
schedule = '5 minute'
as
insert into fleet_db.setup_schema.vehicles_processed
select vehicle_id, vin, registration_no, make, model, year, depot, status, odometer_km, fuel_type, last_updated
from fleet_db.setup_schema.stream_vehicles;

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

alter task fleet_db.setup_schema.vehicles_task suspend;
alter task fleet_db.setup_schema.telemetry_task suspend;
alter task fleet_db.setup_schema.maintenance_task suspend;

alter task fleet_db.setup_schema.vehicles_task resume;
alter task fleet_db.setup_schema.telemetry_task resume;
alter task fleet_db.setup_schema.maintenance_task resume;

-- ============ checks ============

select *
from fleet_db.setup_schema.vehicles
at(timestamp => dateadd(minute, -1, current_timestamp()));


select * from fleet_db.setup_schema.vehicles_raw;
select * from fleet_db.setup_schema.maintenance;
select * from fleet_db.setup_schema.telemetry;

-- vehicles with high downtime
select v.vehicle_id, v.depot, sum(m.downtime_hours) as total_downtime
from fleet_db.setup_schema.vehicles v
join fleet_db.setup_schema.maintenance m on v.vehicle_id = m.vehicle_id
group by v.vehicle_id, v.depot
order by total_downtime desc;
