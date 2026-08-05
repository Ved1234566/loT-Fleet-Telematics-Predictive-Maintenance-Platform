-- Fleet DB masking policies, role setup, and access control verification
-- Co-authored with CoCo
use role accountadmin;

use database fleet_db;
use warehouse compute_wh;

;

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
grant role analyst to user VEDANG4009;
grant usage on database fleet_db to role analyst;
grant usage on schema fleet_db.setup_schema to role analyst;
grant select on all tables in schema fleet_db.setup_schema to role analyst;


-- then in a new session/worksheet, switch role and check masking works
use role analyst;
select vin, registration_no from fleet_db.setup_schema.vehicles_processed limit 5;
