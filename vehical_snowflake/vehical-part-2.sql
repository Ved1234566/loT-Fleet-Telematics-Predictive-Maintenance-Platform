use role accountadmin;

use database fleet_db;
use warehouse compute_wh;

-- CPA - 1 
create or replace table fleet_db.setup_schema.vehicle_health as
select vehicle_id,avg(speed_kmph) avg_speed,avg(engine_temp_c) avg_engine_temp,avg(fuel_pct) avg_fuel
from fleet_db.setup_schema.telemetry_processed
group by vehicle_id;

-- CPA - 2
create or replace table fleet_db.setup_schema.health_score as
select vehicle_id,avg_engine_temp,avg_fuel,
case 
    when avg_engine_temp>95 then 'high risk'
    when avg_engine_temp>85 then 'medium risk'
    else 'healthy' 
    end as risk_band
    from fleet_db.setup_schema.vehicle_health;

-- CPA - 3 
create or replace table fleet_db.setup_schema.fleet_summary as
select depot,count(*) total_vehicles,avg(odometer_km) avg_odometer
from fleet_db.setup_schema.vehicles_processed
group by depot;

-- JOIN

create or replace view fleet_db.setup_schema.v_fleet_dashboard as
select h.avg_engine_temp,h.avg_fuel,s.risk_band
from fleet_db.setup_schema.vehicles_processed as v
left join fleet_db.setup_schema.vehicle_health as h 
    on v.vehicle_id=h.vehicle_id
left join fleet_db.setup_schema.health_score as s 
    on v.vehicle_id=s.vehicle_id;

-- VIEW
create or replace view fleet_db.setup_schema.v_depot_kpis as
select depot,count(*) total_vehicles,avg(odometer_km) average_odometer
from fleet_db.setup_schema.vehicles_processed
group by depot;

-- MASKING POLICY 
create or replace masking policy vin_mask as
(val string) returns string ->
case 
    when current_role()='accountadmin' then val 
    else '************' 
    end;
alter table fleet_db.setup_schema.vehicles_processed
modify column vin set masking policy vin_mask;

create or replace masking policy registration_mask as
(val string) returns string ->
case when current_role()='accountadmin' then val 
    else '******' 
    end;

alter table fleet_db.setup_schema.vehicles_processed
modify column registration_no set masking policy registration_mask;

-- ROLE GRANTING AND MAKING A ROLE
create or replace role analyst;
grant usage on database fleet_db to role analyst;
grant usage on schema fleet_db.setup_schema to role analyst;
grant select on all tables in schema fleet_db.setup_schema to role analyst;