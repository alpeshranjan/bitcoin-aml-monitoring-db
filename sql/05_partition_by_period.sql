-- ============================================================================
-- ANLC-752 Course Project -- Unit 10, Item 2: Partition by period
--
-- core.transaction and core.tx_feature are range-partitioned on time_step.
-- Period-scoped filtering is the dominant access pattern in the monitoring
-- workload (every query in sql/03_analytics.sql and the deck's SELECT/WHERE
-- example filters or groups by time_step) and currently scans the whole
-- table to satisfy it. One partition per period (49 partitions) lets the
-- planner prune to a single ~4,200-row partition instead of scanning all
-- 203,769 rows.
--
-- Two real PostgreSQL constraints shape this migration, and both are
-- decisions on the record rather than surprises discovered later:
--
--   1. A partitioned table's primary key must include the partition key.
--      core.transaction's PK becomes (tx_id, time_step), not tx_id alone.
--      Since each tx_id has exactly one time_step, this changes nothing
--      about what is enforced -- tx_id remains effectively unique -- but it
--      does change the column list any referencing table must join on.
--
--   2. PostgreSQL cannot enforce a native unique constraint on tx_id ALONE
--      across a table partitioned by time_step (uniqueness is only
--      guaranteed per-partition, and tx_id does not correlate with
--      time_step ranges). core.tx_flow's foreign keys to core.transaction
--      (tx_id) are therefore DROPPED, not migrated to a composite key --
--      tx_flow does not carry time_step and adding it purely to satisfy a
--      constraint would denormalize an edge table for no monitoring
--      benefit. Referential integrity across that edge is not undefended:
--      it is what edgelist_endpoints_resolve already checks at load time,
--      persisted to governance.dq_check_result. This project already treats
--      a passing named rule as stronger evidence than an assertion in a
--      slide; the same argument applies to a live constraint here.
--
-- analytics is dropped and rebuilt (sql/03_analytics.sql, sql/04_analysis.sql)
-- rather than patched in place -- exactly the property the schema section of
-- the Unit 8 deck already claims for that schema ("analytics can be dropped
-- and rebuilt without touching evidence").
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Drop the derived layer. Nothing here is evidence; all of it is rebuilt
--    by sql/03_analytics.sql and sql/04_analysis.sql after the migration.
-- ---------------------------------------------------------------------------
DROP SCHEMA IF EXISTS analytics CASCADE;
CREATE SCHEMA analytics;
COMMENT ON SCHEMA analytics IS 'Derived AML monitoring layer. Read-only to the analyst role.';

-- ---------------------------------------------------------------------------
-- 2. Move the unpartitioned tables aside.
-- ---------------------------------------------------------------------------
ALTER TABLE core.transaction RENAME TO transaction_unpartitioned;
ALTER TABLE core.tx_feature  RENAME TO tx_feature_unpartitioned;

-- Drop tx_flow's FKs to the (now renamed) transaction table -- see note (2)
-- above. Done generically so this migration does not depend on guessing
-- PostgreSQL's auto-generated constraint names.
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN
        SELECT conname FROM pg_constraint
        WHERE conrelid = 'core.tx_flow'::regclass AND contype = 'f'
    LOOP
        EXECUTE format('ALTER TABLE core.tx_flow DROP CONSTRAINT %I', r.conname);
    END LOOP;
END $$;

COMMENT ON TABLE core.tx_flow IS
    'Directed money flow edge: bitcoin from src_tx_id was spent by dst_tx_id. '
    'Edges connect transactions, NOT wallets or account holders -- the dataset '
    'carries no party or counterparty entity. Foreign keys to core.transaction '
    'were dropped when core.transaction was partitioned by time_step (PostgreSQL '
    'cannot enforce uniqueness on tx_id alone across that partitioning); '
    'endpoint referential integrity is instead enforced at load time by the '
    'edgelist_endpoints_resolve rule in governance.dq_check_result.';

-- ---------------------------------------------------------------------------
-- 3. Partitioned core.transaction
-- ---------------------------------------------------------------------------
CREATE TABLE core.transaction (
    tx_id         BIGINT   NOT NULL,
    time_step     SMALLINT NOT NULL REFERENCES core.dim_time_step (time_step),
    class_id      SMALLINT NOT NULL REFERENCES core.dim_class (class_id),
    load_batch_id INTEGER  NOT NULL,
    CONSTRAINT pk_transaction PRIMARY KEY (tx_id, time_step)
) PARTITION BY RANGE (time_step);

COMMENT ON TABLE core.transaction IS
    'One row per Bitcoin transaction (graph node). tx_id is the Elliptic surrogate '
    'identifier, not a Bitcoin transaction hash. Range-partitioned on time_step: '
    '49 partitions, one per period, because period-scoped filtering is the '
    'dominant access pattern in the monitoring workload.';

CREATE TABLE core.transaction_p01 PARTITION OF core.transaction FOR VALUES FROM (1) TO (2);
CREATE TABLE core.transaction_p02 PARTITION OF core.transaction FOR VALUES FROM (2) TO (3);
CREATE TABLE core.transaction_p03 PARTITION OF core.transaction FOR VALUES FROM (3) TO (4);
CREATE TABLE core.transaction_p04 PARTITION OF core.transaction FOR VALUES FROM (4) TO (5);
CREATE TABLE core.transaction_p05 PARTITION OF core.transaction FOR VALUES FROM (5) TO (6);
CREATE TABLE core.transaction_p06 PARTITION OF core.transaction FOR VALUES FROM (6) TO (7);
CREATE TABLE core.transaction_p07 PARTITION OF core.transaction FOR VALUES FROM (7) TO (8);
CREATE TABLE core.transaction_p08 PARTITION OF core.transaction FOR VALUES FROM (8) TO (9);
CREATE TABLE core.transaction_p09 PARTITION OF core.transaction FOR VALUES FROM (9) TO (10);
CREATE TABLE core.transaction_p10 PARTITION OF core.transaction FOR VALUES FROM (10) TO (11);
CREATE TABLE core.transaction_p11 PARTITION OF core.transaction FOR VALUES FROM (11) TO (12);
CREATE TABLE core.transaction_p12 PARTITION OF core.transaction FOR VALUES FROM (12) TO (13);
CREATE TABLE core.transaction_p13 PARTITION OF core.transaction FOR VALUES FROM (13) TO (14);
CREATE TABLE core.transaction_p14 PARTITION OF core.transaction FOR VALUES FROM (14) TO (15);
CREATE TABLE core.transaction_p15 PARTITION OF core.transaction FOR VALUES FROM (15) TO (16);
CREATE TABLE core.transaction_p16 PARTITION OF core.transaction FOR VALUES FROM (16) TO (17);
CREATE TABLE core.transaction_p17 PARTITION OF core.transaction FOR VALUES FROM (17) TO (18);
CREATE TABLE core.transaction_p18 PARTITION OF core.transaction FOR VALUES FROM (18) TO (19);
CREATE TABLE core.transaction_p19 PARTITION OF core.transaction FOR VALUES FROM (19) TO (20);
CREATE TABLE core.transaction_p20 PARTITION OF core.transaction FOR VALUES FROM (20) TO (21);
CREATE TABLE core.transaction_p21 PARTITION OF core.transaction FOR VALUES FROM (21) TO (22);
CREATE TABLE core.transaction_p22 PARTITION OF core.transaction FOR VALUES FROM (22) TO (23);
CREATE TABLE core.transaction_p23 PARTITION OF core.transaction FOR VALUES FROM (23) TO (24);
CREATE TABLE core.transaction_p24 PARTITION OF core.transaction FOR VALUES FROM (24) TO (25);
CREATE TABLE core.transaction_p25 PARTITION OF core.transaction FOR VALUES FROM (25) TO (26);
CREATE TABLE core.transaction_p26 PARTITION OF core.transaction FOR VALUES FROM (26) TO (27);
CREATE TABLE core.transaction_p27 PARTITION OF core.transaction FOR VALUES FROM (27) TO (28);
CREATE TABLE core.transaction_p28 PARTITION OF core.transaction FOR VALUES FROM (28) TO (29);
CREATE TABLE core.transaction_p29 PARTITION OF core.transaction FOR VALUES FROM (29) TO (30);
CREATE TABLE core.transaction_p30 PARTITION OF core.transaction FOR VALUES FROM (30) TO (31);
CREATE TABLE core.transaction_p31 PARTITION OF core.transaction FOR VALUES FROM (31) TO (32);
CREATE TABLE core.transaction_p32 PARTITION OF core.transaction FOR VALUES FROM (32) TO (33);
CREATE TABLE core.transaction_p33 PARTITION OF core.transaction FOR VALUES FROM (33) TO (34);
CREATE TABLE core.transaction_p34 PARTITION OF core.transaction FOR VALUES FROM (34) TO (35);
CREATE TABLE core.transaction_p35 PARTITION OF core.transaction FOR VALUES FROM (35) TO (36);
CREATE TABLE core.transaction_p36 PARTITION OF core.transaction FOR VALUES FROM (36) TO (37);
CREATE TABLE core.transaction_p37 PARTITION OF core.transaction FOR VALUES FROM (37) TO (38);
CREATE TABLE core.transaction_p38 PARTITION OF core.transaction FOR VALUES FROM (38) TO (39);
CREATE TABLE core.transaction_p39 PARTITION OF core.transaction FOR VALUES FROM (39) TO (40);
CREATE TABLE core.transaction_p40 PARTITION OF core.transaction FOR VALUES FROM (40) TO (41);
CREATE TABLE core.transaction_p41 PARTITION OF core.transaction FOR VALUES FROM (41) TO (42);
CREATE TABLE core.transaction_p42 PARTITION OF core.transaction FOR VALUES FROM (42) TO (43);
CREATE TABLE core.transaction_p43 PARTITION OF core.transaction FOR VALUES FROM (43) TO (44);
CREATE TABLE core.transaction_p44 PARTITION OF core.transaction FOR VALUES FROM (44) TO (45);
CREATE TABLE core.transaction_p45 PARTITION OF core.transaction FOR VALUES FROM (45) TO (46);
CREATE TABLE core.transaction_p46 PARTITION OF core.transaction FOR VALUES FROM (46) TO (47);
CREATE TABLE core.transaction_p47 PARTITION OF core.transaction FOR VALUES FROM (47) TO (48);
CREATE TABLE core.transaction_p48 PARTITION OF core.transaction FOR VALUES FROM (48) TO (49);
CREATE TABLE core.transaction_p49 PARTITION OF core.transaction FOR VALUES FROM (49) TO (50);

INSERT INTO core.transaction (tx_id, time_step, class_id, load_batch_id)
SELECT tx_id, time_step, class_id, load_batch_id FROM core.transaction_unpartitioned;

-- ---------------------------------------------------------------------------
-- 4. Partitioned core.tx_feature (time_step added -- required to partition
--    on it, and it is a straight 1:1 copy of the parent's period, not a new
--    fact)
-- ---------------------------------------------------------------------------
CREATE TABLE core.tx_feature (
    tx_id         BIGINT   NOT NULL,
    time_step     SMALLINT NOT NULL,
    local_feature_1            DOUBLE PRECISION NOT NULL,
    local_feature_2            DOUBLE PRECISION NOT NULL,
    local_feature_3            DOUBLE PRECISION NOT NULL,
    local_feature_4            DOUBLE PRECISION NOT NULL,
    local_feature_5            DOUBLE PRECISION NOT NULL,
    local_feature_6            DOUBLE PRECISION NOT NULL,
    local_feature_7            DOUBLE PRECISION NOT NULL,
    local_feature_8            DOUBLE PRECISION NOT NULL,
    local_feature_9            DOUBLE PRECISION NOT NULL,
    local_feature_10           DOUBLE PRECISION NOT NULL,
    local_feature_11           DOUBLE PRECISION NOT NULL,
    local_feature_12           DOUBLE PRECISION NOT NULL,
    local_feature_13           DOUBLE PRECISION NOT NULL,
    local_feature_14           DOUBLE PRECISION NOT NULL,
    local_feature_15           DOUBLE PRECISION NOT NULL,
    local_feature_16           DOUBLE PRECISION NOT NULL,
    local_feature_17           DOUBLE PRECISION NOT NULL,
    local_feature_18           DOUBLE PRECISION NOT NULL,
    local_feature_19           DOUBLE PRECISION NOT NULL,
    local_feature_20           DOUBLE PRECISION NOT NULL,
    local_feature_21           DOUBLE PRECISION NOT NULL,
    local_feature_22           DOUBLE PRECISION NOT NULL,
    local_feature_23           DOUBLE PRECISION NOT NULL,
    local_feature_24           DOUBLE PRECISION NOT NULL,
    local_feature_25           DOUBLE PRECISION NOT NULL,
    local_feature_26           DOUBLE PRECISION NOT NULL,
    local_feature_27           DOUBLE PRECISION NOT NULL,
    local_feature_28           DOUBLE PRECISION NOT NULL,
    local_feature_29           DOUBLE PRECISION NOT NULL,
    local_feature_30           DOUBLE PRECISION NOT NULL,
    local_feature_31           DOUBLE PRECISION NOT NULL,
    local_feature_32           DOUBLE PRECISION NOT NULL,
    local_feature_33           DOUBLE PRECISION NOT NULL,
    local_feature_34           DOUBLE PRECISION NOT NULL,
    local_feature_35           DOUBLE PRECISION NOT NULL,
    local_feature_36           DOUBLE PRECISION NOT NULL,
    local_feature_37           DOUBLE PRECISION NOT NULL,
    local_feature_38           DOUBLE PRECISION NOT NULL,
    local_feature_39           DOUBLE PRECISION NOT NULL,
    local_feature_40           DOUBLE PRECISION NOT NULL,
    local_feature_41           DOUBLE PRECISION NOT NULL,
    local_feature_42           DOUBLE PRECISION NOT NULL,
    local_feature_43           DOUBLE PRECISION NOT NULL,
    local_feature_44           DOUBLE PRECISION NOT NULL,
    local_feature_45           DOUBLE PRECISION NOT NULL,
    local_feature_46           DOUBLE PRECISION NOT NULL,
    local_feature_47           DOUBLE PRECISION NOT NULL,
    local_feature_48           DOUBLE PRECISION NOT NULL,
    local_feature_49           DOUBLE PRECISION NOT NULL,
    local_feature_50           DOUBLE PRECISION NOT NULL,
    local_feature_51           DOUBLE PRECISION NOT NULL,
    local_feature_52           DOUBLE PRECISION NOT NULL,
    local_feature_53           DOUBLE PRECISION NOT NULL,
    local_feature_54           DOUBLE PRECISION NOT NULL,
    local_feature_55           DOUBLE PRECISION NOT NULL,
    local_feature_56           DOUBLE PRECISION NOT NULL,
    local_feature_57           DOUBLE PRECISION NOT NULL,
    local_feature_58           DOUBLE PRECISION NOT NULL,
    local_feature_59           DOUBLE PRECISION NOT NULL,
    local_feature_60           DOUBLE PRECISION NOT NULL,
    local_feature_61           DOUBLE PRECISION NOT NULL,
    local_feature_62           DOUBLE PRECISION NOT NULL,
    local_feature_63           DOUBLE PRECISION NOT NULL,
    local_feature_64           DOUBLE PRECISION NOT NULL,
    local_feature_65           DOUBLE PRECISION NOT NULL,
    local_feature_66           DOUBLE PRECISION NOT NULL,
    local_feature_67           DOUBLE PRECISION NOT NULL,
    local_feature_68           DOUBLE PRECISION NOT NULL,
    local_feature_69           DOUBLE PRECISION NOT NULL,
    local_feature_70           DOUBLE PRECISION NOT NULL,
    local_feature_71           DOUBLE PRECISION NOT NULL,
    local_feature_72           DOUBLE PRECISION NOT NULL,
    local_feature_73           DOUBLE PRECISION NOT NULL,
    local_feature_74           DOUBLE PRECISION NOT NULL,
    local_feature_75           DOUBLE PRECISION NOT NULL,
    local_feature_76           DOUBLE PRECISION NOT NULL,
    local_feature_77           DOUBLE PRECISION NOT NULL,
    local_feature_78           DOUBLE PRECISION NOT NULL,
    local_feature_79           DOUBLE PRECISION NOT NULL,
    local_feature_80           DOUBLE PRECISION NOT NULL,
    local_feature_81           DOUBLE PRECISION NOT NULL,
    local_feature_82           DOUBLE PRECISION NOT NULL,
    local_feature_83           DOUBLE PRECISION NOT NULL,
    local_feature_84           DOUBLE PRECISION NOT NULL,
    local_feature_85           DOUBLE PRECISION NOT NULL,
    local_feature_86           DOUBLE PRECISION NOT NULL,
    local_feature_87           DOUBLE PRECISION NOT NULL,
    local_feature_88           DOUBLE PRECISION NOT NULL,
    local_feature_89           DOUBLE PRECISION NOT NULL,
    local_feature_90           DOUBLE PRECISION NOT NULL,
    local_feature_91           DOUBLE PRECISION NOT NULL,
    local_feature_92           DOUBLE PRECISION NOT NULL,
    local_feature_93           DOUBLE PRECISION NOT NULL,
    aggregate_feature_1        DOUBLE PRECISION NOT NULL,
    aggregate_feature_2        DOUBLE PRECISION NOT NULL,
    aggregate_feature_3        DOUBLE PRECISION NOT NULL,
    aggregate_feature_4        DOUBLE PRECISION NOT NULL,
    aggregate_feature_5        DOUBLE PRECISION NOT NULL,
    aggregate_feature_6        DOUBLE PRECISION NOT NULL,
    aggregate_feature_7        DOUBLE PRECISION NOT NULL,
    aggregate_feature_8        DOUBLE PRECISION NOT NULL,
    aggregate_feature_9        DOUBLE PRECISION NOT NULL,
    aggregate_feature_10       DOUBLE PRECISION NOT NULL,
    aggregate_feature_11       DOUBLE PRECISION NOT NULL,
    aggregate_feature_12       DOUBLE PRECISION NOT NULL,
    aggregate_feature_13       DOUBLE PRECISION NOT NULL,
    aggregate_feature_14       DOUBLE PRECISION NOT NULL,
    aggregate_feature_15       DOUBLE PRECISION NOT NULL,
    aggregate_feature_16       DOUBLE PRECISION NOT NULL,
    aggregate_feature_17       DOUBLE PRECISION NOT NULL,
    aggregate_feature_18       DOUBLE PRECISION NOT NULL,
    aggregate_feature_19       DOUBLE PRECISION NOT NULL,
    aggregate_feature_20       DOUBLE PRECISION NOT NULL,
    aggregate_feature_21       DOUBLE PRECISION NOT NULL,
    aggregate_feature_22       DOUBLE PRECISION NOT NULL,
    aggregate_feature_23       DOUBLE PRECISION NOT NULL,
    aggregate_feature_24       DOUBLE PRECISION NOT NULL,
    aggregate_feature_25       DOUBLE PRECISION NOT NULL,
    aggregate_feature_26       DOUBLE PRECISION NOT NULL,
    aggregate_feature_27       DOUBLE PRECISION NOT NULL,
    aggregate_feature_28       DOUBLE PRECISION NOT NULL,
    aggregate_feature_29       DOUBLE PRECISION NOT NULL,
    aggregate_feature_30       DOUBLE PRECISION NOT NULL,
    aggregate_feature_31       DOUBLE PRECISION NOT NULL,
    aggregate_feature_32       DOUBLE PRECISION NOT NULL,
    aggregate_feature_33       DOUBLE PRECISION NOT NULL,
    aggregate_feature_34       DOUBLE PRECISION NOT NULL,
    aggregate_feature_35       DOUBLE PRECISION NOT NULL,
    aggregate_feature_36       DOUBLE PRECISION NOT NULL,
    aggregate_feature_37       DOUBLE PRECISION NOT NULL,
    aggregate_feature_38       DOUBLE PRECISION NOT NULL,
    aggregate_feature_39       DOUBLE PRECISION NOT NULL,
    aggregate_feature_40       DOUBLE PRECISION NOT NULL,
    aggregate_feature_41       DOUBLE PRECISION NOT NULL,
    aggregate_feature_42       DOUBLE PRECISION NOT NULL,
    aggregate_feature_43       DOUBLE PRECISION NOT NULL,
    aggregate_feature_44       DOUBLE PRECISION NOT NULL,
    aggregate_feature_45       DOUBLE PRECISION NOT NULL,
    aggregate_feature_46       DOUBLE PRECISION NOT NULL,
    aggregate_feature_47       DOUBLE PRECISION NOT NULL,
    aggregate_feature_48       DOUBLE PRECISION NOT NULL,
    aggregate_feature_49       DOUBLE PRECISION NOT NULL,
    aggregate_feature_50       DOUBLE PRECISION NOT NULL,
    aggregate_feature_51       DOUBLE PRECISION NOT NULL,
    aggregate_feature_52       DOUBLE PRECISION NOT NULL,
    aggregate_feature_53       DOUBLE PRECISION NOT NULL,
    aggregate_feature_54       DOUBLE PRECISION NOT NULL,
    aggregate_feature_55       DOUBLE PRECISION NOT NULL,
    aggregate_feature_56       DOUBLE PRECISION NOT NULL,
    aggregate_feature_57       DOUBLE PRECISION NOT NULL,
    aggregate_feature_58       DOUBLE PRECISION NOT NULL,
    aggregate_feature_59       DOUBLE PRECISION NOT NULL,
    aggregate_feature_60       DOUBLE PRECISION NOT NULL,
    aggregate_feature_61       DOUBLE PRECISION NOT NULL,
    aggregate_feature_62       DOUBLE PRECISION NOT NULL,
    aggregate_feature_63       DOUBLE PRECISION NOT NULL,
    aggregate_feature_64       DOUBLE PRECISION NOT NULL,
    aggregate_feature_65       DOUBLE PRECISION NOT NULL,
    aggregate_feature_66       DOUBLE PRECISION NOT NULL,
    aggregate_feature_67       DOUBLE PRECISION NOT NULL,
    aggregate_feature_68       DOUBLE PRECISION NOT NULL,
    aggregate_feature_69       DOUBLE PRECISION NOT NULL,
    aggregate_feature_70       DOUBLE PRECISION NOT NULL,
    aggregate_feature_71       DOUBLE PRECISION NOT NULL,
    aggregate_feature_72       DOUBLE PRECISION NOT NULL,
    CONSTRAINT pk_tx_feature PRIMARY KEY (tx_id, time_step),
    CONSTRAINT fk_tx_feature_transaction FOREIGN KEY (tx_id, time_step)
        REFERENCES core.transaction (tx_id, time_step)
) PARTITION BY RANGE (time_step);

COMMENT ON TABLE core.tx_feature IS
    'Wide 1:1 feature vector per transaction. Range-partitioned on time_step to '
    'match core.transaction; time_step is carried here only because a '
    'partitioned table''s key must include the partition column, not because it '
    'is a new fact -- it is always equal to the owning transaction''s time_step, '
    'enforced by the composite foreign key.';

CREATE TABLE core.tx_feature_p01 PARTITION OF core.tx_feature FOR VALUES FROM (1) TO (2);
CREATE TABLE core.tx_feature_p02 PARTITION OF core.tx_feature FOR VALUES FROM (2) TO (3);
CREATE TABLE core.tx_feature_p03 PARTITION OF core.tx_feature FOR VALUES FROM (3) TO (4);
CREATE TABLE core.tx_feature_p04 PARTITION OF core.tx_feature FOR VALUES FROM (4) TO (5);
CREATE TABLE core.tx_feature_p05 PARTITION OF core.tx_feature FOR VALUES FROM (5) TO (6);
CREATE TABLE core.tx_feature_p06 PARTITION OF core.tx_feature FOR VALUES FROM (6) TO (7);
CREATE TABLE core.tx_feature_p07 PARTITION OF core.tx_feature FOR VALUES FROM (7) TO (8);
CREATE TABLE core.tx_feature_p08 PARTITION OF core.tx_feature FOR VALUES FROM (8) TO (9);
CREATE TABLE core.tx_feature_p09 PARTITION OF core.tx_feature FOR VALUES FROM (9) TO (10);
CREATE TABLE core.tx_feature_p10 PARTITION OF core.tx_feature FOR VALUES FROM (10) TO (11);
CREATE TABLE core.tx_feature_p11 PARTITION OF core.tx_feature FOR VALUES FROM (11) TO (12);
CREATE TABLE core.tx_feature_p12 PARTITION OF core.tx_feature FOR VALUES FROM (12) TO (13);
CREATE TABLE core.tx_feature_p13 PARTITION OF core.tx_feature FOR VALUES FROM (13) TO (14);
CREATE TABLE core.tx_feature_p14 PARTITION OF core.tx_feature FOR VALUES FROM (14) TO (15);
CREATE TABLE core.tx_feature_p15 PARTITION OF core.tx_feature FOR VALUES FROM (15) TO (16);
CREATE TABLE core.tx_feature_p16 PARTITION OF core.tx_feature FOR VALUES FROM (16) TO (17);
CREATE TABLE core.tx_feature_p17 PARTITION OF core.tx_feature FOR VALUES FROM (17) TO (18);
CREATE TABLE core.tx_feature_p18 PARTITION OF core.tx_feature FOR VALUES FROM (18) TO (19);
CREATE TABLE core.tx_feature_p19 PARTITION OF core.tx_feature FOR VALUES FROM (19) TO (20);
CREATE TABLE core.tx_feature_p20 PARTITION OF core.tx_feature FOR VALUES FROM (20) TO (21);
CREATE TABLE core.tx_feature_p21 PARTITION OF core.tx_feature FOR VALUES FROM (21) TO (22);
CREATE TABLE core.tx_feature_p22 PARTITION OF core.tx_feature FOR VALUES FROM (22) TO (23);
CREATE TABLE core.tx_feature_p23 PARTITION OF core.tx_feature FOR VALUES FROM (23) TO (24);
CREATE TABLE core.tx_feature_p24 PARTITION OF core.tx_feature FOR VALUES FROM (24) TO (25);
CREATE TABLE core.tx_feature_p25 PARTITION OF core.tx_feature FOR VALUES FROM (25) TO (26);
CREATE TABLE core.tx_feature_p26 PARTITION OF core.tx_feature FOR VALUES FROM (26) TO (27);
CREATE TABLE core.tx_feature_p27 PARTITION OF core.tx_feature FOR VALUES FROM (27) TO (28);
CREATE TABLE core.tx_feature_p28 PARTITION OF core.tx_feature FOR VALUES FROM (28) TO (29);
CREATE TABLE core.tx_feature_p29 PARTITION OF core.tx_feature FOR VALUES FROM (29) TO (30);
CREATE TABLE core.tx_feature_p30 PARTITION OF core.tx_feature FOR VALUES FROM (30) TO (31);
CREATE TABLE core.tx_feature_p31 PARTITION OF core.tx_feature FOR VALUES FROM (31) TO (32);
CREATE TABLE core.tx_feature_p32 PARTITION OF core.tx_feature FOR VALUES FROM (32) TO (33);
CREATE TABLE core.tx_feature_p33 PARTITION OF core.tx_feature FOR VALUES FROM (33) TO (34);
CREATE TABLE core.tx_feature_p34 PARTITION OF core.tx_feature FOR VALUES FROM (34) TO (35);
CREATE TABLE core.tx_feature_p35 PARTITION OF core.tx_feature FOR VALUES FROM (35) TO (36);
CREATE TABLE core.tx_feature_p36 PARTITION OF core.tx_feature FOR VALUES FROM (36) TO (37);
CREATE TABLE core.tx_feature_p37 PARTITION OF core.tx_feature FOR VALUES FROM (37) TO (38);
CREATE TABLE core.tx_feature_p38 PARTITION OF core.tx_feature FOR VALUES FROM (38) TO (39);
CREATE TABLE core.tx_feature_p39 PARTITION OF core.tx_feature FOR VALUES FROM (39) TO (40);
CREATE TABLE core.tx_feature_p40 PARTITION OF core.tx_feature FOR VALUES FROM (40) TO (41);
CREATE TABLE core.tx_feature_p41 PARTITION OF core.tx_feature FOR VALUES FROM (41) TO (42);
CREATE TABLE core.tx_feature_p42 PARTITION OF core.tx_feature FOR VALUES FROM (42) TO (43);
CREATE TABLE core.tx_feature_p43 PARTITION OF core.tx_feature FOR VALUES FROM (43) TO (44);
CREATE TABLE core.tx_feature_p44 PARTITION OF core.tx_feature FOR VALUES FROM (44) TO (45);
CREATE TABLE core.tx_feature_p45 PARTITION OF core.tx_feature FOR VALUES FROM (45) TO (46);
CREATE TABLE core.tx_feature_p46 PARTITION OF core.tx_feature FOR VALUES FROM (46) TO (47);
CREATE TABLE core.tx_feature_p47 PARTITION OF core.tx_feature FOR VALUES FROM (47) TO (48);
CREATE TABLE core.tx_feature_p48 PARTITION OF core.tx_feature FOR VALUES FROM (48) TO (49);
CREATE TABLE core.tx_feature_p49 PARTITION OF core.tx_feature FOR VALUES FROM (49) TO (50);

INSERT INTO core.tx_feature (tx_id, time_step, local_feature_1,
    local_feature_2,
    local_feature_3,
    local_feature_4,
    local_feature_5,
    local_feature_6,
    local_feature_7,
    local_feature_8,
    local_feature_9,
    local_feature_10,
    local_feature_11,
    local_feature_12,
    local_feature_13,
    local_feature_14,
    local_feature_15,
    local_feature_16,
    local_feature_17,
    local_feature_18,
    local_feature_19,
    local_feature_20,
    local_feature_21,
    local_feature_22,
    local_feature_23,
    local_feature_24,
    local_feature_25,
    local_feature_26,
    local_feature_27,
    local_feature_28,
    local_feature_29,
    local_feature_30,
    local_feature_31,
    local_feature_32,
    local_feature_33,
    local_feature_34,
    local_feature_35,
    local_feature_36,
    local_feature_37,
    local_feature_38,
    local_feature_39,
    local_feature_40,
    local_feature_41,
    local_feature_42,
    local_feature_43,
    local_feature_44,
    local_feature_45,
    local_feature_46,
    local_feature_47,
    local_feature_48,
    local_feature_49,
    local_feature_50,
    local_feature_51,
    local_feature_52,
    local_feature_53,
    local_feature_54,
    local_feature_55,
    local_feature_56,
    local_feature_57,
    local_feature_58,
    local_feature_59,
    local_feature_60,
    local_feature_61,
    local_feature_62,
    local_feature_63,
    local_feature_64,
    local_feature_65,
    local_feature_66,
    local_feature_67,
    local_feature_68,
    local_feature_69,
    local_feature_70,
    local_feature_71,
    local_feature_72,
    local_feature_73,
    local_feature_74,
    local_feature_75,
    local_feature_76,
    local_feature_77,
    local_feature_78,
    local_feature_79,
    local_feature_80,
    local_feature_81,
    local_feature_82,
    local_feature_83,
    local_feature_84,
    local_feature_85,
    local_feature_86,
    local_feature_87,
    local_feature_88,
    local_feature_89,
    local_feature_90,
    local_feature_91,
    local_feature_92,
    local_feature_93,
    aggregate_feature_1,
    aggregate_feature_2,
    aggregate_feature_3,
    aggregate_feature_4,
    aggregate_feature_5,
    aggregate_feature_6,
    aggregate_feature_7,
    aggregate_feature_8,
    aggregate_feature_9,
    aggregate_feature_10,
    aggregate_feature_11,
    aggregate_feature_12,
    aggregate_feature_13,
    aggregate_feature_14,
    aggregate_feature_15,
    aggregate_feature_16,
    aggregate_feature_17,
    aggregate_feature_18,
    aggregate_feature_19,
    aggregate_feature_20,
    aggregate_feature_21,
    aggregate_feature_22,
    aggregate_feature_23,
    aggregate_feature_24,
    aggregate_feature_25,
    aggregate_feature_26,
    aggregate_feature_27,
    aggregate_feature_28,
    aggregate_feature_29,
    aggregate_feature_30,
    aggregate_feature_31,
    aggregate_feature_32,
    aggregate_feature_33,
    aggregate_feature_34,
    aggregate_feature_35,
    aggregate_feature_36,
    aggregate_feature_37,
    aggregate_feature_38,
    aggregate_feature_39,
    aggregate_feature_40,
    aggregate_feature_41,
    aggregate_feature_42,
    aggregate_feature_43,
    aggregate_feature_44,
    aggregate_feature_45,
    aggregate_feature_46,
    aggregate_feature_47,
    aggregate_feature_48,
    aggregate_feature_49,
    aggregate_feature_50,
    aggregate_feature_51,
    aggregate_feature_52,
    aggregate_feature_53,
    aggregate_feature_54,
    aggregate_feature_55,
    aggregate_feature_56,
    aggregate_feature_57,
    aggregate_feature_58,
    aggregate_feature_59,
    aggregate_feature_60,
    aggregate_feature_61,
    aggregate_feature_62,
    aggregate_feature_63,
    aggregate_feature_64,
    aggregate_feature_65,
    aggregate_feature_66,
    aggregate_feature_67,
    aggregate_feature_68,
    aggregate_feature_69,
    aggregate_feature_70,
    aggregate_feature_71,
    aggregate_feature_72)
SELECT f.tx_id, t.time_step, local_feature_1,
    local_feature_2,
    local_feature_3,
    local_feature_4,
    local_feature_5,
    local_feature_6,
    local_feature_7,
    local_feature_8,
    local_feature_9,
    local_feature_10,
    local_feature_11,
    local_feature_12,
    local_feature_13,
    local_feature_14,
    local_feature_15,
    local_feature_16,
    local_feature_17,
    local_feature_18,
    local_feature_19,
    local_feature_20,
    local_feature_21,
    local_feature_22,
    local_feature_23,
    local_feature_24,
    local_feature_25,
    local_feature_26,
    local_feature_27,
    local_feature_28,
    local_feature_29,
    local_feature_30,
    local_feature_31,
    local_feature_32,
    local_feature_33,
    local_feature_34,
    local_feature_35,
    local_feature_36,
    local_feature_37,
    local_feature_38,
    local_feature_39,
    local_feature_40,
    local_feature_41,
    local_feature_42,
    local_feature_43,
    local_feature_44,
    local_feature_45,
    local_feature_46,
    local_feature_47,
    local_feature_48,
    local_feature_49,
    local_feature_50,
    local_feature_51,
    local_feature_52,
    local_feature_53,
    local_feature_54,
    local_feature_55,
    local_feature_56,
    local_feature_57,
    local_feature_58,
    local_feature_59,
    local_feature_60,
    local_feature_61,
    local_feature_62,
    local_feature_63,
    local_feature_64,
    local_feature_65,
    local_feature_66,
    local_feature_67,
    local_feature_68,
    local_feature_69,
    local_feature_70,
    local_feature_71,
    local_feature_72,
    local_feature_73,
    local_feature_74,
    local_feature_75,
    local_feature_76,
    local_feature_77,
    local_feature_78,
    local_feature_79,
    local_feature_80,
    local_feature_81,
    local_feature_82,
    local_feature_83,
    local_feature_84,
    local_feature_85,
    local_feature_86,
    local_feature_87,
    local_feature_88,
    local_feature_89,
    local_feature_90,
    local_feature_91,
    local_feature_92,
    local_feature_93,
    aggregate_feature_1,
    aggregate_feature_2,
    aggregate_feature_3,
    aggregate_feature_4,
    aggregate_feature_5,
    aggregate_feature_6,
    aggregate_feature_7,
    aggregate_feature_8,
    aggregate_feature_9,
    aggregate_feature_10,
    aggregate_feature_11,
    aggregate_feature_12,
    aggregate_feature_13,
    aggregate_feature_14,
    aggregate_feature_15,
    aggregate_feature_16,
    aggregate_feature_17,
    aggregate_feature_18,
    aggregate_feature_19,
    aggregate_feature_20,
    aggregate_feature_21,
    aggregate_feature_22,
    aggregate_feature_23,
    aggregate_feature_24,
    aggregate_feature_25,
    aggregate_feature_26,
    aggregate_feature_27,
    aggregate_feature_28,
    aggregate_feature_29,
    aggregate_feature_30,
    aggregate_feature_31,
    aggregate_feature_32,
    aggregate_feature_33,
    aggregate_feature_34,
    aggregate_feature_35,
    aggregate_feature_36,
    aggregate_feature_37,
    aggregate_feature_38,
    aggregate_feature_39,
    aggregate_feature_40,
    aggregate_feature_41,
    aggregate_feature_42,
    aggregate_feature_43,
    aggregate_feature_44,
    aggregate_feature_45,
    aggregate_feature_46,
    aggregate_feature_47,
    aggregate_feature_48,
    aggregate_feature_49,
    aggregate_feature_50,
    aggregate_feature_51,
    aggregate_feature_52,
    aggregate_feature_53,
    aggregate_feature_54,
    aggregate_feature_55,
    aggregate_feature_56,
    aggregate_feature_57,
    aggregate_feature_58,
    aggregate_feature_59,
    aggregate_feature_60,
    aggregate_feature_61,
    aggregate_feature_62,
    aggregate_feature_63,
    aggregate_feature_64,
    aggregate_feature_65,
    aggregate_feature_66,
    aggregate_feature_67,
    aggregate_feature_68,
    aggregate_feature_69,
    aggregate_feature_70,
    aggregate_feature_71,
    aggregate_feature_72
FROM core.tx_feature_unpartitioned f
JOIN core.transaction_unpartitioned t ON t.tx_id = f.tx_id;

-- ---------------------------------------------------------------------------
-- 5. Drop the unpartitioned originals now that both new tables are populated
--    and nothing references them.
-- ---------------------------------------------------------------------------
DROP TABLE core.tx_feature_unpartitioned;
DROP TABLE core.transaction_unpartitioned;

COMMIT;

-- ---------------------------------------------------------------------------
-- 6. Rebuild indexes, extended statistics, and the analytics + analysis
--    layers against the new partitioned tables. Run these three files after
--    this script:
--
--     psql -d elliptic_aml -f sql/02_indexes.sql
--     psql -d elliptic_aml -f sql/03_analytics.sql
--     psql -d elliptic_aml -f sql/04_analysis.sql
-- ---------------------------------------------------------------------------
