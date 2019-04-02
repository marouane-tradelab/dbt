{#
    Create SCD Hash SQL fields cross-db
#}

{% macro archive_scd_hash() %}
  {{ adapter_macro('archive_scd_hash') }}
{% endmacro %}

{% macro default__archive_scd_hash() %}
    md5("dbt_pk" || '|' || "dbt_updated_at")
{% endmacro %}

{% macro create_temporary_table(sql, relation) %}
  {{ return(adapter_macro('create_temporary_table', sql, relation)) }}
{% endmacro %}

{% macro default__create_temporary_table(sql, relation) %}
    {% call statement() %}
        {{ create_table_as(True, relation, sql) }}
    {% endcall %}
    {{ return(relation) }}
{% endmacro %}

{#
    Add new columns to the table if applicable
#}
{% macro create_columns(relation, columns) %}
  {{ adapter_macro('create_columns', relation, columns) }}
{% endmacro %}

{% macro default__create_columns(relation, columns) %}
  {% for column in columns %}
    {% call statement() %}
      alter table {{ relation }} add column "{{ column.name }}" {{ column.data_type }};
    {% endcall %}
  {% endfor %}
{% endmacro %}

{#
    Run the update part of an archive query. Different databases have
    tricky differences in their `update` semantics. Table projection is
    not allowed on Redshift/pg, but is effectively required on bq.
#}

{% macro archive_update(target_relation, tmp_relation) %}
    {{ adapter_macro('archive_update', target_relation, tmp_relation) }}
{% endmacro %}

{% macro default__archive_update(target_relation, tmp_relation) %}
    update {{ target_relation }}
    set {{ adapter.quote('dbt_valid_to') }} = tmp.{{ adapter.quote('dbt_valid_to') }}
    from {{ tmp_relation }} as tmp
    where tmp.{{ adapter.quote('dbt_scd_id') }} = {{ target_relation }}.{{ adapter.quote('dbt_scd_id') }}
      and {{ adapter.quote('change_type') }} = 'update';
{% endmacro %}


{#
    Cross-db compatible archival implementation
#}
{% macro archive_select(source_sql, target_relation, source_columns, unique_key, updated_at) %}

    {% set timestamp_column = api.Column.create('_', 'timestamp') %}
    with source as (
      {{ source_sql }}
    ),

    current_data as (

        select
            {% for col in source_columns %}
                {{ adapter.quote(col.name) }} {% if not loop.last %},{% endif %}
            {% endfor %},
            {{ updated_at }} as {{ adapter.quote('dbt_updated_at') }},
            {{ unique_key }} as {{ adapter.quote('dbt_pk') }},
            {{ updated_at }} as {{ adapter.quote('dbt_valid_from') }},
            {{ timestamp_column.literal('null') }} as {{ adapter.quote('tmp_valid_to') }}
        from source
    ),

    archived_data as (

        select
            {% for col in source_columns %}
                {{ adapter.quote(col.name) }},
            {% endfor %}
            {{ updated_at }} as {{ adapter.quote('dbt_updated_at') }},
            {{ unique_key }} as {{ adapter.quote('dbt_pk') }},
            {{ adapter.quote('dbt_valid_from') }},
            {{ adapter.quote('dbt_valid_to') }} as {{ adapter.quote('tmp_valid_to') }}
        from {{ target_relation }}

    ),

    insertions as (

        select
            current_data.*,
            {{ timestamp_column.literal('null') }} as {{ adapter.quote('dbt_valid_to') }}
        from current_data
        left outer join archived_data
          on archived_data.{{ adapter.quote('dbt_pk') }} = current_data.{{ adapter.quote('dbt_pk') }}
        where archived_data.{{ adapter.quote('dbt_pk') }} is null or (
          archived_data.{{ adapter.quote('dbt_pk') }} is not null and
          current_data.{{ adapter.quote('dbt_updated_at') }} > archived_data.{{ adapter.quote('dbt_updated_at') }} and
          archived_data.{{ adapter.quote('tmp_valid_to') }} is null
        )
    ),

    updates as (

        select
            archived_data.*,
            current_data.{{ adapter.quote('dbt_updated_at') }} as {{ adapter.quote('dbt_valid_to') }}
        from current_data
        left outer join archived_data
          on archived_data.{{ adapter.quote('dbt_pk') }} = current_data.{{ adapter.quote('dbt_pk') }}
        where archived_data.{{ adapter.quote('dbt_pk') }} is not null
          and archived_data.{{ adapter.quote('dbt_updated_at') }} < current_data.{{ adapter.quote('dbt_updated_at') }}
          and archived_data.{{ adapter.quote('tmp_valid_to') }} is null
    ),

    merged as (

      select *, 'update' as {{ adapter.quote('change_type') }} from updates
      union all
      select *, 'insert' as {{ adapter.quote('change_type') }} from insertions

    )

    select *,
        {{ archive_scd_hash() }} as {{ adapter.quote('dbt_scd_id') }}
    from merged

{% endmacro %}


{# this is gross #}
{% macro create_empty_table_as(sql) %}
  {% set tmp_relation = api.Relation.create(identifier=model['name']+'_dbt_archival_view_tmp', type='view') %}
  {% set limited_sql -%}
    with cte as (
      {{ sql }}
    )
    select * from cte limit 0
  {%- endset %}
  {%- set tmp_relation = create_temporary_table(limited_sql, tmp_relation) -%}

  {{ return(tmp_relation) }}

{% endmacro %}


{% materialization archive, default %}
  {%- set config = model['config'] -%}

  {%- set target_database = config.get('target_database') -%}
  {%- set target_schema = config.get('target_schema') -%}
  {%- set target_table = model.get('alias', model.get('name')) -%}
{#
  -- {%- set source_database = config.get('source_database') -%}
  -- {%- set source_schema = config.get('source_schema') -%}
  -- {%- set source_table = config.get('source_table') -%}
#}
  {{ create_schema(target_database, target_schema) }}

{# our source relation is now made in a select query - we'll get that passed in
  {%- set source_relation = adapter.get_relation(
      database=source_database,
      schema=source_schema,
      identifier=source_table) -%}
#}
  {%- set target_relation = adapter.get_relation(
      database=target_database,
      schema=target_schema,
      identifier=target_table) -%}

{# sorry I removed this error handling :(
  {%- if source_relation is none -%}
    {{ exceptions.missing_relation('.'.join([source_database, source_schema, source_table])) }}
  {%- endif -%}

#}

  {%- if target_relation is none -%}
    {%- set target_relation = api.Relation.create(
        database=target_database,
        schema=target_schema,
        identifier=target_table) -%}
  {%- elif not target_relation.is_table -%}
    {{ exceptions.relation_wrong_type(target_relation, 'table') }}
  {%- endif -%}

  {% set source_info_model = create_empty_table_as(model['injected_sql']) %}

  {%- set source_columns = adapter.get_columns_in_relation(source_info_model) -%}

  {%- set unique_key = config.get('unique_key') -%}
  {%- set updated_at = config.get('updated_at') -%}
  {%- set dest_columns = source_columns + [
      api.Column.create('dbt_valid_from', 'timestamp'),
      api.Column.create('dbt_valid_to', 'timestamp'),
      api.Column.create('dbt_scd_id', 'string'),
      api.Column.create('dbt_updated_at', 'timestamp'),
  ] -%}


  {% call statement() %}
    {{ create_archive_table(target_relation, dest_columns) }}
  {% endcall %}

  {% set missing_columns = adapter.get_missing_columns(source_info_model, target_relation) %}

  {{ create_columns(target_relation, missing_columns) }}


  {%- set identifier = model['alias'] -%}
  {%- set tmp_identifier = model['name'] + '__dbt_archival_tmp' -%}

  {% set tmp_table_sql -%}

      with dbt_archive_sbq as (
        {{ archive_select(model['injected_sql'], target_relation, source_columns, unique_key, updated_at) }}
      )
      select * from dbt_archive_sbq

  {%- endset %}

  {%- set tmp_relation = api.Relation.create(identifier=tmp_identifier, type='table') -%}
  {%- set tmp_relation = create_temporary_table(tmp_table_sql, tmp_relation) -%}

  {{ adapter.expand_target_column_types(temp_table=tmp_identifier,
                                        to_relation=target_relation) }}

  {% call statement('_') -%}
    {{ archive_update(target_relation, tmp_relation) }}
  {% endcall %}

  {% call statement('main') -%}

    insert into {{ target_relation }} (
      {{ column_list(dest_columns) }}
    )
    select {{ column_list(dest_columns) }} from {{ tmp_relation }}
    where {{ adapter.quote('change_type') }} = 'insert';
  {% endcall %}

  {{ adapter.commit() }}
{% endmaterialization %}
