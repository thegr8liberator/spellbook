{{ config
(
    alias = 'v0_5_userops_basics',
    schema = 'account_abstraction_erc4337_zora',

    partition_by = ['block_month'],
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    unique_key = ['userop_hash', 'tx_hash']
)
}}

{% set chain = 'zora' %}
{% set gas_symbol = 'ZORA' %}
{% set wrapped_gas_address = '0x0000000000000000000000000000000000000000' %}
{% set version = 'v0.5' %}
{% set deployed_date = '2023-02-15' %}

-- macros/models/sector/erc4337
{{
    erc4337_userops_basics(
        blockchain = 'zora',
        version = 'v0.5',
        userops_evt_model = source('erc4337_zora','EntryPoint_evt_UserOperationEvent'),
        handleops_call_model = source('erc4337_zora', 'EntryPoint_call_handleOps')
    )
}}
