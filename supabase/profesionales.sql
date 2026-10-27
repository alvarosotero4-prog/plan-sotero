-- Plan: panel para nutricionistas y dietistas
-- Pega este script entero en Supabase > SQL Editor y pulsa Run (una sola vez).
-- Es seguro repetirlo: usa "if not exists" y "create or replace".
-- Supabase avisará de "operaciones destructivas" por los "drop policy": son solo
-- las políticas de este script, no borran datos.

-- 1) Tablas -----------------------------------------------------------------
create table if not exists public.professionals (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  name       text not null,
  business   text,
  code       text not null unique,
  status     text not null default 'trial' check (status in ('trial','active','suspended')),
  max_clients int not null default 3,
  created_at timestamptz not null default now()
);

create table if not exists public.client_links (
  id          uuid primary key default gen_random_uuid(),
  pro_id      uuid not null references public.professionals(user_id) on delete cascade,
  client_id   uuid not null references auth.users(id) on delete cascade,
  profile_id  text not null,
  client_name text,
  client_email text,
  status      text not null default 'active' check (status in ('active','revoked')),
  consented_at timestamptz not null default now(),
  revoked_at  timestamptz,
  created_at  timestamptz not null default now(),
  unique (pro_id, client_id, profile_id)
);
create index if not exists client_links_pro_idx on public.client_links(pro_id);
create index if not exists client_links_client_idx on public.client_links(client_id);

create table if not exists public.pro_plans (
  link_id    uuid primary key references public.client_links(id) on delete cascade,
  targets    jsonb,
  note       text,
  updated_at timestamptz not null default now()
);

create table if not exists public.pro_notes (
  link_id    uuid primary key references public.client_links(id) on delete cascade,
  body       text,
  updated_at timestamptz not null default now()
);

-- 2) Seguridad por filas -----------------------------------------------------
alter table public.professionals enable row level security;
alter table public.client_links  enable row level security;
alter table public.pro_plans     enable row level security;
alter table public.pro_notes     enable row level security;

-- professionals: cada profesional ve la suya; el cliente vinculado ve a su profesional
drop policy if exists pro_select_own on public.professionals;
create policy pro_select_own on public.professionals for select
  using (user_id = auth.uid());
drop policy if exists pro_select_by_client on public.professionals;
create policy pro_select_by_client on public.professionals for select
  using (exists (select 1 from public.client_links l
                 where l.pro_id = professionals.user_id and l.client_id = auth.uid() and l.status = 'active'));

-- client_links: solo lectura para las dos partes; se crea y revoca con las funciones de abajo
drop policy if exists links_select on public.client_links;
create policy links_select on public.client_links for select
  using (pro_id = auth.uid() or client_id = auth.uid());

-- pro_plans: el profesional escribe; el cliente solo lee
drop policy if exists plans_select on public.pro_plans;
create policy plans_select on public.pro_plans for select
  using (exists (select 1 from public.client_links l
                 where l.id = pro_plans.link_id and (l.pro_id = auth.uid() or l.client_id = auth.uid())));
drop policy if exists plans_insert on public.pro_plans;
create policy plans_insert on public.pro_plans for insert
  with check (exists (select 1 from public.client_links l
                      where l.id = pro_plans.link_id and l.pro_id = auth.uid() and l.status = 'active'));
drop policy if exists plans_update on public.pro_plans;
create policy plans_update on public.pro_plans for update
  using (exists (select 1 from public.client_links l
                 where l.id = pro_plans.link_id and l.pro_id = auth.uid() and l.status = 'active'))
  with check (exists (select 1 from public.client_links l
                      where l.id = pro_plans.link_id and l.pro_id = auth.uid() and l.status = 'active'));

-- pro_notes: privadas del profesional (el cliente no las ve)
drop policy if exists notes_all on public.pro_notes;
create policy notes_all on public.pro_notes for all
  using (exists (select 1 from public.client_links l where l.id = pro_notes.link_id and l.pro_id = auth.uid()))
  with check (exists (select 1 from public.client_links l where l.id = pro_notes.link_id and l.pro_id = auth.uid() and l.status = 'active'));

-- plan_profiles: el profesional puede LEER el perfil que el cliente ha compartido, mientras el vínculo esté activo
drop policy if exists pro_read_clients on public.plan_profiles;
create policy pro_read_clients on public.plan_profiles for select
  using (exists (select 1 from public.client_links l
                 where l.pro_id = auth.uid() and l.client_id = plan_profiles.user_id
                   and l.profile_id = plan_profiles.id and l.status = 'active'));

-- 3) Funciones ---------------------------------------------------------------
create or replace function public.become_professional(p_name text, p_business text default null)
returns public.professionals
language plpgsql security definer set search_path = public, auth as $$
declare
  alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code text; r public.professionals; i int := 0; k int;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if coalesce(trim(p_name), '') = '' then raise exception 'name_required'; end if;
  select * into r from public.professionals where user_id = auth.uid();
  if found then
    update public.professionals
       set name = trim(p_name), business = nullif(trim(coalesce(p_business, '')), '')
     where user_id = auth.uid() returning * into r;
    return r;
  end if;
  loop
    v_code := '';
    for k in 1..6 loop
      v_code := v_code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.professionals where code = v_code);
    i := i + 1;
    if i > 25 then raise exception 'code_failed'; end if;
  end loop;
  insert into public.professionals (user_id, name, business, code)
  values (auth.uid(), trim(p_name), nullif(trim(coalesce(p_business, '')), ''), v_code)
  returning * into r;
  return r;
end; $$;

create or replace function public.link_with_code(p_code text, p_profile text)
returns public.client_links
language plpgsql security definer set search_path = public, auth as $$
declare
  pr public.professionals; l public.client_links; v_name text; v_email text; n int; existed boolean;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select * into pr from public.professionals where code = upper(trim(p_code));
  if not found then raise exception 'invalid_code'; end if;
  if pr.status = 'suspended' then raise exception 'pro_suspended'; end if;
  if pr.user_id = auth.uid() then raise exception 'self_link'; end if;
  select name into v_name from public.plan_profiles where user_id = auth.uid() and id = p_profile;
  if not found then raise exception 'profile_not_found'; end if;
  select email into v_email from auth.users where id = auth.uid();
  select * into l from public.client_links
   where pro_id = pr.user_id and client_id = auth.uid() and profile_id = p_profile;
  existed := found;
  if existed and l.status = 'active' then return l; end if;
  select count(*) into n from public.client_links where pro_id = pr.user_id and status = 'active';
  if pr.status = 'trial' and n >= pr.max_clients then raise exception 'pro_full'; end if;
  if existed then
    update public.client_links
       set status = 'active', consented_at = now(), revoked_at = null, client_name = v_name, client_email = v_email
     where id = l.id returning * into l;
  else
    insert into public.client_links (pro_id, client_id, profile_id, client_name, client_email)
    values (pr.user_id, auth.uid(), p_profile, v_name, v_email) returning * into l;
  end if;
  return l;
end; $$;

create or replace function public.revoke_link(p_link uuid)
returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  update public.client_links
     set status = 'revoked', revoked_at = now()
   where id = p_link and (client_id = auth.uid() or pro_id = auth.uid());
end; $$;

revoke all on function public.become_professional(text, text) from public, anon;
revoke all on function public.link_with_code(text, text)      from public, anon;
revoke all on function public.revoke_link(uuid)               from public, anon;
grant execute on function public.become_professional(text, text) to authenticated;
grant execute on function public.link_with_code(text, text)      to authenticated;
grant execute on function public.revoke_link(uuid)               to authenticated;

-- 4) Menús del nutricionista --------------------------------------------------
-- El profesional guarda aquí el menú semanal que ve el cliente (alimentos y gramos).
alter table public.pro_plans add column if not exists menu jsonb;

-- 5) Comprobar un código antes de empezar el cuestionario -----------------------
-- Devuelve el nombre del profesional (no su email) o null si el código no existe.
create or replace function public.pro_by_code(p_code text)
returns json
language sql stable security definer set search_path = public, auth as $$
  select json_build_object('name', name, 'business', business, 'status', status)
    from public.professionals
   where code = upper(trim(p_code)) and status <> 'suspended' and auth.uid() is not null
$$;
revoke all on function public.pro_by_code(text) from public, anon;
grant execute on function public.pro_by_code(text) to authenticated;

-- 6) Chat entre cliente y nutricionista ---------------------------------------
create table if not exists public.chat_messages (
  id         bigint generated always as identity primary key,
  link_id    uuid not null references public.client_links(id) on delete cascade,
  sender_id  uuid not null references auth.users(id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now(),
  read_at    timestamptz
);
create index if not exists chat_messages_link_idx on public.chat_messages(link_id, created_at);
create index if not exists chat_messages_unread_idx on public.chat_messages(link_id) where read_at is null;
alter table public.chat_messages enable row level security;

-- Solo las dos personas del vínculo, y solo mientras el vínculo esté activo
drop policy if exists chat_select on public.chat_messages;
create policy chat_select on public.chat_messages for select
  using (exists (select 1 from public.client_links l
                 where l.id = chat_messages.link_id and l.status = 'active'
                   and (l.pro_id = auth.uid() or l.client_id = auth.uid())));
drop policy if exists chat_insert on public.chat_messages;
create policy chat_insert on public.chat_messages for insert
  with check (sender_id = auth.uid()
              and exists (select 1 from public.client_links l
                          where l.id = chat_messages.link_id and l.status = 'active'
                            and (l.pro_id = auth.uid() or l.client_id = auth.uid())));
-- No se pueden editar ni borrar mensajes desde la app (solo se marcan como leídos con la función de abajo)
revoke update, delete on public.chat_messages from anon, authenticated;

create or replace function public.chat_mark_read(p_link uuid)
returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  update public.chat_messages m
     set read_at = now()
   where m.link_id = p_link and m.read_at is null and m.sender_id <> auth.uid()
     and exists (select 1 from public.client_links l
                 where l.id = p_link and l.status = 'active'
                   and (l.pro_id = auth.uid() or l.client_id = auth.uid()));
end; $$;
revoke all on function public.chat_mark_read(uuid) from public, anon;
grant execute on function public.chat_mark_read(uuid) to authenticated;

-- 7) Fotos de progreso compartidas con el nutricionista ------------------------
-- Las fotos se guardan en el móvil del cliente. Solo si el cliente activa "compartir mis fotos"
-- se sube una copia aquí, y el nutricionista vinculado puede verla mientras dure el vínculo.
alter table public.client_links add column if not exists share_photos boolean not null default false;

-- El cliente activa o desactiva compartir fotos en su vínculo
create or replace function public.set_share_photos(p_link uuid, p_on boolean)
returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  update public.client_links set share_photos = p_on
   where id = p_link and client_id = auth.uid() and status = 'active';
  if not found then raise exception 'link_not_found'; end if;
end; $$;
revoke all on function public.set_share_photos(uuid, boolean) from public, anon;
grant execute on function public.set_share_photos(uuid, boolean) to authenticated;

-- Ficha de cada foto (fecha y ángulo); el archivo va al almacenamiento privado
create table if not exists public.progress_photos (
  user_id    uuid not null references auth.users(id) on delete cascade,
  profile_id text not null,
  id         text not null,
  date       text not null,
  angle      text not null,
  path       text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, profile_id, id)
);
alter table public.progress_photos enable row level security;

drop policy if exists photos_owner on public.progress_photos;
create policy photos_owner on public.progress_photos for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- El nutricionista solo las ve si el vínculo está activo y el cliente ha activado compartir fotos
drop policy if exists photos_pro_select on public.progress_photos;
create policy photos_pro_select on public.progress_photos for select
  using (exists (select 1 from public.client_links l
                 where l.pro_id = auth.uid() and l.client_id = progress_photos.user_id
                   and l.profile_id = progress_photos.profile_id
                   and l.status = 'active' and l.share_photos));

-- Almacenamiento privado (sin enlaces públicos), solo JPEG y máximo 3 MB por foto
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('progress-photos', 'progress-photos', false, 3145728, array['image/jpeg'])
on conflict (id) do update
  set public = false, file_size_limit = 3145728, allowed_mime_types = array['image/jpeg'];

-- Ruta de cada archivo: <id del cliente>/<id del perfil>/<id de la foto>.jpg
drop policy if exists photos_obj_owner on storage.objects;
create policy photos_obj_owner on storage.objects for all
  using (bucket_id = 'progress-photos' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'progress-photos' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists photos_obj_pro on storage.objects;
create policy photos_obj_pro on storage.objects for select
  using (bucket_id = 'progress-photos'
         and exists (select 1 from public.client_links l
                     where l.pro_id = auth.uid()
                       and l.client_id::text = (storage.foldername(name))[1]
                       and l.profile_id = (storage.foldername(name))[2]
                       and l.status = 'active' and l.share_photos));

-- Para activar a un profesional de pago sin límite de clientes:
--   update public.professionals set status = 'active' where user_id = '<id>';
-- Para suspenderlo:
--   update public.professionals set status = 'suspended' where user_id = '<id>';
