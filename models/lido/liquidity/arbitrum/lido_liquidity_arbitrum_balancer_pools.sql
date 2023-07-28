{{ config(
    schema='lido_liquidity_arbitrum',
    alias = alias('balancer_pools'),
    tags = ['dunesql'], 
    partition_by = ['time'],
    materialized = 'table',
    file_format = 'delta',
    unique_key = ['pool', 'time'],
    post_hook='{{ expose_spells(\'["arbitrum"]\',
                                "project",
                                "lido_liquidity",
                                \'["ppclunghe"]\') }}'
    )
}}

{% set project_start_date = '2022-09-17' %} 

with dates as (
with day_seq as (select (sequence(cast('{{ project_start_date }}' as date), CURRENT_DATE, interval '1' day)) as day)
select days.day
from day_seq
cross join unnest(day) as days(day)
  )


, pools(pool_id,  poolAddress) as (   
values 
(0x36bf227d6bac96e2ab1ebb5492ecec69c691943f000200000000000000000316, 0x36bf227d6BaC96e2aB1EbB5492ECec69C691943f),
(0x5a7f39435fd9c381e4932fa2047c9a5136a5e3e7000000000000000000000400, 0x5a7f39435fd9c381e4932fa2047c9a5136a5e3e7),
(0xfb5e6d0c1dfed2ba000fbc040ab8df3615ac329c000000000000000000000159, 0xfb5e6d0c1dfed2ba000fbc040ab8df3615ac329c),
(0xb5bd58c733948e3d65d86ba9604e06e5da276fd10002000000000000000003e6, 0xb5bd58c733948e3d65d86ba9604e06e5da276fd1),
(0x178e029173417b1f9c8bc16dcec6f697bc323746000200000000000000000158, 0x178e029173417b1f9c8bc16dcec6f697bc323746)
)

, pool_per_date as ( 
select dates.day, pools.*
from dates
left join pools on 1=1
)

, tokens as (
select distinct token_address from (
SELECT  tokens.token_address
FROM {{source('balancer_v2_arbitrum','WeightedPoolV2Factory_call_create')}} call_create
    CROSS JOIN UNNEST(call_create.tokens) as tokens(token_address)
WHERE call_create.output_0 in (select distinct  poolAddress from pools)
union all
SELECT tokens.token_address
FROM {{source('balancer_v2_arbitrum','WeightedPool2TokensFactory_call_create')}} call_create
    CROSS JOIN UNNEST(call_create.tokens) as tokens(token_address)
WHERE call_create.output_0 in (select distinct  poolAddress from pools)
union all
SELECT tokens.token_address
FROM {{source('balancer_v2_arbitrum','WeightedPoolFactory_call_create')}} call_create
    CROSS JOIN UNNEST(call_create.tokens) as tokens(token_address)
WHERE call_create.output_0 in (select distinct  poolAddress from pools)
union all
SELECT tokens.token_address
FROM {{source('balancer_v2_arbitrum','StablePoolFactory_call_create')}} call_create
    CROSS JOIN UNNEST(call_create.tokens) as tokens(token_address)
WHERE call_create.output_0 in (select distinct  poolAddress from pools)
union all
SELECT tokens.token_address
FROM {{source('balancer_v2_arbitrum','MetaStablePoolFactory_call_create')}} call_create
    CROSS JOIN UNNEST(call_create.tokens) as tokens(token_address)
WHERE call_create.output_0 in (select distinct  poolAddress from pools)
union all
SELECT tokens.token_address
FROM {{source('balancer_v2_arbitrum','ComposableStablePoolFactory_call_create')}} call_create
    CROSS JOIN UNNEST(call_create.tokens) as tokens(token_address)
WHERE call_create.output_0 in (select distinct  poolAddress from pools)
union all
SELECT tokens.token_address
FROM {{source('balancer_v2_arbitrum','LiquidityBootstrappingPoolFactory_call_create')}} call_create
    CROSS JOIN UNNEST(call_create.tokens) as tokens(token_address)
WHERE call_create.output_0 in (select distinct  poolAddress from pools)
)
)


, tokens_prices_daily AS (
    SELECT distinct
        DATE_TRUNC('day', minute) AS time,
        contract_address as token,
        symbol,
        decimals,
        avg(price) AS price
    FROM {{ source('prices', 'usd') }}
    WHERE date_trunc('day', minute) >= date '{{ project_start_date }}'
    and date_trunc('day', minute) < current_date
    and blockchain = 'arbitrum'
    and contract_address in (select distinct token_address from tokens)
    group by 1,2,3,4
    union all
    SELECT distinct
        DATE_TRUNC('day', minute), 
        contract_address as token,
        symbol,
        decimals,
        last_value(price) over (partition by DATE_TRUNC('day', minute), contract_address ORDER BY  minute range between unbounded preceding AND unbounded following) AS price
    FROM {{ source('prices', 'usd') }}
    WHERE date_trunc('day', minute) = current_date
    and blockchain = 'arbitrum'
    and contract_address in (select distinct token_address from tokens)
)

, wsteth_prices_hourly AS (
    select time, lead(time,1, DATE_TRUNC('hour', now() + interval '1' hour)) over (order by time) as next_time, price
    from (
    SELECT distinct
        DATE_TRUNC('hour', minute) time,
        last_value(price) over (partition by DATE_TRUNC('hour', minute), contract_address ORDER BY  minute range between unbounded preceding AND unbounded following) AS price
    FROM {{ source('prices', 'usd') }}
    WHERE date_trunc('day', minute) >=  date '{{ project_start_date }}'
    and blockchain = 'arbitrum'
    and contract_address = 0x5979d7b546e38e414f7e9822514be443a4800529
))


, swaps_changes as (
        SELECT
            day,
            pool_id,
            token,
            SUM(COALESCE(delta, 0)) AS delta
        FROM
            (
                SELECT
                    date_trunc('day', evt_block_time) AS day,
                    poolId AS pool_id,
                    tokenIn AS token,
                    cast(amountIn as double) AS delta
                FROM {{source('balancer_v2_arbitrum','Vault_evt_Swap')}}
                WHERE date_trunc('day', evt_block_time) >= date '{{ project_start_date }}'
                and poolId in (select pool_id from pools)
                UNION
                ALL
                SELECT
                    date_trunc('day', evt_block_time) AS day,
                    poolId AS pool_id,
                    tokenOut AS token,
                    -cast(amountOut as double) AS delta
                FROM {{source('balancer_v2_arbitrum','Vault_evt_Swap')}}
                WHERE date_trunc('day', evt_block_time) >= date '{{ project_start_date }}'
                and poolId in (select pool_id from pools)
            ) swaps
        GROUP BY 1, 2, 3
   )

 , balances_changes AS (
        SELECT
            date_trunc('day', evt_block_time) AS day,
            poolId AS pool_id,
            u.token,
            cast(u.delta as double) as delta
        FROM {{source('balancer_v2_arbitrum','Vault_evt_PoolBalanceChanged')}}
         CROSS JOIN UNNEST(tokens, deltas) as u(token, delta)
        WHERE date_trunc('day', evt_block_time) >= date '{{ project_start_date }}'
        and poolId in (select pool_id from pools)
    )

, managed_changes AS (
        SELECT
            date_trunc('day', evt_block_time) AS day,
            poolId AS pool_id,
            token,
            cast(managedDelta as double) AS delta
        FROM {{source('balancer_v2_arbitrum','Vault_evt_PoolBalanceManaged')}}
        WHERE date_trunc('day', evt_block_time) >= date '{{ project_start_date }}'
        and poolId in (select pool_id from pools)
)

, daily_delta_balance AS (
        SELECT
            day,
            pool_id,
            token,
            SUM(COALESCE(amount, cast(0 as double))) AS amount
        FROM
            (
                SELECT
                    day,
                    pool_id,
                    token,
                    SUM(COALESCE(delta, cast(0 as double))) AS amount
                FROM
                    balances_changes
                GROUP BY 1, 2, 3
                UNION ALL
                SELECT
                    day,
                    pool_id,
                    token,
                    delta AS amount
                FROM
                    swaps_changes
                UNION ALL
                SELECT
                    day,
                    pool_id,
                    token,
                    delta AS amount
                FROM
                    managed_changes
            ) balance
        GROUP BY 1, 2, 3
)

, cumulative_balance AS (
        SELECT
            day,
            pool_id,
            token,
            LEAD(day, 1, current_date + interval '1' day) OVER (PARTITION BY token, pool_id ORDER BY DAY) AS day_of_next_change,
            SUM(amount) OVER (PARTITION BY pool_id, token ORDER BY DAY ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_amount
        FROM daily_delta_balance
)

    

, cumulative_usd_balance AS (
        SELECT
            c.day,
            c.pool_id,
            b.token,
            p1.symbol AS token_symbol,
            cumulative_amount as token_balance_raw,
            cumulative_amount / POWER(10, p1.decimals) AS token_balance,
            (cumulative_amount / POWER(10, p1.decimals)) * COALESCE(p1.price, 0) AS amount_usd, 
            0 as row_numb
        FROM  pool_per_date  c
        LEFT JOIN cumulative_balance b ON c.pool_id = b.pool_id and  b.day <= c.day AND c.day < b.day_of_next_change
        LEFT JOIN tokens_prices_daily p1 ON p1.time = b.day AND p1.token = b.token
        WHERE b.token = 0x5979d7b546e38e414f7e9822514be443a4800529
        union all
        SELECT
            c.day,
            c.pool_id,
            coalesce(b.token, p1.token) as token,
            p1.symbol AS token_symbol,
            cumulative_amount as token_balance_raw,
            cumulative_amount / POWER(10, p1.decimals) AS token_balance,
            (cumulative_amount / POWER(10, p1.decimals)) * COALESCE(p1.price, 0) AS amount_usd, 
            row_number() OVER(PARTITION BY c.day, c.pool_id ORDER BY  c.day, c.pool_id, b.token) as row_numb
            
        FROM  pool_per_date  c
        LEFT JOIN cumulative_balance b ON c.pool_id = b.pool_id and b.day <= c.day AND c.day < b.day_of_next_change
        LEFT JOIN tokens_prices_daily p1 ON p1.time = b.day 
            AND p1.token = (case when b.token = 0xda1cd1711743e57dd57102e9e61b75f3587703da then 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1 else b.token end)
        WHERE b.token != 0x5979d7b546e38e414f7e9822514be443a4800529 
          and b.token not in (select poolAddress from pools)

)


, reserves as (
select main.day, main.pool_id, 
main_token, main_token_symbol, main_token_reserve, main_token_usd_reserve,
paired1_token, paired1_token_symbol, paired1_token_reserve, paired1_token_usd_reserve,
paired2_token, paired2_token_symbol, paired2_token_reserve, paired2_token_usd_reserve,
paired3_token, paired3_token_symbol, paired3_token_reserve, paired3_token_usd_reserve,
paired4_token, paired4_token_symbol, paired4_token_reserve, paired4_token_usd_reserve
from (
SELECT
    b.day,
    b.pool_id,
    token AS main_token,
    token_symbol as main_token_symbol,
    coalesce(token_balance, token_balance_raw) as main_token_reserve,
    coalesce(amount_usd, 0) AS main_token_usd_reserve
FROM cumulative_usd_balance b
where token = 0x5979d7b546e38e414f7e9822514be443a4800529 ) main
join 
(
SELECT
    b.day,
    b.pool_id,
    token AS paired1_token,
    token_symbol as paired1_token_symbol,
    coalesce(token_balance, token_balance_raw) as paired1_token_reserve,
    coalesce(amount_usd, 0) AS paired1_token_usd_reserve
FROM cumulative_usd_balance b
where token != 0x5979d7b546e38e414f7e9822514be443a4800529 and cast(row_numb as int) = int '1') paired1
on main.day = paired1.day and main.pool_id = paired1.pool_id 
left join (
SELECT
    b.day,
    b.pool_id,
    token AS paired2_token,
    token_symbol as paired2_token_symbol,
    coalesce(token_balance, token_balance_raw) as paired2_token_reserve,
    coalesce(amount_usd, 0) AS paired2_token_usd_reserve
FROM cumulative_usd_balance b
where token != 0x5979d7b546e38e414f7e9822514be443a4800529 and cast(row_numb as int) = int '2') paired2
on main.day = paired2.day and main.pool_id = paired2.pool_id 
left join (
SELECT
    b.day,
    b.pool_id,
    token AS paired3_token,
    token_symbol as paired3_token_symbol,
    coalesce(token_balance, token_balance_raw) as paired3_token_reserve,
    coalesce(amount_usd, 0) AS paired3_token_usd_reserve
FROM cumulative_usd_balance b
where token != 0x5979d7b546e38e414f7e9822514be443a4800529 and cast(row_numb as int) = int '3') paired3
on main.day = paired3.day and main.pool_id = paired3.pool_id 
left join (
SELECT
    b.day,
    b.pool_id,
    token AS paired4_token,
    token_symbol as paired4_token_symbol,
    coalesce(token_balance, token_balance_raw) as paired4_token_reserve,
    coalesce(amount_usd, 0) AS paired4_token_usd_reserve
FROM cumulative_usd_balance b
where token != 0x5979d7b546e38e414f7e9822514be443a4800529 and cast(row_numb as int) = int '4') paired4
on main.day = paired4.day and main.pool_id = paired4.pool_id 
)



, trading_volume as (    
    select  date_trunc('day', s.evt_block_time) as time,
        poolId,
        sum(case when tokenOut = 0x5979d7b546e38e414f7e9822514be443a4800529 then p.price*amountOut/1e18 
             else p.price*amountIn/1e18 end) as trading_volume
    from {{source('balancer_v2_arbitrum','Vault_evt_Swap')}} s
    left join wsteth_prices_hourly p on date_trunc('hour', s.evt_block_time) >= p.time and date_trunc('hour', s.evt_block_time) < p.next_time
    WHERE date_trunc('day', s.evt_block_time) >= date '{{ project_start_date }}'
    and s.poolId in (select pool_id from pools)
    group by 1,2
) 


, all_metrics as (
select  pool_id as pool, 'arbitrum' as blockchain, 'balancer' as project, 0 as fee, day as time, main_token, main_token_symbol, 
paired1_token as paired_token,
paired1_token_symbol as paired_token_symbol,
main_token_reserve, paired1_token_reserve as paired_token_reserve,
main_token_usd_reserve,
paired1_token_usd_reserve + coalesce(paired2_token_usd_reserve,0) + coalesce(paired3_token_usd_reserve,0) + coalesce(paired4_token_usd_reserve,0) as paired_token_usd_reserve,
coalesce(trading_volume.trading_volume,0) as trading_volume
from reserves r
left join trading_volume on r.pool_id = trading_volume.poolId and  r.day = trading_volume.time
order by day desc, pool_id

)


select 
blockchain ||' '|| project ||' '|| coalesce(paired_token_symbol,'unknown') ||':'|| main_token_symbol ||'('|| substring(cast(pool as varchar),64) ||')' as pool_name,
* 
from all_metrics
where main_token_reserve > 1
