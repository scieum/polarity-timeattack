-- ============================================================
-- Polarity Time Attack — Ranking System Schema
-- ============================================================
-- Run this entire file in Supabase SQL Editor once per project.
-- It creates tables, RLS policies, and RPC functions used by the quiz.
-- ------------------------------------------------------------

-- 1) USERS: nickname + hashed PIN (SHA-256 client-side)
create table if not exists quiz_users (
  id uuid primary key default gen_random_uuid(),
  nickname text unique not null,
  pin_hash text not null,
  created_at timestamptz not null default now()
);
create index if not exists quiz_users_nickname_idx on quiz_users (nickname);

-- 2) RANKINGS: one best record per user
create table if not exists quiz_rankings (
  user_id uuid primary key references quiz_users(id) on delete cascade,
  nickname text not null,
  mistakes int not null check (mistakes >= 0),
  time_seconds int not null check (time_seconds >= 0),
  updated_at timestamptz not null default now()
);
-- Leaderboard ordering: fewer mistakes first, then faster time, then earlier update
create index if not exists quiz_rankings_order_idx
  on quiz_rankings (mistakes asc, time_seconds asc, updated_at asc);

-- ------------------------------------------------------------
-- ROW LEVEL SECURITY
-- ------------------------------------------------------------
alter table quiz_users enable row level security;
alter table quiz_rankings enable row level security;

-- Users table: no direct client access (RPCs with SECURITY DEFINER handle it)
drop policy if exists "quiz_users_no_direct" on quiz_users;

-- Rankings: allow anyone (anon) to read the leaderboard
drop policy if exists "quiz_rankings_public_read" on quiz_rankings;
create policy "quiz_rankings_public_read"
  on quiz_rankings for select
  to anon, authenticated
  using (true);
-- No insert/update/delete policies → mutations only through RPCs below

-- ------------------------------------------------------------
-- RPC FUNCTIONS  (SECURITY DEFINER bypasses RLS)
-- ------------------------------------------------------------

-- Register a new user. Fails if nickname already exists.
create or replace function register_user(p_nickname text, p_pin_hash text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nick text := btrim(p_nickname);
  v_id uuid;
begin
  if length(v_nick) < 1 or length(v_nick) > 20 then
    raise exception 'NICKNAME_LENGTH';
  end if;
  if length(p_pin_hash) < 16 then
    raise exception 'PIN_HASH_INVALID';
  end if;
  if exists (select 1 from quiz_users where nickname = v_nick) then
    raise exception 'NICKNAME_TAKEN';
  end if;
  insert into quiz_users (nickname, pin_hash)
  values (v_nick, p_pin_hash)
  returning id into v_id;
  return v_id;
end;
$$;

-- Verify login. Returns user_id if nickname+pin match, else null.
create or replace function verify_user(p_nickname text, p_pin_hash text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  select id into v_id
    from quiz_users
   where nickname = btrim(p_nickname) and pin_hash = p_pin_hash;
  return v_id;
end;
$$;

-- Check if a nickname is already taken (for live duplicate check).
create or replace function nickname_exists(p_nickname text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from quiz_users where nickname = btrim(p_nickname)
  );
$$;

-- Submit a score. Only updates if the new record is better than the old.
-- Returns a row describing what happened.
--   updated     : true if the personal best was replaced
--   prev_mistakes / prev_time : previous best (null if no prior record)
--   best_mistakes / best_time : the best record after this submission
create or replace function submit_score(
  p_nickname text,
  p_pin_hash text,
  p_mistakes int,
  p_time_seconds int
) returns table (
  updated boolean,
  prev_mistakes int,
  prev_time int,
  best_mistakes int,
  best_time int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
  v_nick text := btrim(p_nickname);
  v_prev_m int;
  v_prev_t int;
  v_is_better boolean := false;
begin
  -- Authenticate
  select id into v_user_id
    from quiz_users
   where nickname = v_nick and pin_hash = p_pin_hash;
  if v_user_id is null then
    raise exception 'AUTH_FAILED';
  end if;

  -- Sanity-check score bounds (prevents trivial tampering)
  if p_mistakes < 0 or p_mistakes > 500 then raise exception 'BAD_MISTAKES'; end if;
  if p_time_seconds < 0 or p_time_seconds > 36000 then raise exception 'BAD_TIME'; end if;

  -- Fetch previous best
  select mistakes, time_seconds into v_prev_m, v_prev_t
    from quiz_rankings where user_id = v_user_id;

  if v_prev_m is null then
    -- First submission
    insert into quiz_rankings (user_id, nickname, mistakes, time_seconds, updated_at)
    values (v_user_id, v_nick, p_mistakes, p_time_seconds, now());
    v_is_better := true;
  elsif (p_mistakes < v_prev_m)
     or (p_mistakes = v_prev_m and p_time_seconds < v_prev_t) then
    update quiz_rankings
       set mistakes = p_mistakes,
           time_seconds = p_time_seconds,
           nickname = v_nick,
           updated_at = now()
     where user_id = v_user_id;
    v_is_better := true;
  end if;

  return query
    select v_is_better,
           v_prev_m,
           v_prev_t,
           coalesce(least_m.mistakes, p_mistakes),
           coalesce(least_m.time_seconds, p_time_seconds)
      from (select mistakes, time_seconds
              from quiz_rankings where user_id = v_user_id) least_m;
end;
$$;

-- Top-N leaderboard with pre-computed rank numbers
create or replace function get_top_ranking(p_limit int default 10)
returns table (
  rank int,
  nickname text,
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
    nickname, mistakes, time_seconds, updated_at
  from quiz_rankings
  order by mistakes asc, time_seconds asc, updated_at asc
  limit greatest(1, least(p_limit, 100));
$$;

-- My rank + ±window neighbors
-- Returns up to (2*window + 1) rows centered on the caller
create or replace function get_neighbors(
  p_nickname text,
  p_window int default 3
) returns table (
  rank int,
  nickname text,
  mistakes int,
  time_seconds int,
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
  if v_total = 0 then
    return;
  end if;

  with ordered as (
    select nickname, mistakes, time_seconds,
           row_number() over (order by mistakes asc, time_seconds asc, updated_at asc)::int as r
      from quiz_rankings
  )
  select r into v_my_rank from ordered where nickname = v_nick;

  if v_my_rank is null then
    return;
  end if;

  return query
  with ordered as (
    select nickname, mistakes, time_seconds,
           row_number() over (order by mistakes asc, time_seconds asc, updated_at asc)::int as r
      from quiz_rankings
  )
  select o.r,
         o.nickname,
         o.mistakes,
         o.time_seconds,
         (o.nickname = v_nick) as is_me,
         v_my_rank,
         v_total
    from ordered o
   where o.r between (v_my_rank - v_window) and (v_my_rank + v_window)
   order by o.r asc;
end;
$$;

-- Expose RPCs to anon + authenticated
grant execute on function register_user(text, text)    to anon, authenticated;
grant execute on function verify_user(text, text)      to anon, authenticated;
grant execute on function nickname_exists(text)        to anon, authenticated;
grant execute on function submit_score(text, text, int, int) to anon, authenticated;
grant execute on function get_top_ranking(int)         to anon, authenticated;
grant execute on function get_neighbors(text, int)     to anon, authenticated;
