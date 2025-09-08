--
-- PostgreSQL database dump
--

\restrict YDkuXu6v8AfbOjMaaBcIptLxjYKzbkgaGfKuCBoCxtHfYf7rhBZVMc1ovEwHXJf

-- Dumped from database version 16.10 (Debian 16.10-1.pgdg13+1)
-- Dumped by pg_dump version 16.10 (Debian 16.10-1.pgdg13+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- Name: cleanup_expired_cache(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.cleanup_expired_cache() RETURNS integer
    LANGUAGE plpgsql
    AS $$
  DECLARE
    deleted_count INTEGER;
  BEGIN
    DELETE FROM census_data_cache 
    WHERE expires_at < NOW();
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
  END;
  $$;


--
-- Name: generate_cache_hash(text, integer, text[], jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_cache_hash(dataset_code text, year integer, variables text[], geography_spec jsonb) RETURNS text
    LANGUAGE plpgsql IMMUTABLE
    AS $$
    BEGIN
        RETURN encode(
            digest(
                dataset_code || year::TEXT || array_to_string(variables, ',') || geography_spec::TEXT,
                'sha256'
            ),
            'hex'
        );
    END;
    $$;


--
-- Name: get_cache_stats(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_cache_stats() RETURNS TABLE(total_entries bigint, expired_entries bigint, cache_size_mb numeric, most_accessed_dataset character varying, avg_response_size_kb numeric)
    LANGUAGE plpgsql
    AS $$
  BEGIN
    RETURN QUERY
    SELECT 
      COUNT(*) as total_entries,
      COUNT(*) FILTER (WHERE expires_at < NOW()) as expired_entries,
      ROUND(
        SUM(octet_length(response_data::text))::NUMERIC / (1024 * 1024), 
        2
      ) as cache_size_mb,
      (
        SELECT dataset_code 
        FROM census_data_cache 
        GROUP BY dataset_code 
        ORDER BY COUNT(*) DESC 
        LIMIT 1
      ) as most_accessed_dataset,
      ROUND(
        AVG(octet_length(response_data::text))::NUMERIC / 1024, 
        2
      ) as avg_response_size_kb
    FROM census_data_cache;
  END;
  $$;


--
-- Name: optimize_database(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.optimize_database() RETURNS text
    LANGUAGE plpgsql
    AS $$
  DECLARE
    result_message TEXT;
  BEGIN
    -- Analyze all tables to update statistics
    ANALYZE places;
    ANALYZE census_data_cache;
    
    -- Vacuum to reclaim space
    VACUUM places;
    VACUUM census_data_cache;
    
    result_message := 'Database optimization completed at ' || NOW()::TEXT;
    
    RETURN result_message;
  END;
  $$;


--
-- Name: search_geographies(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.search_geographies(search_term text, result_limit integer DEFAULT 10) RETURNS TABLE(id integer, name text, summary_level_name text, latitude numeric, longitude numeric, for_param text, in_param text, weighted_score real)
    LANGUAGE sql
    AS $$
  SELECT 
    g.id,
    g.name,
    sl.name as summary_level_name,
    g.latitude,
    g.longitude,
    g.for_param,
    g.in_param,
    -- Weighted score: similarity + hierarchy boost
    (SIMILARITY(g.name, search_term) + (1.0 - (sl.hierarchy_level::real / 100.0))) as weighted_score
  FROM geographies g
  LEFT JOIN summary_levels sl ON g.summary_level_code = sl.code
  WHERE 
    g.name % search_term  -- Uses trigram similarity operator
    OR g.name ILIKE '%' || search_term || '%'  -- Fallback for partial matches
  ORDER BY 
    weighted_score DESC,  -- Combined similarity + hierarchy score
    LENGTH(g.name) ASC,   -- Prefer shorter names when scores are equal
    g.name ASC
  LIMIT result_limit;
$$;


--
-- Name: search_geographies_by_summary_level(text, text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.search_geographies_by_summary_level(search_term text, summary_level_code text, result_limit integer DEFAULT 10) RETURNS TABLE(id integer, name text, summary_level_name text, latitude numeric, longitude numeric, for_param text, in_param text, similarity real)
    LANGUAGE sql
    AS $$
	SELECT 
	  g.id,
	  g.name,
	  sl.name as summary_level_name,
	  g.latitude,
	  g.longitude,
	  g.for_param,
	  g.in_param,
	  SIMILARITY(g.name, search_term) as similarity
	FROM geographies g
	LEFT JOIN summary_levels sl ON g.summary_level_code = sl.code
	WHERE 
	  g.summary_level_code = summary_level_code
	  AND (
	    g.name % search_term  -- Uses trigram similarity operator
	    OR g.name ILIKE '%' || search_term || '%'  -- Fallback for partial matches
	  )
	ORDER BY 
	  SIMILARITY(g.name, search_term) DESC,
	  LENGTH(g.name) ASC,   -- Prefer shorter names when similarity is equal
	  g.name ASC
	LIMIT result_limit;
$$;


--
-- Name: search_summary_levels(text, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.search_summary_levels(search_term text, result_limit integer DEFAULT 1) RETURNS TABLE(code text, name text)
    LANGUAGE sql
    AS $_$
  SELECT 
    sl.code as code,
    sl.name as name
  FROM summary_levels sl
  WHERE 
    sl.code = LPAD($1, 3, '0')  -- exact code match
    OR LOWER(sl.name) = LOWER(TRIM($1))  -- exact name match
    OR SIMILARITY(LOWER(sl.name), LOWER(TRIM($1))) > 0.3  -- fuzzy name match
  ORDER BY 
    CASE 
      WHEN sl.code = LPAD($1, 3, '0') THEN 1.00
      WHEN LOWER(sl.name) = LOWER(TRIM($1)) THEN 1.00
      ELSE SIMILARITY(LOWER(sl.name), LOWER(TRIM($1)))
    END DESC,
    CASE 
      WHEN sl.code = LPAD($1, 3, '0') THEN 1
      WHEN LOWER(sl.name) = LOWER(TRIM($1)) THEN 2
      ELSE 3
    END
  LIMIT COALESCE($2, 5)
$_$;


--
-- Name: update_cache_accessed(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_cache_accessed() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
        -- Only update if the last_accessed is more than 1 hour old to avoid too many updates
        IF OLD.last_accessed < NOW() - INTERVAL '1 hour' THEN
            NEW.last_accessed = NOW();
        END IF;
        RETURN NEW;
    END;
    $$;


--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
        NEW.updated_at = NOW();
        RETURN NEW;
    END;
    $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: census_data_cache; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.census_data_cache (
    id bigint NOT NULL,
    request_hash character varying(64) NOT NULL,
    dataset_code character varying(50) NOT NULL,
    year integer NOT NULL,
    variables text[],
    geography_spec jsonb NOT NULL,
    response_data jsonb NOT NULL,
    row_count integer,
    expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    last_accessed timestamp with time zone DEFAULT now()
);


--
-- Name: census_data_cache_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.census_data_cache_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: census_data_cache_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.census_data_cache_id_seq OWNED BY public.census_data_cache.id;


--
-- Name: geographies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.geographies (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    full_name character varying(500),
    state_code character(2),
    state_name character varying(100),
    county_code character(3),
    county_name character varying(100),
    fips_code character varying(15),
    census_geoid character varying(20),
    ucgid_code character varying(20),
    parent_geography_id bigint,
    latitude numeric(10,7),
    longitude numeric(11,7),
    population integer,
    land_area_sqkm numeric(12,4),
    water_area_sqkm numeric(12,4),
    elevation_meters integer,
    year integer DEFAULT 2022,
    is_active boolean DEFAULT true,
    data_source character varying(100),
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    predecessor_geoid character varying(20),
    successor_geoid character varying(20),
    geoid_change_reason character varying(100),
    summary_level_id bigint,
    for_param character varying(25),
    in_param character varying(25),
    summary_level_code character varying(3),
    region_code character(1),
    division_code character(1)
);


--
-- Name: summary_levels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.summary_levels (
    id bigint NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    get_variable character varying(20) NOT NULL,
    query_name character varying(255) NOT NULL,
    on_spine boolean NOT NULL,
    parent_summary_level_id bigint,
    code text,
    parent_summary_level text,
    hierarchy_level integer DEFAULT 99
);


--
-- Name: geography_levels_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.geography_levels_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: geography_levels_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.geography_levels_id_seq OWNED BY public.summary_levels.id;


--
-- Name: geography_years; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.geography_years (
    id bigint NOT NULL,
    geography_id bigint NOT NULL,
    year_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: geography_years_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.geography_years_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: geography_years_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.geography_years_id_seq OWNED BY public.geography_years.id;


--
-- Name: pgmigrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pgmigrations (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    run_on timestamp without time zone NOT NULL
);


--
-- Name: pgmigrations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.pgmigrations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: pgmigrations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.pgmigrations_id_seq OWNED BY public.pgmigrations.id;


--
-- Name: places_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.places_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: places_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.places_id_seq OWNED BY public.geographies.id;


--
-- Name: years; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.years (
    id bigint NOT NULL,
    year integer NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: years_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.years_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: years_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.years_id_seq OWNED BY public.years.id;


--
-- Name: census_data_cache id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.census_data_cache ALTER COLUMN id SET DEFAULT nextval('public.census_data_cache_id_seq'::regclass);


--
-- Name: geographies id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.geographies ALTER COLUMN id SET DEFAULT nextval('public.places_id_seq'::regclass);


--
-- Name: geography_years id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.geography_years ALTER COLUMN id SET DEFAULT nextval('public.geography_years_id_seq'::regclass);


--
-- Name: pgmigrations id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pgmigrations ALTER COLUMN id SET DEFAULT nextval('public.pgmigrations_id_seq'::regclass);


--
-- Name: summary_levels id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.summary_levels ALTER COLUMN id SET DEFAULT nextval('public.geography_levels_id_seq'::regclass);


--
-- Name: years id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.years ALTER COLUMN id SET DEFAULT nextval('public.years_id_seq'::regclass);


--
-- Name: census_data_cache census_data_cache_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.census_data_cache
    ADD CONSTRAINT census_data_cache_pkey PRIMARY KEY (id);


--
-- Name: census_data_cache census_data_cache_request_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.census_data_cache
    ADD CONSTRAINT census_data_cache_request_hash_key UNIQUE (request_hash);


--
-- Name: geographies geographies_fips_code_year_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.geographies
    ADD CONSTRAINT geographies_fips_code_year_unique UNIQUE (fips_code, year);


--
-- Name: geographies geographies_ucgid_code_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.geographies
    ADD CONSTRAINT geographies_ucgid_code_unique UNIQUE (ucgid_code);


--
-- Name: summary_levels geography_levels_get_variable_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.summary_levels
    ADD CONSTRAINT geography_levels_get_variable_key UNIQUE (get_variable);


--
-- Name: summary_levels geography_levels_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.summary_levels
    ADD CONSTRAINT geography_levels_name_key UNIQUE (name);


--
-- Name: summary_levels geography_levels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.summary_levels
    ADD CONSTRAINT geography_levels_pkey PRIMARY KEY (id);


--
-- Name: summary_levels geography_levels_query_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.summary_levels
    ADD CONSTRAINT geography_levels_query_name_key UNIQUE (query_name);


--
-- Name: summary_levels geography_levels_summary_level_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.summary_levels
    ADD CONSTRAINT geography_levels_summary_level_key UNIQUE (code);


--
-- Name: geography_years geography_years_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.geography_years
    ADD CONSTRAINT geography_years_pkey PRIMARY KEY (id);


--
-- Name: geography_years geography_years_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.geography_years
    ADD CONSTRAINT geography_years_unique UNIQUE (geography_id, year_id);


--
-- Name: pgmigrations pgmigrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pgmigrations
    ADD CONSTRAINT pgmigrations_pkey PRIMARY KEY (id);


--
-- Name: geographies places_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.geographies
    ADD CONSTRAINT places_pkey PRIMARY KEY (id);


--
-- Name: years years_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.years
    ADD CONSTRAINT years_pkey PRIMARY KEY (id);


--
-- Name: years years_year_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.years
    ADD CONSTRAINT years_year_key UNIQUE (year);


--
-- Name: census_data_cache_dataset_code_year_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX census_data_cache_dataset_code_year_index ON public.census_data_cache USING btree (dataset_code, year);


--
-- Name: census_data_cache_expires_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX census_data_cache_expires_at_index ON public.census_data_cache USING btree (expires_at);


--
-- Name: census_data_cache_last_accessed_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX census_data_cache_last_accessed_index ON public.census_data_cache USING btree (last_accessed);


--
-- Name: census_data_cache_request_hash_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX census_data_cache_request_hash_index ON public.census_data_cache USING btree (request_hash);


--
-- Name: geographies_division_code_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX geographies_division_code_index ON public.geographies USING btree (division_code);


--
-- Name: geographies_fips_code_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX geographies_fips_code_index ON public.geographies USING btree (fips_code);


--
-- Name: geographies_latitude_longitude_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX geographies_latitude_longitude_index ON public.geographies USING btree (latitude, longitude);


--
-- Name: geographies_parent_geography_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX geographies_parent_geography_id_index ON public.geographies USING btree (parent_geography_id);


--
-- Name: geographies_region_code_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX geographies_region_code_index ON public.geographies USING btree (region_code);


--
-- Name: geographies_state_code_county_code_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX geographies_state_code_county_code_index ON public.geographies USING btree (state_code, county_code);


--
-- Name: geographies_state_code_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX geographies_state_code_index ON public.geographies USING btree (state_code);


--
-- Name: geographies_summary_level_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX geographies_summary_level_id_index ON public.geographies USING btree (summary_level_id);


--
-- Name: geographies_ucgid_code_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX geographies_ucgid_code_index ON public.geographies USING btree (ucgid_code);


--
-- Name: geographies_year_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX geographies_year_index ON public.geographies USING btree (year);


--
-- Name: geography_levels_parent_summary_level_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX geography_levels_parent_summary_level_index ON public.summary_levels USING btree (parent_summary_level);


--
-- Name: geography_levels_summary_level_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX geography_levels_summary_level_index ON public.summary_levels USING btree (code);


--
-- Name: geography_years_geography_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX geography_years_geography_id_index ON public.geography_years USING btree (geography_id);


--
-- Name: geography_years_year_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX geography_years_year_id_index ON public.geography_years USING btree (year_id);


--
-- Name: idx_census_data_cache_geography; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_census_data_cache_geography ON public.census_data_cache USING gin (geography_spec);


--
-- Name: idx_geographies_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_geographies_active ON public.geographies USING btree (is_active) WHERE (is_active = true);


--
-- Name: idx_geographies_full_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_geographies_full_name ON public.geographies USING gin (to_tsvector('english'::regconfig, (full_name)::text));


--
-- Name: idx_geographies_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_geographies_name ON public.geographies USING gin (to_tsvector('english'::regconfig, (name)::text));


--
-- Name: idx_geographies_population; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_geographies_population ON public.geographies USING btree (population DESC) WHERE (population IS NOT NULL);


--
-- Name: idx_geographies_predecessor_geoid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_geographies_predecessor_geoid ON public.geographies USING btree (predecessor_geoid) WHERE (predecessor_geoid IS NOT NULL);


--
-- Name: idx_geographies_successor_geoid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_geographies_successor_geoid ON public.geographies USING btree (successor_geoid) WHERE (successor_geoid IS NOT NULL);


--
-- Name: idx_summary_levels_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_summary_levels_code ON public.summary_levels USING btree (code);


--
-- Name: idx_summary_levels_name_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_summary_levels_name_gin ON public.summary_levels USING gin (name public.gin_trgm_ops);


--
-- Name: summary_levels_parent_summary_level_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX summary_levels_parent_summary_level_id_index ON public.summary_levels USING btree (parent_summary_level_id);


--
-- Name: census_data_cache update_census_data_cache_accessed; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_census_data_cache_accessed BEFORE UPDATE OF response_data ON public.census_data_cache FOR EACH ROW EXECUTE FUNCTION public.update_cache_accessed();


--
-- Name: geographies update_geographies_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER update_geographies_updated_at BEFORE UPDATE ON public.geographies FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: summary_levels geography_levels_parent_geography_level_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.summary_levels
    ADD CONSTRAINT geography_levels_parent_geography_level_id_fkey FOREIGN KEY (parent_summary_level_id) REFERENCES public.summary_levels(id);


--
-- Name: geography_years geography_years_geography_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.geography_years
    ADD CONSTRAINT geography_years_geography_id_fkey FOREIGN KEY (geography_id) REFERENCES public.geographies(id) ON DELETE CASCADE;


--
-- Name: geography_years geography_years_year_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.geography_years
    ADD CONSTRAINT geography_years_year_id_fkey FOREIGN KEY (year_id) REFERENCES public.years(id) ON DELETE CASCADE;


--
-- Name: geographies places_geography_level_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.geographies
    ADD CONSTRAINT places_geography_level_id_fkey FOREIGN KEY (summary_level_id) REFERENCES public.summary_levels(id);


--
-- Name: geographies places_parent_place_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.geographies
    ADD CONSTRAINT places_parent_place_id_fkey FOREIGN KEY (parent_geography_id) REFERENCES public.geographies(id);


--
-- PostgreSQL database dump complete
--

\unrestrict YDkuXu6v8AfbOjMaaBcIptLxjYKzbkgaGfKuCBoCxtHfYf7rhBZVMc1ovEwHXJf

