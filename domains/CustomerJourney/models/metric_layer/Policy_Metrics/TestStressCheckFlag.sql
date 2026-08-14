{{ config(tags=['metric_policy']) }}

-- METRIC: TestStressCheckFlag
-- Deliberately messy test file for the full-gate stress test.
-- Owner: Retention Analytics
-- Contract: 1 row per policy ID = 1:1

select
    policy.*
    ,case
        when policy.Policy:cancellationdate is null then 1
    else 0
    end as teststresscheckflag
from {{ ref('PolicyRaw') }} as policy
