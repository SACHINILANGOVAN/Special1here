-- =============================================================================
--  Forever Connect — Supabase schema
--  Private one-to-one messaging + Secret Rooms + presence + profile photos.
--
--  Run the whole file once in Supabase → SQL Editor → New query → Run.
--  It is idempotent: running it again upgrades functions/policies in place.
--  No seed data, demo users or sample messages are created.
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;

-- =============================================================================
-- 1. TABLES
-- =============================================================================

-- ---------------------------------------------------------------- profiles ---
-- One row per auth user (created automatically by trigger on auth.users).
-- `phone` is copied from the VERIFIED auth phone only and is never readable by
-- other users (column-level grants below).
create table if not exists public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  username      text unique,
  display_name  text,
  phone         text unique,
  avatar_path   text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint profiles_username_format check (
    username is null or (username = lower(username) and username ~ '^[a-z0-9_][a-z0-9_.]{2,19}$')
  ),
  constraint profiles_display_name_len check (display_name is null or char_length(display_name) between 1 and 40),
  constraint profiles_phone_format check (phone is null or phone ~ '^\+[1-9][0-9]{6,14}$'),
  constraint profiles_avatar_path_owner check (avatar_path is null or avatar_path like (id::text || '/%'))
);

-- ----------------------------------------------------------- user_presence ---
create table if not exists public.user_presence (
  user_id       uuid primary key references public.profiles (id) on delete cascade,
  is_online     boolean not null default false,
  last_seen_at  timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ----------------------------------------------------------- conversations ---
-- Private one-to-one conversations. `direct_key` = "<smaller uuid>:<larger uuid>"
-- guarantees exactly one conversation per pair of users.
create table if not exists public.conversations (
  id               uuid primary key default gen_random_uuid(),
  direct_key       text not null unique,
  last_message_id  uuid,
  last_message_at  timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint conversations_direct_key_format check (
    direct_key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  )
);

-- ------------------------------------------------ conversation_participants ---
create table if not exists public.conversation_participants (
  conversation_id  uuid not null references public.conversations (id) on delete cascade,
  user_id          uuid not null references public.profiles (id) on delete cascade,
  joined_at        timestamptz not null default now(),
  last_read_at     timestamptz,
  cleared_at       timestamptz,          -- "Clear chat" (hides older messages for this user only)
  primary key (conversation_id, user_id)
);

-- ---------------------------------------------------------------- messages ---
create table if not exists public.messages (
  id               uuid primary key default gen_random_uuid(),
  conversation_id  uuid not null references public.conversations (id) on delete cascade,
  sender_id        uuid not null references public.profiles (id) on delete cascade,
  body             text not null,
  reply_to_id      uuid references public.messages (id) on delete set null,
  created_at       timestamptz not null default now(),
  edited_at        timestamptz,
  constraint messages_body_len check (char_length(body) between 1 and 4000 and btrim(body) <> '')
);

-- Attachments (photos, videos, documents). Written as idempotent ALTERs so that
-- re-running this file upgrades an existing database in place.
alter table public.messages alter column body drop not null;
alter table public.messages add column if not exists kind            text not null default 'text';
alter table public.messages add column if not exists attachment_path text;
alter table public.messages add column if not exists attachment_name text;
alter table public.messages add column if not exists attachment_mime text;
alter table public.messages add column if not exists attachment_size bigint;
alter table public.messages drop constraint if exists messages_body_len;
-- (messages_kind / messages_payload are defined once, in the Groups block below.
--  An attachment must live in "<conversation>/<sender>/<file>", uploaded by its sender.)

-- Groups ---------------------------------------------------------------------
-- A conversation is either direct (exactly 2 people, unique direct_key) or a group
-- (title, optional photo, admins). Re-running this file upgrades existing data in place.
alter table public.conversations add column if not exists is_group    boolean not null default false;
alter table public.conversations add column if not exists title       text;
alter table public.conversations add column if not exists avatar_path text;
alter table public.conversations add column if not exists created_by  uuid references public.profiles (id) on delete set null;
alter table public.conversations alter column direct_key drop not null;
alter table public.conversations drop constraint if exists conversations_direct_key_format;
alter table public.conversations drop constraint if exists conversations_kind;
alter table public.conversations add constraint conversations_kind check (
  (is_group and direct_key is null and title is not null and char_length(btrim(title)) between 1 and 60)
  or
  (not is_group and title is null and avatar_path is null and
   direct_key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
);
alter table public.conversation_participants add column if not exists role text not null default 'member';
alter table public.conversation_participants drop constraint if exists conversation_participants_role;
alter table public.conversation_participants add constraint conversation_participants_role check (role in ('admin', 'member'));

-- 'system' messages ("Ravi added Priya") are written only by the group functions below.
alter table public.messages drop constraint if exists messages_kind;
alter table public.messages add constraint messages_kind check (kind in ('text', 'image', 'video', 'file', 'system'));
alter table public.messages drop constraint if exists messages_payload;
alter table public.messages add constraint messages_payload check (
  (kind in ('text', 'system')
     and body is not null and char_length(body) between 1 and 4000 and btrim(body) <> ''
     and attachment_path is null and attachment_name is null and attachment_mime is null and attachment_size is null)
  or
  (kind in ('image', 'video', 'file')
     and attachment_path like (conversation_id::text || '/' || sender_id::text || '/%')
     and char_length(attachment_name) between 1 and 200
     and char_length(attachment_mime) between 1 and 120
     and attachment_size between 1 and 52428800
     and (body is null or char_length(body) <= 1000))
);

alter table public.conversations drop constraint if exists conversations_last_message_fk;
alter table public.conversations
  add constraint conversations_last_message_fk
  foreign key (last_message_id) references public.messages (id) on delete set null;

-- -------------------------------------------------------- message_receipts ---
-- Delivered / read receipts (one row per message per recipient).
create table if not exists public.message_receipts (
  message_id    uuid not null references public.messages (id) on delete cascade,
  user_id       uuid not null references public.profiles (id) on delete cascade,
  delivered_at  timestamptz not null default now(),
  read_at       timestamptz,
  primary key (message_id, user_id),
  constraint message_receipts_read_after_delivery check (read_at is null or read_at >= delivered_at)
);

-- ------------------------------------------------------------ secret_rooms ---
-- A live Secret Room (6-digit code). One room per owner. Closing the room or
-- changing its code deletes the row, which erases its participants and messages.
create table if not exists public.secret_rooms (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,
  owner_id         uuid not null unique references public.profiles (id) on delete cascade,
  peer_session_id  uuid not null,       -- WebRTC session id used by the peer-to-peer protocol
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint secret_rooms_code_format check (code ~ '^[0-9]{6}$')
);

-- ------------------------------------------------ secret_room_participants ---
create table if not exists public.secret_room_participants (
  room_id     uuid not null references public.secret_rooms (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  role        text not null,
  peer_token  text,                     -- guest's secret reconnection token (verified by the host)
  joined_at   timestamptz not null default now(),
  cleared_at  timestamptz,
  primary key (room_id, user_id),
  constraint srp_role check (role in ('host', 'guest')),
  constraint srp_token check (
    (role = 'host' and peer_token is null) or
    (role = 'guest' and peer_token is not null and char_length(peer_token) between 8 and 64)
  )
);
-- Exactly one host and at most one guest per room → "only two people".
create unique index if not exists srp_one_host_per_room  on public.secret_room_participants (room_id) where role = 'host';
create unique index if not exists srp_one_guest_per_room on public.secret_room_participants (room_id) where role = 'guest';

-- ---------------------------------------------------- secret_room_messages ---
-- Text is stored. Photos/videos still travel peer-to-peer; only a placeholder
-- row (kind + mime) is stored for them.
create table if not exists public.secret_room_messages (
  id            uuid primary key default gen_random_uuid(),
  room_id       uuid not null references public.secret_rooms (id) on delete cascade,
  sender_id     uuid not null references public.profiles (id) on delete cascade,
  kind          text not null default 'text',
  body          text,
  mime          text,
  reply_to_id   uuid references public.secret_room_messages (id) on delete set null,
  created_at    timestamptz not null default now(),
  edited_at     timestamptz,
  delivered_at  timestamptz,
  constraint srm_kind check (kind in ('text', 'image', 'video')),
  constraint srm_payload check (
    (kind = 'text' and body is not null and char_length(body) between 1 and 4000 and btrim(body) <> '' and mime is null)
    or (kind in ('image', 'video') and body is null and mime is not null and char_length(mime) <= 100)
  )
);

-- =============================================================================
-- 2. INDEXES
-- =============================================================================
create index if not exists profiles_username_prefix_idx   on public.profiles (username text_pattern_ops);
create index if not exists conversations_last_msg_idx      on public.conversations (last_message_at desc nulls last);
create index if not exists conv_participants_user_idx      on public.conversation_participants (user_id);
create index if not exists messages_conv_created_idx       on public.messages (conversation_id, created_at desc);
create index if not exists messages_sender_idx             on public.messages (sender_id);
create index if not exists messages_reply_idx              on public.messages (reply_to_id) where reply_to_id is not null;
create index if not exists receipts_user_idx               on public.message_receipts (user_id);
create index if not exists srp_user_idx                    on public.secret_room_participants (user_id);
create index if not exists srm_room_created_idx            on public.secret_room_messages (room_id, created_at desc);
create index if not exists srm_sender_idx                  on public.secret_room_messages (sender_id);
create index if not exists srm_reply_idx                   on public.secret_room_messages (reply_to_id) where reply_to_id is not null;

-- =============================================================================
-- 3. HELPER FUNCTIONS (security definer → no recursive RLS)
-- =============================================================================
create or replace function public.is_conversation_participant(p_conversation uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.conversation_participants
    where conversation_id = p_conversation and user_id = auth.uid()
  );
$$;

create or replace function public.is_room_participant(p_room uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.secret_room_participants
    where room_id = p_room and user_id = auth.uid()
  );
$$;

-- When the current user joined a room (null if not a member). A guest only sees
-- room messages written after they joined.
create or replace function public.room_member_since(p_room uuid)
returns timestamptz language sql stable security definer set search_path = public as $$
  select joined_at from public.secret_room_participants
  where room_id = p_room and user_id = auth.uid();
$$;

-- A profile is visible to its owner and to people who share a conversation or room.
create or replace function public.can_view_profile(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select p_user = auth.uid()
    or exists (
      select 1 from public.conversation_participants a
      join public.conversation_participants b on b.conversation_id = a.conversation_id
      where a.user_id = auth.uid() and b.user_id = p_user
    )
    or exists (
      select 1 from public.secret_room_participants a
      join public.secret_room_participants b on b.room_id = a.room_id
      where a.user_id = auth.uid() and b.user_id = p_user
    );
$$;

-- Realtime Authorization: private broadcast topics "dm:<conversation uuid>".
create or replace function public.can_access_realtime_topic(p_topic text)
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if p_topic ~ '^dm:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return public.is_conversation_participant(substring(p_topic from 4)::uuid);
  end if;
  return false;
end;
$$;

-- =============================================================================
-- 4. TRIGGERS
-- =============================================================================

-- ------------------------------------------------------------- updated_at ---
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at      on public.profiles;
drop trigger if exists presence_set_updated_at      on public.user_presence;
drop trigger if exists conversations_set_updated_at on public.conversations;
drop trigger if exists secret_rooms_set_updated_at  on public.secret_rooms;
create trigger profiles_set_updated_at      before update on public.profiles      for each row execute function public.set_updated_at();
create trigger presence_set_updated_at      before update on public.user_presence for each row execute function public.set_updated_at();
create trigger conversations_set_updated_at before update on public.conversations for each row execute function public.set_updated_at();
create trigger secret_rooms_set_updated_at  before update on public.secret_rooms  for each row execute function public.set_updated_at();

-- ------------------------------------------------- new auth user → profile ---
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_username text := lower(nullif(btrim(new.raw_user_meta_data ->> 'username'), ''));
  v_display  text := nullif(btrim(new.raw_user_meta_data ->> 'display_name'), '');
  v_phone    text := case when coalesce(new.phone, '') <> '' then '+' || ltrim(new.phone, '+') end;
begin
  if v_username is not null then
    if v_username !~ '^[a-z0-9_][a-z0-9_.]{2,19}$' then
      raise exception 'invalid_username' using errcode = '22023';
    end if;
    if exists (select 1 from public.profiles where username = v_username) then
      raise exception 'username_taken' using errcode = '23505';
    end if;
  end if;

  insert into public.profiles (id, username, display_name, phone)
  values (new.id, v_username, left(coalesce(v_display, v_username), 40), v_phone)
  on conflict (id) do nothing;

  insert into public.user_presence (user_id, is_online, last_seen_at)
  values (new.id, false, now())
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ------------------------------------ verified phone change → profile.phone ---
create or replace function public.handle_user_phone_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.profiles
     set phone = case when coalesce(new.phone, '') <> '' then '+' || ltrim(new.phone, '+') end
   where id = new.id;
  return new;
end;
$$;

drop trigger if exists on_auth_user_phone_changed on auth.users;
create trigger on_auth_user_phone_changed
  after update of phone on auth.users
  for each row when (old.phone is distinct from new.phone)
  execute function public.handle_user_phone_change();

-- -------------------------------------------------------- messages guards ---
create or replace function public.messages_before_write()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.created_at := now();
    new.edited_at  := null;
    if new.reply_to_id is not null and not exists (
      select 1 from public.messages r
      where r.id = new.reply_to_id and r.conversation_id = new.conversation_id
    ) then
      new.reply_to_id := null;
    end if;
  else
    if new.id <> old.id or new.conversation_id <> old.conversation_id or new.sender_id <> old.sender_id
       or new.created_at <> old.created_at or new.reply_to_id is distinct from old.reply_to_id
       or new.kind <> old.kind or new.attachment_path is distinct from old.attachment_path
       or new.attachment_name is distinct from old.attachment_name or new.attachment_mime is distinct from old.attachment_mime
       or new.attachment_size is distinct from old.attachment_size then
      raise exception 'Only the message text can be edited' using errcode = '42501';
    end if;
    if new.body is distinct from old.body and old.kind <> 'text' then
      raise exception 'Attachments cannot be edited' using errcode = '42501';
    end if;
    new.edited_at := case when new.body is distinct from old.body then now() else old.edited_at end;
  end if;
  return new;
end;
$$;

drop trigger if exists messages_before_write on public.messages;
create trigger messages_before_write
  before insert or update on public.messages
  for each row execute function public.messages_before_write();

create or replace function public.messages_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.conversations
     set last_message_id = new.id, last_message_at = new.created_at
   where id = new.conversation_id;
  return null;
end;
$$;

drop trigger if exists messages_after_insert on public.messages;
create trigger messages_after_insert
  after insert on public.messages
  for each row execute function public.messages_after_insert();

-- ------------------------------------------------ secret room msg guards ---
create or replace function public.srm_before_write()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    new.created_at   := now();
    new.edited_at    := null;
    new.delivered_at := null;
    if new.reply_to_id is not null and not exists (
      select 1 from public.secret_room_messages r
      where r.id = new.reply_to_id and r.room_id = new.room_id
    ) then
      new.reply_to_id := null;
    end if;
  else
    if new.id <> old.id or new.room_id <> old.room_id or new.sender_id <> old.sender_id
       or new.kind <> old.kind or new.mime is distinct from old.mime
       or new.created_at <> old.created_at or new.reply_to_id is distinct from old.reply_to_id then
      raise exception 'Only the message text can be edited' using errcode = '42501';
    end if;
    new.edited_at    := case when new.body is distinct from old.body then now() else old.edited_at end;
    new.delivered_at := coalesce(old.delivered_at, new.delivered_at);
  end if;
  return new;
end;
$$;

drop trigger if exists srm_before_write on public.secret_room_messages;
create trigger srm_before_write
  before insert or update on public.secret_room_messages
  for each row execute function public.srm_before_write();

-- =============================================================================
-- 5. RPC FUNCTIONS (called from the app)
-- =============================================================================

-- ----------------------------------------------------- auth / profile ---
create or replace function public.username_available(p_username text)
returns boolean language sql stable security definer set search_path = public as $$
  select lower(btrim(coalesce(p_username, ''))) ~ '^[a-z0-9_][a-z0-9_.]{2,19}$'
     and not exists (select 1 from public.profiles where username = lower(btrim(p_username)));
$$;

-- Username + password login: resolve a username to the Supabase-managed login
-- e-mail of a *username* account. Passwords are only ever checked by Supabase Auth.
create or replace function public.login_email_for_username(p_username text)
returns text language sql stable security definer set search_path = public, auth as $$
  select u.email
    from public.profiles p
    join auth.users u on u.id = p.id
   where p.username = lower(btrim(coalesce(p_username, '')))
     and u.raw_user_meta_data ->> 'signup_method' = 'username'
   limit 1;
$$;

-- Creates the profile row if it is missing (e.g. for users created before this schema).
create or replace function public.ensure_my_profile()
returns void language plpgsql security definer set search_path = public, auth as $$
declare v_phone text;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select case when coalesce(phone, '') <> '' then '+' || ltrim(phone, '+') end into v_phone
    from auth.users where id = auth.uid();
  insert into public.profiles (id, phone) values (auth.uid(), v_phone) on conflict (id) do nothing;
  insert into public.user_presence (user_id) values (auth.uid()) on conflict (user_id) do nothing;
end;
$$;

-- Search by exact mobile number (E.164) or by username prefix. Never returns phone numbers.
create or replace function public.search_users(p_query text)
returns table (id uuid, username text, display_name text, avatar_path text)
language plpgsql stable security definer set search_path = public as $$
declare
  q text := lower(btrim(coalesce(p_query, '')));
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;

  if q ~ '^\+?[0-9 ()-]{7,24}$' then
    return query
      select p.id, p.username, p.display_name, p.avatar_path
        from public.profiles p
       where p.phone = '+' || regexp_replace(q, '[^0-9]', '', 'g')
         and p.id <> auth.uid() and p.username is not null
       limit 1;
    return;
  end if;

  q := ltrim(q, '@');
  if char_length(q) < 2 or q !~ '^[a-z0-9_.]+$' then return; end if;

  return query
    select p.id, p.username, p.display_name, p.avatar_path
      from public.profiles p
     where p.username like replace(q, '_', '\_') || '%'
       and p.id <> auth.uid()
     order by (p.username = q) desc, char_length(p.username), p.username
     limit 20;
end;
$$;

-- ----------------------------------------------------------- presence ---
create or replace function public.touch_presence(p_online boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  insert into public.user_presence (user_id, is_online, last_seen_at)
  values (auth.uid(), coalesce(p_online, false), now())
  on conflict (user_id) do update
    set is_online = excluded.is_online, last_seen_at = now();
end;
$$;

-- ------------------------------------------------------ conversations ---
create or replace function public.get_or_create_direct_conversation(p_other uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me  uuid := auth.uid();
  v_key text;
  v_id  uuid;
begin
  if v_me is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_other is null or p_other = v_me then raise exception 'invalid_user' using errcode = '22023'; end if;
  if not exists (select 1 from public.profiles where id = p_other and username is not null) then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  v_key := least(v_me::text, p_other::text) || ':' || greatest(v_me::text, p_other::text);
  select id into v_id from public.conversations where direct_key = v_key;
  if v_id is null then
    insert into public.conversations (direct_key) values (v_key)
    on conflict (direct_key) do nothing
    returning id into v_id;
    if v_id is null then
      select id into v_id from public.conversations where direct_key = v_key;
    end if;
  end if;

  insert into public.conversation_participants (conversation_id, user_id)
  values (v_id, v_me), (v_id, p_other)
  on conflict (conversation_id, user_id) do nothing;

  return v_id;
end;
$$;

-- Conversation list for the current user: direct chats (peer profile + presence) and groups
-- (title, photo, member count, my role), with last message, delivery/read state and unread count.
drop function if exists public.get_conversations(); -- return columns changed (attachments, groups)
create or replace function public.get_conversations()
returns table (
  conversation_id          uuid,
  peer_id                  uuid,
  peer_username            text,
  peer_display_name        text,
  peer_avatar_path         text,
  peer_created_at          timestamptz,
  peer_is_online           boolean,
  peer_last_seen_at        timestamptz,
  last_message_id          uuid,
  last_message_body        text,
  last_message_sender_id   uuid,
  last_message_at          timestamptz,
  last_message_delivered   boolean,
  last_message_read        boolean,
  unread_count             bigint,
  cleared_at               timestamptz,
  created_at               timestamptz,
  last_message_kind        text,
  last_message_file_name   text,
  is_group                 boolean,
  group_title              text,
  group_avatar_path        text,
  member_count             integer,
  my_role                  text,
  last_message_sender_name text
)
language sql stable security definer set search_path = public as $$
  select
    c.id,
    p.id, p.username, p.display_name, p.avatar_path, p.created_at,
    coalesce(up.is_online, false), up.last_seen_at,
    lm.id, lm.body, lm.sender_id, lm.created_at,
    -- delivered / read = every other member has a receipt (1 member for direct chats)
    (lm.id is not null and not exists (
       select 1 from public.conversation_participants x
        where x.conversation_id = c.id and x.user_id <> lm.sender_id
          and not exists (select 1 from public.message_receipts r where r.message_id = lm.id and r.user_id = x.user_id))),
    (lm.id is not null and not exists (
       select 1 from public.conversation_participants x
        where x.conversation_id = c.id and x.user_id <> lm.sender_id
          and not exists (select 1 from public.message_receipts r where r.message_id = lm.id and r.user_id = x.user_id and r.read_at is not null))),
    (select count(*) from public.messages m
      where m.conversation_id = c.id
        and m.sender_id <> me.user_id
        and m.kind <> 'system'
        and m.created_at > greatest(coalesce(me.last_read_at, '-infinity'::timestamptz),
                                    coalesce(me.cleared_at,  '-infinity'::timestamptz))),
    me.cleared_at,
    c.created_at,
    lm.kind,
    lm.attachment_name,
    c.is_group,
    c.title,
    c.avatar_path,
    (select count(*)::integer from public.conversation_participants x where x.conversation_id = c.id),
    me.role,
    (select coalesce(sp.display_name, sp.username) from public.profiles sp where sp.id = lm.sender_id)
  from public.conversation_participants me
  join public.conversations c on c.id = me.conversation_id
  left join lateral (
    select o.user_id from public.conversation_participants o
     where o.conversation_id = c.id and o.user_id <> me.user_id and not c.is_group
     limit 1
  ) o on true
  left join public.profiles p        on p.id = o.user_id
  left join public.user_presence up  on up.user_id = p.id
  left join public.messages lm       on lm.id = c.last_message_id
                                    and lm.created_at > coalesce(me.cleared_at, '-infinity'::timestamptz)
  where me.user_id = auth.uid()
    and (c.is_group or o.user_id is not null)
  order by coalesce(c.last_message_at, c.created_at) desc;
$$;

-- ---------------------------------------------------------------- groups ---
create or replace function public.display_name_of(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(display_name, username, 'Someone') from public.profiles where id = p_user;
$$;

-- Internal: write a centred system line ("Ravi added Priya") into a group.
create or replace function public.group_system_message(p_conv uuid, p_text text)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.messages (conversation_id, sender_id, kind, body)
  values (p_conv, auth.uid(), 'system', left(p_text, 4000));
end;
$$;

create or replace function public.is_group_admin(p_conv uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.conversation_participants cp
    join public.conversations c on c.id = cp.conversation_id
    where cp.conversation_id = p_conv and cp.user_id = auth.uid() and cp.role = 'admin' and c.is_group
  );
$$;

-- Create a group with the given members (the creator becomes admin). Max 256 people.
create or replace function public.create_group(p_title text, p_members uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := auth.uid();
  v_title text := btrim(coalesce(p_title, ''));
  v_id uuid;
  v_members uuid[];
begin
  if v_me is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if char_length(v_title) not between 1 and 60 then raise exception 'invalid_title' using errcode = '22023'; end if;
  select coalesce(array_agg(distinct p.id), '{}') into v_members
    from public.profiles p
   where p.id = any (coalesce(p_members, '{}')) and p.id <> v_me and p.username is not null;
  if cardinality(v_members) < 1 then raise exception 'no_members' using errcode = '22023'; end if;
  if cardinality(v_members) > 255 then raise exception 'too_many_members' using errcode = '22023'; end if;

  insert into public.conversations (is_group, title, created_by) values (true, v_title, v_me) returning id into v_id;
  insert into public.conversation_participants (conversation_id, user_id, role) values (v_id, v_me, 'admin');
  insert into public.conversation_participants (conversation_id, user_id, role)
  select v_id, unnest(v_members), 'member';
  perform public.group_system_message(v_id, public.display_name_of(v_me) || ' created the group “' || v_title || '”');
  return v_id;
end;
$$;

create or replace function public.add_group_members(p_conv uuid, p_members uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare v_added uuid[]; v_names text;
begin
  if not public.is_group_admin(p_conv) then raise exception 'not_admin' using errcode = '42501'; end if;
  select coalesce(array_agg(distinct p.id), '{}') into v_added
    from public.profiles p
   where p.id = any (coalesce(p_members, '{}')) and p.username is not null
     and not exists (select 1 from public.conversation_participants cp where cp.conversation_id = p_conv and cp.user_id = p.id);
  if cardinality(v_added) = 0 then return 0; end if;
  if (select count(*) from public.conversation_participants where conversation_id = p_conv) + cardinality(v_added) > 256 then
    raise exception 'too_many_members' using errcode = '22023';
  end if;
  insert into public.conversation_participants (conversation_id, user_id, role) select p_conv, unnest(v_added), 'member';
  select string_agg(public.display_name_of(u), ', ') into v_names from unnest(v_added) u;
  perform public.group_system_message(p_conv, public.display_name_of(auth.uid()) || ' added ' || v_names);
  return cardinality(v_added);
end;
$$;

create or replace function public.remove_group_member(p_conv uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_group_admin(p_conv) then raise exception 'not_admin' using errcode = '42501'; end if;
  if p_user = auth.uid() then raise exception 'use_leave_group' using errcode = '22023'; end if;
  delete from public.conversation_participants where conversation_id = p_conv and user_id = p_user;
  if found then
    perform public.group_system_message(p_conv, public.display_name_of(auth.uid()) || ' removed ' || public.display_name_of(p_user));
  end if;
end;
$$;

create or replace function public.set_group_admin(p_conv uuid, p_user uuid, p_admin boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_group_admin(p_conv) then raise exception 'not_admin' using errcode = '42501'; end if;
  update public.conversation_participants set role = case when p_admin then 'admin' else 'member' end
   where conversation_id = p_conv and user_id = p_user;
  if not exists (select 1 from public.conversation_participants where conversation_id = p_conv and role = 'admin') then
    raise exception 'group_needs_admin' using errcode = '22023';
  end if;
end;
$$;

-- Leave a group. The last admin leaving promotes the longest-standing member; the last person deletes the group.
create or replace function public.leave_group(p_conv uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_me uuid := auth.uid();
begin
  if not exists (select 1 from public.conversation_participants cp join public.conversations c on c.id = cp.conversation_id
                  where cp.conversation_id = p_conv and cp.user_id = v_me and c.is_group) then
    raise exception 'not_a_participant' using errcode = '42501';
  end if;
  perform public.group_system_message(p_conv, public.display_name_of(v_me) || ' left');
  delete from public.conversation_participants where conversation_id = p_conv and user_id = v_me;
  if not exists (select 1 from public.conversation_participants where conversation_id = p_conv) then
    delete from public.conversations where id = p_conv;
  elsif not exists (select 1 from public.conversation_participants where conversation_id = p_conv and role = 'admin') then
    update public.conversation_participants set role = 'admin'
     where conversation_id = p_conv
       and user_id = (select user_id from public.conversation_participants where conversation_id = p_conv order by joined_at limit 1);
  end if;
end;
$$;

-- Rename and/or change the photo (admins). Photos live in the public "avatars" bucket under the admin's folder.
create or replace function public.update_group(p_conv uuid, p_title text default null, p_avatar_path text default null, p_clear_avatar boolean default false)
returns void language plpgsql security definer set search_path = public as $$
declare v_old text; v_title text := nullif(btrim(coalesce(p_title, '')), '');
begin
  if not public.is_group_admin(p_conv) then raise exception 'not_admin' using errcode = '42501'; end if;
  if v_title is not null and char_length(v_title) > 60 then raise exception 'invalid_title' using errcode = '22023'; end if;
  if p_avatar_path is not null and p_avatar_path not like (auth.uid()::text || '/%') then
    raise exception 'invalid_avatar_path' using errcode = '22023';
  end if;
  select title into v_old from public.conversations where id = p_conv;
  update public.conversations
     set title = coalesce(v_title, title),
         avatar_path = case when p_clear_avatar then null else coalesce(p_avatar_path, avatar_path) end
   where id = p_conv;
  if v_title is not null and v_title is distinct from v_old then
    perform public.group_system_message(p_conv, public.display_name_of(auth.uid()) || ' changed the group name to “' || v_title || '”');
  elsif p_avatar_path is not null or p_clear_avatar then
    perform public.group_system_message(p_conv, public.display_name_of(auth.uid()) || ' changed the group photo');
  end if;
end;
$$;

-- Mark incoming messages as delivered (one conversation, or all when null).
create or replace function public.mark_delivered(p_conversation uuid default null)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  insert into public.message_receipts (message_id, user_id, delivered_at)
  select m.id, auth.uid(), now()
    from public.conversation_participants cp
    join public.messages m on m.conversation_id = cp.conversation_id
   where cp.user_id = auth.uid()
     and (p_conversation is null or cp.conversation_id = p_conversation)
     and m.sender_id <> auth.uid()
     and m.created_at > coalesce(cp.last_read_at, '-infinity'::timestamptz)
     and not exists (select 1 from public.message_receipts r where r.message_id = m.id and r.user_id = auth.uid())
  on conflict (message_id, user_id) do nothing;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Mark every incoming message in a conversation as read.
create or replace function public.mark_conversation_read(p_conversation uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_last timestamptz;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select last_read_at into v_last from public.conversation_participants
   where conversation_id = p_conversation and user_id = auth.uid() for update;
  if not found then raise exception 'not_a_participant' using errcode = '42501'; end if;

  insert into public.message_receipts (message_id, user_id, delivered_at, read_at)
  select m.id, auth.uid(), now(), now()
    from public.messages m
   where m.conversation_id = p_conversation
     and m.sender_id <> auth.uid()
     and m.created_at > coalesce(v_last, '-infinity'::timestamptz)
  on conflict (message_id, user_id) do update
    set read_at = coalesce(public.message_receipts.read_at, excluded.read_at)
  where public.message_receipts.read_at is null;

  update public.conversation_participants
     set last_read_at = now()
   where conversation_id = p_conversation and user_id = auth.uid();
end;
$$;

create or replace function public.clear_conversation(p_conversation uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.conversation_participants
     set cleared_at = now(), last_read_at = now()
   where conversation_id = p_conversation and user_id = auth.uid();
  if not found then raise exception 'not_a_participant' using errcode = '42501'; end if;
end;
$$;

-- ------------------------------------------------------- secret rooms ---
-- Create (or re-key) the caller's room. A user is in at most one room at a time,
-- so any previous room they own or joined is closed/left first.
create or replace function public.open_secret_room(p_code text, p_peer_session uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_code is null or p_code !~ '^[0-9]{6}$' or p_peer_session is null then
    raise exception 'invalid_code' using errcode = '22023';
  end if;

  delete from public.secret_rooms where owner_id = auth.uid();
  delete from public.secret_room_participants where user_id = auth.uid();

  begin
    insert into public.secret_rooms (code, owner_id, peer_session_id)
    values (p_code, auth.uid(), p_peer_session)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'code_taken' using errcode = 'P0001';
  end;

  insert into public.secret_room_participants (room_id, user_id, role) values (v_id, auth.uid(), 'host');
  return v_id;
end;
$$;

create or replace function public.join_secret_room(p_code text, p_token text)
returns table (room_id uuid, peer_session_id uuid)
language plpgsql security definer set search_path = public as $$
declare r public.secret_rooms%rowtype;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_code is null or p_code !~ '^[0-9]{6}$' then raise exception 'invalid_code' using errcode = '22023'; end if;
  if p_token is null or char_length(p_token) not between 8 and 64 then raise exception 'invalid_token' using errcode = '22023'; end if;

  select * into r from public.secret_rooms where code = p_code for update;
  if not found then raise exception 'room_not_found' using errcode = 'P0002'; end if;
  if r.owner_id = auth.uid() then raise exception 'own_room' using errcode = 'P0001'; end if;
  if exists (select 1 from public.secret_room_participants s
              where s.room_id = r.id and s.role = 'guest' and s.user_id <> auth.uid()) then
    raise exception 'room_full' using errcode = 'P0001';
  end if;

  delete from public.secret_rooms where owner_id = auth.uid();
  delete from public.secret_room_participants s where s.user_id = auth.uid() and s.room_id <> r.id;

  insert into public.secret_room_participants (room_id, user_id, role, peer_token)
  values (r.id, auth.uid(), 'guest', p_token)
  on conflict on constraint secret_room_participants_pkey do update set peer_token = excluded.peer_token;

  return query select r.id, r.peer_session_id;
end;
$$;

create or replace function public.leave_secret_room(p_room uuid)
returns void language sql security definer set search_path = public as $$
  delete from public.secret_room_participants
   where room_id = p_room and user_id = auth.uid() and role = 'guest';
$$;

create or replace function public.close_secret_room(p_room uuid)
returns void language sql security definer set search_path = public as $$
  delete from public.secret_rooms where id = p_room and owner_id = auth.uid();
$$;

create or replace function public.get_my_secret_room()
returns table (
  room_id         uuid,
  code            text,
  peer_session_id uuid,
  my_role         text,
  my_token        text,
  guest_token     text,
  guest_id        uuid,
  cleared_at      timestamptz
)
language sql stable security definer set search_path = public as $$
  select r.id, r.code, r.peer_session_id, me.role, me.peer_token, g.peer_token, g.user_id, me.cleared_at
    from public.secret_room_participants me
    join public.secret_rooms r on r.id = me.room_id
    left join public.secret_room_participants g on g.room_id = r.id and g.role = 'guest'
   where me.user_id = auth.uid()
   order by me.joined_at desc
   limit 1;
$$;

create or replace function public.mark_room_messages_delivered(p_ids uuid[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or p_ids is null then return; end if;
  if cardinality(p_ids) > 500 then raise exception 'too_many_ids' using errcode = '22023'; end if;
  update public.secret_room_messages m
     set delivered_at = now()
   where m.id = any (p_ids)
     and m.delivered_at is null
     and m.sender_id <> auth.uid()
     and exists (select 1 from public.secret_room_participants s
                  where s.room_id = m.room_id and s.user_id = auth.uid());
end;
$$;

create or replace function public.clear_secret_room_history(p_room uuid)
returns void language sql security definer set search_path = public as $$
  update public.secret_room_participants
     set cleared_at = now()
   where room_id = p_room and user_id = auth.uid();
$$;

-- =============================================================================
-- 6. PRIVILEGES (least privilege; RLS below decides which ROWS)
-- =============================================================================
revoke all on public.profiles, public.user_presence, public.conversations, public.conversation_participants,
              public.messages, public.message_receipts, public.secret_rooms,
              public.secret_room_participants, public.secret_room_messages
  from anon, authenticated;

-- profiles: phone is NOT selectable by clients (users read their own phone from their auth session).
grant select (id, username, display_name, avatar_path, created_at, updated_at) on public.profiles to authenticated;
grant update (username, display_name, avatar_path) on public.profiles to authenticated;

grant select on public.user_presence, public.conversations, public.conversation_participants,
                public.message_receipts, public.secret_rooms to authenticated;
grant select (room_id, user_id, role, peer_token, joined_at, cleared_at) on public.secret_room_participants to authenticated;

grant select on public.messages to authenticated;
grant insert (id, conversation_id, sender_id, body, reply_to_id,
              kind, attachment_path, attachment_name, attachment_mime, attachment_size) on public.messages to authenticated;
grant update (body) on public.messages to authenticated;

grant select on public.secret_room_messages to authenticated;
grant insert (id, room_id, sender_id, kind, body, mime, reply_to_id) on public.secret_room_messages to authenticated;
grant update (body) on public.secret_room_messages to authenticated;

-- Functions: revoke the default PUBLIC execute, then grant only what the app needs.
do $$
declare f text;
begin
  foreach f in array array[
    'public.is_conversation_participant(uuid)', 'public.is_room_participant(uuid)', 'public.room_member_since(uuid)',
    'public.can_view_profile(uuid)', 'public.can_access_realtime_topic(text)',
    'public.username_available(text)', 'public.login_email_for_username(text)', 'public.ensure_my_profile()',
    'public.search_users(text)', 'public.touch_presence(boolean)', 'public.get_or_create_direct_conversation(uuid)',
    'public.get_conversations()', 'public.mark_delivered(uuid)', 'public.mark_conversation_read(uuid)',
    'public.clear_conversation(uuid)', 'public.open_secret_room(text, uuid)', 'public.join_secret_room(text, text)',
    'public.leave_secret_room(uuid)', 'public.close_secret_room(uuid)', 'public.get_my_secret_room()',
    'public.mark_room_messages_delivered(uuid[])', 'public.clear_secret_room_history(uuid)',
    'public.handle_new_user()', 'public.handle_user_phone_change()', 'public.messages_after_insert()',
    'public.display_name_of(uuid)', 'public.group_system_message(uuid, text)', 'public.is_group_admin(uuid)',
    'public.create_group(text, uuid[])', 'public.add_group_members(uuid, uuid[])', 'public.remove_group_member(uuid, uuid)',
    'public.set_group_admin(uuid, uuid, boolean)', 'public.leave_group(uuid)', 'public.update_group(uuid, text, text, boolean)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
  end loop;

  foreach f in array array[
    'public.is_conversation_participant(uuid)', 'public.is_room_participant(uuid)', 'public.room_member_since(uuid)',
    'public.can_view_profile(uuid)', 'public.can_access_realtime_topic(text)',
    'public.ensure_my_profile()', 'public.search_users(text)', 'public.touch_presence(boolean)',
    'public.get_or_create_direct_conversation(uuid)', 'public.get_conversations()', 'public.mark_delivered(uuid)',
    'public.mark_conversation_read(uuid)', 'public.clear_conversation(uuid)', 'public.open_secret_room(text, uuid)',
    'public.join_secret_room(text, text)', 'public.leave_secret_room(uuid)', 'public.close_secret_room(uuid)',
    'public.get_my_secret_room()', 'public.mark_room_messages_delivered(uuid[])', 'public.clear_secret_room_history(uuid)',
    'public.username_available(text)', 'public.login_email_for_username(text)',
    'public.create_group(text, uuid[])', 'public.add_group_members(uuid, uuid[])', 'public.remove_group_member(uuid, uuid)',
    'public.set_group_admin(uuid, uuid, boolean)', 'public.leave_group(uuid)', 'public.update_group(uuid, text, text, boolean)'
    -- (display_name_of, group_system_message and is_group_admin stay internal)
  ] loop
    execute format('grant execute on function %s to authenticated', f);
  end loop;

  -- Needed before sign-in (registration form + username login).
  execute 'grant execute on function public.username_available(text) to anon';
  execute 'grant execute on function public.login_email_for_username(text) to anon';
end;
$$;

-- =============================================================================
-- 7. ROW LEVEL SECURITY
-- =============================================================================
alter table public.profiles                  enable row level security;
alter table public.user_presence             enable row level security;
alter table public.conversations             enable row level security;
alter table public.conversation_participants enable row level security;
alter table public.messages                  enable row level security;
alter table public.message_receipts          enable row level security;
alter table public.secret_rooms              enable row level security;
alter table public.secret_room_participants  enable row level security;
alter table public.secret_room_messages      enable row level security;

-- profiles
drop policy if exists "profiles: visible to self and contacts" on public.profiles;
drop policy if exists "profiles: owner can update"             on public.profiles;
create policy "profiles: visible to self and contacts" on public.profiles
  for select to authenticated using (public.can_view_profile(id));
create policy "profiles: owner can update" on public.profiles
  for update to authenticated using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- user_presence (writes only through touch_presence)
drop policy if exists "presence: visible to self and contacts" on public.user_presence;
create policy "presence: visible to self and contacts" on public.user_presence
  for select to authenticated using (public.can_view_profile(user_id));

-- conversations (writes only through RPC / trigger)
drop policy if exists "conversations: participants can read" on public.conversations;
create policy "conversations: participants can read" on public.conversations
  for select to authenticated using (public.is_conversation_participant(id));

drop policy if exists "conversation_participants: participants can read" on public.conversation_participants;
create policy "conversation_participants: participants can read" on public.conversation_participants
  for select to authenticated using (public.is_conversation_participant(conversation_id));

-- messages
drop policy if exists "messages: participants can read"       on public.messages;
drop policy if exists "messages: participants can send"       on public.messages;
drop policy if exists "messages: sender can edit"             on public.messages;
create policy "messages: participants can read" on public.messages
  for select to authenticated using (public.is_conversation_participant(conversation_id));
create policy "messages: participants can send" on public.messages
  for insert to authenticated
  with check (sender_id = (select auth.uid()) and kind <> 'system' and public.is_conversation_participant(conversation_id));
create policy "messages: sender can edit" on public.messages
  for update to authenticated
  using (sender_id = (select auth.uid()) and kind <> 'system' and public.is_conversation_participant(conversation_id))
  with check (sender_id = (select auth.uid()));

-- message_receipts (writes only through mark_delivered / mark_conversation_read)
drop policy if exists "receipts: recipient and sender can read" on public.message_receipts;
create policy "receipts: recipient and sender can read" on public.message_receipts
  for select to authenticated using (
    user_id = (select auth.uid())
    or exists (select 1 from public.messages m where m.id = message_id and m.sender_id = (select auth.uid()))
  );

-- secret rooms (writes only through RPC)
drop policy if exists "secret_rooms: participants can read" on public.secret_rooms;
create policy "secret_rooms: participants can read" on public.secret_rooms
  for select to authenticated using (public.is_room_participant(id));

drop policy if exists "secret_room_participants: participants can read" on public.secret_room_participants;
create policy "secret_room_participants: participants can read" on public.secret_room_participants
  for select to authenticated using (public.is_room_participant(room_id));

drop policy if exists "secret_room_messages: members read since joining" on public.secret_room_messages;
drop policy if exists "secret_room_messages: members can send"           on public.secret_room_messages;
drop policy if exists "secret_room_messages: sender can edit"            on public.secret_room_messages;
create policy "secret_room_messages: members read since joining" on public.secret_room_messages
  for select to authenticated using (created_at >= public.room_member_since(room_id));
create policy "secret_room_messages: members can send" on public.secret_room_messages
  for insert to authenticated
  with check (sender_id = (select auth.uid()) and public.is_room_participant(room_id));
create policy "secret_room_messages: sender can edit" on public.secret_room_messages
  for update to authenticated
  using (sender_id = (select auth.uid()) and public.is_room_participant(room_id))
  with check (sender_id = (select auth.uid()));

-- =============================================================================
-- 8. STORAGE — profile photos (bucket "avatars")
--    Public read (unguessable paths, linked only from profiles you can see);
--    users can only write inside their own folder "<user id>/...".
-- =============================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "avatars: owner can read own files" on storage.objects;
drop policy if exists "avatars: owner can upload"         on storage.objects;
drop policy if exists "avatars: owner can update"         on storage.objects;
drop policy if exists "avatars: owner can delete"         on storage.objects;
create policy "avatars: owner can read own files" on storage.objects
  for select to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "avatars: owner can upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "avatars: owner can update" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "avatars: owner can delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- -----------------------------------------------------------------------------
-- 8b. STORAGE — private-chat attachments (bucket "chat-media", PRIVATE)
--     Path: "<conversation id>/<uploader user id>/<file>". Only the two participants
--     can read (via short-lived signed URLs); you can only upload into your own folder.
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat-media', 'chat-media', false, 52428800, null)
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit;

create or replace function public.chat_object_conversation(p_name text)
returns uuid language sql immutable set search_path = public as $$
  select case
    when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/'
    then substring(p_name from 1 for 36)::uuid
  end;
$$;
revoke all on function public.chat_object_conversation(text) from public, anon;
grant execute on function public.chat_object_conversation(text) to authenticated;

drop policy if exists "chat-media: participants can read"   on storage.objects;
drop policy if exists "chat-media: participants can upload" on storage.objects;
drop policy if exists "chat-media: uploader can delete"     on storage.objects;
create policy "chat-media: participants can read" on storage.objects
  for select to authenticated
  using (bucket_id = 'chat-media' and public.is_conversation_participant(public.chat_object_conversation(name)));
create policy "chat-media: participants can upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'chat-media'
              and public.is_conversation_participant(public.chat_object_conversation(name))
              and (storage.foldername(name))[2] = (select auth.uid())::text);
create policy "chat-media: uploader can delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'chat-media' and (storage.foldername(name))[2] = (select auth.uid())::text);

-- =============================================================================
-- 9. REALTIME
-- =============================================================================
-- 9a. Postgres Changes (RLS is enforced per subscriber).
do $$
declare t text;
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
  foreach t in array array['messages', 'message_receipts', 'user_presence', 'secret_room_messages', 'conversation_participants'] loop
    if not exists (
      select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end;
$$;

-- 9b. Realtime Authorization for private broadcast channels (typing indicator).
--     (RLS is already enabled on realtime.messages in every Supabase project.)
drop policy if exists "fc: conversation members can receive" on realtime.messages;
drop policy if exists "fc: conversation members can send"    on realtime.messages;
create policy "fc: conversation members can receive" on realtime.messages
  for select to authenticated
  using (realtime.messages.extension = 'broadcast' and public.can_access_realtime_topic((select realtime.topic())));
create policy "fc: conversation members can send" on realtime.messages
  for insert to authenticated
  with check (realtime.messages.extension = 'broadcast' and public.can_access_realtime_topic((select realtime.topic())));

-- =============================================================================
-- 10. EXISTING USERS (migration only — creates profile rows for auth users that
--     already exist in this project; creates nothing when there are none)
-- =============================================================================
insert into public.profiles (id, phone)
select u.id, case when coalesce(u.phone, '') <> '' then '+' || ltrim(u.phone, '+') end
  from auth.users u
on conflict (id) do nothing;

insert into public.user_presence (user_id)
select p.id from public.profiles p
on conflict (user_id) do nothing;

-- Done.
