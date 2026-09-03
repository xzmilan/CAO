-- USE FOR DEV/TESTING ONLY. DO NOT USE IN PROD.
{% macro customer_journey__apply_dev_row_limit(sql) -%}
  {% set row_limit = var('dev_row_limit', none) %}

  {% if target.name == 'dev' and row_limit is not none %}
    {% set limited_sql %}
select *
from (
{{ sql }}
) as customer_journey_dev_limited
limit {{ row_limit }}
    {% endset %}
    {{ return(limited_sql) }}
  {% endif %}

  {{ return(sql) }}
{%- endmacro %}

{% macro snowflake__create_table_as(temporary, relation, compiled_code, language='sql') -%}
  {%- if language == 'sql' -%}
    {%- set compiled_code = customer_journey__apply_dev_row_limit(compiled_code) -%}
  {%- endif -%}

  {%- set catalog_relation = adapter.build_catalog_relation(config.model) -%}

  {%- if language == 'sql' -%}
    {%- if temporary -%}
      {{ snowflake__create_table_temporary_sql(relation, compiled_code) }}
    {%- elif catalog_relation.catalog_type == 'INFO_SCHEMA' -%}
      {{ snowflake__create_table_info_schema_sql(relation, compiled_code) }}
    {%- elif catalog_relation.catalog_type == 'BUILT_IN' -%}
      {{ snowflake__create_table_built_in_sql(relation, compiled_code) }}
    {%- elif catalog_relation.catalog_type == 'ICEBERG_REST' -%}
      {%- if catalog_relation.catalog_linked_database_type is defined and catalog_relation.catalog_linked_database_type == 'glue' -%}
        {{ snowflake__create_table_iceberg_rest_with_glue(relation, compiled_code, catalog_relation) }}
      {%- else -%}
        {{ snowflake__create_table_iceberg_rest_sql(relation, compiled_code) }}
      {%- endif -%}
    {%- else -%}
      {% do exceptions.raise_compiler_error('Unexpected model config for: ' ~ relation) %}
    {%- endif -%}
  {%- elif language == 'python' -%}
    {%- if catalog_relation.catalog_type == 'BUILT_IN' -%}
      {% do exceptions.raise_compiler_error('Iceberg is incompatible with Python models. Please use a SQL model for the iceberg format.') %}
    {%- else -%}
      {{ py_write_table(compiled_code, relation, temporary) }}
    {%- endif -%}
  {%- else -%}
    {% do exceptions.raise_compiler_error("snowflake__create_table_as macro didn't get supported language, it got %s" % language) %}
  {%- endif -%}
{%- endmacro %}

{% macro snowflake__create_view_as_with_temp_flag(relation, sql, is_temporary=False) -%}
  {%- set sql = customer_journey__apply_dev_row_limit(sql) -%}
  {%- set secure = config.get('secure', default=false) -%}
  {%- set copy_grants = config.get('copy_grants', default=false) -%}
  {%- set row_access_policy = config.get('row_access_policy', default=none) -%}
  {%- set table_tag = config.get('table_tag', default=none) -%}
  {%- set sql_header = config.get('sql_header', none) -%}

  {{ sql_header if sql_header is not none }}
  create or replace {% if secure -%}
    secure
  {%- endif %} {% if is_temporary -%}
    temporary
  {%- endif %} view {{ relation }}
  {% if config.persist_column_docs() -%}
    {% set model_columns = model.columns %}
    {% set query_columns = get_columns_in_query(sql) %}
    {{ get_persist_docs_column_list(model_columns, query_columns) }}

  {%- endif %}
  {%- set contract_config = config.get('contract') -%}
  {%- if contract_config.enforced -%}
    {{ get_assert_columns_equivalent(sql) }}
  {%- endif %}
  {% if copy_grants -%} copy grants {%- endif %}
  {% if row_access_policy -%} with row access policy {{ row_access_policy }} {%- endif %}
  {% if table_tag -%} with tag ({{ table_tag }}) {%- endif %}
  as (
    {{ sql }}
  );
{%- endmacro %}