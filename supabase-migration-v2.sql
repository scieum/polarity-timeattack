-- ============================================================
-- Migration v2: add school_name, rewrite functions with jsonb
-- Run this ONCE in Supabase SQL Editor (safe on existing data).
-- ============================================================

-- Add school_name column if not present
alter table quiz_users    add column if not exists school_name text;
alter table quiz_rankings add column if not exists school_name text;

-- Drop old function signatures (we're changing return types / params)
drop function if exists register_user(text, text);
drop function if exists submit_score(text, text, int, int);
drop function if exists get_top_ranking(int);
drop function if exists get_neighbors(text, int);

-- ---------- register_user ----------
create or replace function register_user(
  p_nickname text,
  p_pin_hash text,
  p_school_name text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nick text := btrim(p_nickname);
  v_school text := btrim(coalesce(p_school_name, ''));
  v_id uuid;
begin
  if length(v_nick) < 1 or length(v_nick) > 20 then raise exception 'NICKNAME_LENGTH'; end if;
  if length(p_pin_hash) < 16 then raise exception 'PIN_HASH_INVALID'; end if;
  if exists (select 1 from quiz_users where nickname = v_nick) then raise exception 'NICKNAME_TAKEN'; end if;

  insert into quiz_users (nickname, pin_hash, school_name)
  values (v_nick, p_pin_hash, nullif(v_school, ''))
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------- submit_score (returns jsonb — robust) ----------
create or replace function submit_score(
  p_nickname text,
  p_pin_hash text,
  p_mistakes int,
  p_time_seconds int
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_school  text;
  v_nick    text := btrim(p_nickname);
  v_prev_m  int;
  v_prev_t  int;
  v_best_m  int;
  v_best_t  int;
  v_updated boolean := false;
begin
  select id, school_name into v_user_id, v_school
    from quiz_users
   where nickname = v_nick and pin_hash = p_pin_hash;
  if v_user_id is null then raise exception 'AUTH_FAILED'; end if;

  if p_mistakes     < 0 or p_mistakes     > 500   then raise exception 'BAD_MISTAKES'; end if;
  if p_time_seconds < 0 or p_time_seconds > 36000 then raise exception 'BAD_TIME';     end if;

  select mistakes, time_seconds into v_prev_m, v_prev_t
    from quiz_rankings where user_id = v_user_id;

  if v_prev_m is null then
    insert into quiz_rankings (user_id, nickname, school_name, mistakes, time_seconds, updated_at)
    values (v_user_id, v_nick, v_school, p_mistakes, p_time_seconds, now());
    v_updated := true;
    v_best_m  := p_mistakes;
    v_best_t  := p_time_seconds;
  elsif (p_mistakes < v_prev_m) or (p_mistakes = v_prev_m and p_time_seconds < v_prev_t) then
    update quiz_rankings
       set mistakes     = p_mistakes,
           time_seconds = p_time_seconds,
           nickname     = v_nick,
           school_name  = v_school,
           updated_at   = now()
     where user_id = v_user_id;
    v_updated := true;
    v_best_m  := p_mistakes;
    v_best_t  := p_time_seconds;
  else
    v_best_m := v_prev_m;
    v_best_t := v_prev_t;
  end if;

  return jsonb_build_object(
    'updated',       v_updated,
    'prev_mistakes', v_prev_m,
    'prev_time',     v_prev_t,
    'best_mistakes', v_best_m,
    'best_time',     v_best_t
  );
end;
$$;

-- ---------- get_top_ranking ----------
create or replace function get_top_ranking(p_limit int default 20)
returns table (
  rank int,
  nickname text,
  school_name text,
  mistakes int,
  time_seconds int,
  updated_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    row_number() over (order by mistakes asc, time_seconds asc, updated_at asc)::int as rank,
    nickname, school_name, mistakes, time_seconds, updated_at
  from quiz_rankings
  order by mistakes asc, time_seconds asc, updated_at asc
  limit greatest(1, least(p_limit, 100));
$$;

-- ---------- get_neighbors ----------
create or replace function get_neighbors(
  p_nickname text,
  p_window int default 3
) returns table (
  rank int,
  nickname text,
  school_name text,
  mistakes int,
  time_seconds int,
  updated_at timestamptz,
  is_me boolean,
  my_rank int,
  total int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nick text := btrim(p_nickname);
  v_my_rank int;
  v_total int;
  v_window int := greatest(1, least(p_window, 10));
begin
  select count(*) into v_total from quiz_rankings;
  if v_total = 0 then return; end if;

  with ordered as (
    select nickname, school_name, mistakes, time_seconds, updated_at,
           row_number() over (order by mistakes asc, time_seconds asc, updated_at asc)::int as r
      from quiz_rankings
  )
  select r into v_my_rank from ordered where nickname = v_nick;
  if v_my_rank is null then return; end if;

  return query
  with ordered as (
    select nickname, school_name, mistakes, time_seconds, updated_at,
           row_number() over (order by mistakes asc, time_seconds asc, updated_at asc)::int as r
      from quiz_rankings
  )
  select o.r, o.nickname, o.school_name, o.mistakes, o.time_seconds, o.updated_at,
         (o.nickname = v_nick) as is_me,
         v_my_rank, v_total
    from ordered o
   where o.r between (v_my_rank - v_window) and (v_my_rank + v_window)
   order by o.r asc;
end;
$$;

-- Grants
grant execute on function register_user(text, text, text)              to anon, authenticated;
grant execute on function submit_score(text, text, int, int)           to anon, authenticated;
grant execute on function get_top_ranking(int)                         to anon, authenticated;
grant execute on function get_neighbors(text, int)                     to anon, authenticated;
