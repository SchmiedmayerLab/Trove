-- This source file is part of the Trove open-source project
-- SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
-- SPDX-License-Identifier: MIT

\getenv runtime_name DATABASE_USERNAME
BEGIN;
SELECT pg_advisory_xact_lock(hashtext('trove-runtime-provisioning'));
SELECT to_regclass('public.audit_events') IS NULL
    OR to_regclass('public._fluent_migrations') IS NULL AS missing_schema
\gset
\if :missing_schema
    DO $$ BEGIN RAISE EXCEPTION 'Initialize the database schema before granting runtime access'; END $$;
\endif

SELECT format('CREATE ROLE %I NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', :'runtime_name')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'runtime_name')
\gexec
SELECT EXISTS (
    SELECT 1 FROM pg_roles role WHERE role.rolname = :'runtime_name' AND (
        role.rolsuper OR role.rolinherit OR role.rolcreatedb OR role.rolcreaterole OR role.rolreplication OR role.rolbypassrls
        OR EXISTS (SELECT 1 FROM pg_auth_members WHERE member = role.oid)
        OR EXISTS (SELECT 1 FROM pg_database WHERE datdba = role.oid)
        OR EXISTS (SELECT 1 FROM pg_namespace WHERE nspowner = role.oid)
        OR EXISTS (SELECT 1 FROM pg_class WHERE relowner = role.oid)
        OR EXISTS (SELECT 1 FROM pg_proc WHERE proowner = role.oid)
    )
) AS unsafe_role
\gset
\if :unsafe_role
    DO $$ BEGIN RAISE EXCEPTION 'Refusing to repurpose an owner, privileged, or member role as the application login'; END $$;
\endif

REVOKE CREATE ON SCHEMA public FROM PUBLIC;
SELECT format('REVOKE CREATE, TEMPORARY ON DATABASE %I FROM PUBLIC', current_database()) \gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM %I', current_database(), :'runtime_name') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'runtime_name') \gexec
REVOKE ALL ON SCHEMA public FROM :"runtime_name";
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM :"runtime_name";
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM :"runtime_name";
GRANT USAGE ON SCHEMA public TO :"runtime_name";
GRANT SELECT, INSERT, UPDATE, DELETE ON
    public.groups, public.studies, public.components, public.component_schedules,
    public.participants, public.invitation_codes, public.enrollments, public.stored_artifacts
TO :"runtime_name";
GRANT SELECT, INSERT ON public.published_studies, public.enrollment_consents TO :"runtime_name";
GRANT SELECT, INSERT ON public.source_bindings TO :"runtime_name";
GRANT UPDATE (revoked_at) ON public.source_bindings TO :"runtime_name";
GRANT SELECT, INSERT ON public.audit_events TO :"runtime_name";
GRANT SELECT, INSERT ON public.clinical_events, public.clinical_event_nodes,
    public.clinical_point_facts, public.study_data_grants, public.clinical_source_records,
    public.clinical_record_events, public.clinical_output_bindings, public.clinical_output_retractions,
    public.clinical_questionnaire_contexts, public.clinical_point_derivations,
    public.clinical_attribution_commands TO :"runtime_name";

-- The only definer bridge reveals a Boolean, never settings, paths or privileged operations.
CREATE OR REPLACE FUNCTION public.trove_timescale_preloaded() RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog
AS $$
    SELECT EXISTS (
        SELECT 1 FROM unnest(string_to_array(current_setting('shared_preload_libraries'), ',')) AS library(name)
        WHERE btrim(name) = 'timescaledb'
    )
$$;
SELECT format('ALTER FUNCTION public.trove_timescale_preloaded() OWNER TO %I', current_user) \gexec
REVOKE ALL ON FUNCTION public.trove_timescale_preloaded() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.trove_timescale_preloaded() TO :"runtime_name";
COMMIT;
