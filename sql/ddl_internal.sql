-- Creates a hypertable row.
CREATE OR REPLACE FUNCTION _timescaledb_internal.create_hypertable_row(
    schema_name             NAME,
    table_name              NAME,
    time_column_name        NAME,
    time_column_type        REGTYPE,
    partitioning_column     NAME,
    number_partitions       INTEGER,
    associated_schema_name  NAME,
    associated_table_prefix NAME,
    chunk_time_interval        BIGINT,
    tablespace              NAME
)
    RETURNS _timescaledb_catalog.hypertable LANGUAGE PLPGSQL VOLATILE AS
$BODY$
DECLARE
    id                       INTEGER;
    hypertable_row           _timescaledb_catalog.hypertable;
    partitioning_func        _timescaledb_catalog.partition_epoch.partitioning_func%TYPE = 'get_partition_for_key';
    partitioning_func_schema _timescaledb_catalog.partition_epoch.partitioning_func_schema%TYPE = '_timescaledb_internal';
BEGIN
    id :=  nextval(pg_get_serial_sequence('_timescaledb_catalog.hypertable','id'));

    IF associated_schema_name IS NULL THEN
        associated_schema_name = '_timescaledb_internal';
    END IF;

    IF associated_table_prefix IS NULL THEN
        associated_table_prefix = format('_hyper_%s', id);
    END IF;

    IF partitioning_column IS NULL THEN
        IF number_partitions IS NULL THEN
            number_partitions := 1;
            partitioning_func := NULL;
            partitioning_func_schema := NULL;
        ELSIF number_partitions <> 1 THEN
            RAISE EXCEPTION 'The number of partitions must be 1 without a partitioning column'
            USING ERRCODE ='IO101';
        END IF;
    ELSIF number_partitions IS NULL THEN
        RAISE EXCEPTION 'The number of partitions must be specified when there is a partitioning column'
        USING ERRCODE ='IO101';
    END IF;

    IF number_partitions IS NOT NULL AND
       (number_partitions < 1 OR number_partitions > 32767) THEN
        RAISE EXCEPTION 'Invalid number of partitions'
        USING ERRCODE ='IO101';
    END IF;

    INSERT INTO _timescaledb_catalog.hypertable (
        id, schema_name, table_name,
        associated_schema_name, associated_table_prefix,
        chunk_time_interval,
        time_column_name, time_column_type)
    VALUES (
        id, schema_name, table_name,
        associated_schema_name, associated_table_prefix,
        chunk_time_interval,
        time_column_name, time_column_type
      )
    RETURNING * INTO hypertable_row;

    IF number_partitions != 0 THEN
        PERFORM add_equi_partition_epoch(hypertable_row.id, number_partitions::smallint, partitioning_column,
                                         partitioning_func_schema, partitioning_func, tablespace);
    END IF;
    RETURN hypertable_row;
END
$BODY$;

-- Add an index to a hypertable
CREATE OR REPLACE FUNCTION _timescaledb_internal.add_index(
    hypertable_id    INTEGER,
    main_schema_name NAME,
    main_index_name  NAME,
    definition       TEXT
)
    RETURNS VOID LANGUAGE SQL VOLATILE AS
$BODY$
INSERT INTO _timescaledb_catalog.hypertable_index (hypertable_id, main_schema_name, main_index_name, definition)
VALUES (hypertable_id, main_schema_name, main_index_name, definition);
$BODY$;

-- Drops the index for a hypertable
CREATE OR REPLACE FUNCTION _timescaledb_internal.drop_index(
    main_schema_name NAME,
    main_index_name  NAME
)
    RETURNS VOID LANGUAGE SQL VOLATILE AS
$BODY$
DELETE FROM _timescaledb_catalog.hypertable_index i
WHERE i.main_index_name = drop_index.main_index_name AND i.main_schema_name = drop_index.main_schema_name;
$BODY$;

-- Drops a hypertable
CREATE OR REPLACE FUNCTION _timescaledb_internal.drop_hypertable(
    schema_name NAME,
    table_name  NAME
)
    RETURNS VOID LANGUAGE SQL VOLATILE AS
$BODY$
    DELETE FROM _timescaledb_catalog.hypertable h
    WHERE h.schema_name = drop_hypertable.schema_name AND
          h.table_name = drop_hypertable.table_name
$BODY$;

-- Drop chunks older than the given timestamp. If a hypertable name is given,
-- drop only chunks associated with this table.
CREATE OR REPLACE FUNCTION _timescaledb_internal.drop_chunks_older_than(
    older_than_time  BIGINT,
    table_name  NAME = NULL,
    schema_name NAME = NULL
)
    RETURNS VOID LANGUAGE PLPGSQL VOLATILE AS
$BODY$
DECLARE
BEGIN
    EXECUTE format(
        $$
        DELETE FROM _timescaledb_catalog.chunk c
        USING _timescaledb_catalog.partition p,
        _timescaledb_catalog.partition_epoch pe,
        _timescaledb_catalog.hypertable h
        WHERE p.id = c.partition_id
        AND pe.id = p.epoch_id
        AND h.id = pe.hypertable_id
        AND c.end_time < %1$L
        AND (%2$L IS NULL OR h.schema_name = %2$L)
        AND (%3$L IS NULL OR h.table_name = %3$L)
        $$, older_than_time, schema_name, table_name
    );
END
$BODY$;

-- Create the "general definition" of an index. The general definition
-- is the corresponding create index command with the placeholders /*TABLE_NAME*/
-- and  /*INDEX_NAME*/
CREATE OR REPLACE FUNCTION _timescaledb_internal.get_general_index_definition(
    index_oid       REGCLASS,
    table_oid       REGCLASS,
    hypertable_row  _timescaledb_catalog.hypertable
)
RETURNS text
LANGUAGE plpgsql VOLATILE AS
$BODY$
DECLARE
    def             TEXT;
    index_name      TEXT;
    c               INTEGER;
    index_row       RECORD;
    missing_column  TEXT;
BEGIN
    -- Get index definition
    def := pg_get_indexdef(index_oid);

    IF def IS NULL THEN
        RAISE EXCEPTION 'Cannot process index with no definition: %', index_oid::TEXT;
    END IF;

    SELECT * INTO STRICT index_row FROM pg_index WHERE indexrelid = index_oid;

    IF index_row.indisunique THEN
        -- unique index must contain time and all partition columns from all epochs
        SELECT count(*) INTO c
        FROM pg_attribute
        WHERE attrelid = table_oid AND
              attnum = ANY(index_row.indkey) AND
              attname = hypertable_row.time_column_name;

        IF c < 1 THEN
            RAISE EXCEPTION 'Cannot create a unique index without the % column', hypertable_row.time_column_name
            USING ERRCODE = 'IO103';
        END IF;

        -- get any partitioning columns that are not included in the index.
        SELECT partitioning_column INTO missing_column
        FROM _timescaledb_catalog.partition_epoch
        WHERE hypertable_id = hypertable_row.id AND
              partitioning_column NOT IN (
                SELECT attname
                FROM pg_attribute
                WHERE attrelid = table_oid AND
                attnum = ANY(index_row.indkey)
            );

        IF missing_column IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot create a unique index without the partitioning column: %', missing_column
            USING ERRCODE = 'IO103';
        END IF;
    END IF;


    SELECT count(*) INTO c
    FROM regexp_matches(def, 'ON '||table_oid::TEXT || ' USING', 'g');
    IF c <> 1 THEN
         RAISE EXCEPTION 'Cannot process index with definition(no table name match): %', def
         USING ERRCODE = 'IO103';
    END IF;

    def := replace(def, 'ON '|| table_oid::TEXT || ' USING', 'ON /*TABLE_NAME*/ USING');

    -- Replace index name with /*INDEX_NAME*/
    -- Index name is never schema qualified
    -- Mixed case identifiers are properly handled.
    SELECT format('%I', c.relname) INTO STRICT index_name FROM pg_catalog.pg_class AS c WHERE c.oid = index_oid AND c.relkind = 'i'::CHAR;

    SELECT count(*) INTO c
    FROM regexp_matches(def, 'INDEX '|| index_name || ' ON', 'g');
    IF c <> 1 THEN
         RAISE EXCEPTION 'Cannot process index with definition(no index name match): %', def
         USING ERRCODE = 'IO103';
    END IF;

    def := replace(def, 'INDEX '|| index_name || ' ON',  'INDEX /*INDEX_NAME*/ ON');

    RETURN def;
END
$BODY$;

-- Creates the default indexes on a hypertable.
CREATE OR REPLACE FUNCTION _timescaledb_internal.create_default_indexes(
    hypertable_row _timescaledb_catalog.hypertable,
    main_table REGCLASS,
    partitioning_column NAME
)
    RETURNS VOID LANGUAGE PLPGSQL VOLATILE AS
$BODY$
DECLARE
    index_count INTEGER;
BEGIN
    SELECT count(*) INTO index_count
    FROM pg_index
    WHERE indkey = (
        SELECT attnum::text::int2vector
        FROM pg_attribute WHERE attrelid = main_table AND attname=hypertable_row.time_column_name
    ) AND indrelid = main_table;

    IF index_count = 0 THEN
        EXECUTE format($$ CREATE INDEX ON %I.%I(%I DESC) $$,
            hypertable_row.schema_name, hypertable_row.table_name, hypertable_row.time_column_name);
    END IF;

    IF partitioning_column IS NOT NULL THEN
        SELECT count(*) INTO index_count
        FROM pg_index
        WHERE indkey = (
            SELECT array_to_string(ARRAY(
                SELECT attnum::text
                FROM pg_attribute WHERE attrelid = main_table AND attname=partitioning_column
                UNION ALL
                SELECT attnum::text
                FROM pg_attribute WHERE attrelid = main_table AND attname=hypertable_row.time_column_name
            ), ' ')::int2vector
        ) AND indrelid = main_table;


        IF index_count = 0 THEN
            EXECUTE format($$ CREATE INDEX ON %I.%I(%I, %I DESC) $$,
            hypertable_row.schema_name, hypertable_row.table_name, partitioning_column, hypertable_row.time_column_name);
        END IF;
    END IF;
END
$BODY$;
