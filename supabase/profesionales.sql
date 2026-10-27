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
-- Nº de colegiado o de registro profesional (lo escribe el profesional; tú marcas license_checked cuando lo compruebes)
alter table public.professionals add column if not exists license text;
alter table public.professionals add column if not exists license_checked boolean not null default false;

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
-- (la versión anterior no tenía p_license: se elimina para que no haya dos funciones con el mismo nombre)
drop function if exists public.become_professional(text, text);
create or replace function public.become_professional(p_name text, p_business text default null, p_license text default null)
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
       set name = trim(p_name), business = nullif(trim(coalesce(p_business, '')), ''),
           license_checked = case when nullif(trim(coalesce(p_license, '')), '') is not null
                                   and nullif(trim(coalesce(p_license, '')), '') is distinct from license then false else license_checked end,
           license = coalesce(nullif(trim(coalesce(p_license, '')), ''), license)
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
  insert into public.professionals (user_id, name, business, code, license)
  values (auth.uid(), trim(p_name), nullif(trim(coalesce(p_business, '')), ''), v_code, nullif(trim(coalesce(p_license, '')), ''))
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
  if not pr.license_checked then raise exception 'pro_unverified'; end if;
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

revoke all on function public.become_professional(text, text, text) from public, anon;
revoke all on function public.link_with_code(text, text)      from public, anon;
revoke all on function public.revoke_link(uuid)               from public, anon;
grant execute on function public.become_professional(text, text, text) to authenticated;
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
  select json_build_object('name', name, 'business', business, 'status', status, 'verified', license_checked)
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

-- 8) Verificación de profesionales ---------------------------------------------
-- Un profesional nuevo no puede usar el panel ni vincular clientes hasta que tú lo apruebes.
-- Sube un justificante (foto o PDF) a un almacenamiento privado que solo ve él y tú (desde el panel de Supabase).
alter table public.professionals add column if not exists license_doc text;
alter table public.professionals add column if not exists doc_at timestamptz;
alter table public.professionals add column if not exists review_note text;

-- ¿Puede operar este profesional? (aprobado y no suspendido). SECURITY DEFINER para no entrar en bucle con las políticas.
create or replace function public.pro_ok(p_uid uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.professionals
                  where user_id = p_uid and license_checked and status <> 'suspended')
$$;
revoke all on function public.pro_ok(uuid) from public, anon;
grant execute on function public.pro_ok(uuid) to authenticated;

-- El profesional solo ve sus clientes si está aprobado. Como las demás tablas (planes, notas, chat, fotos, perfiles)
-- comprueban el vínculo a través de esta tabla, un profesional no aprobado o suspendido pierde el acceso a todo.
drop policy if exists links_select on public.client_links;
create policy links_select on public.client_links for select
  using (client_id = auth.uid() or (pro_id = auth.uid() and public.pro_ok(auth.uid())));

-- El profesional registra qué archivo ha subido como justificante
create or replace function public.submit_pro_doc(p_path text)
returns public.professionals
language plpgsql security definer set search_path = public, auth as $$
declare r public.professionals;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if p_path is null or position(auth.uid()::text || '/' in p_path) <> 1 then raise exception 'bad_path'; end if;
  update public.professionals
     set license_doc = p_path, doc_at = now(), review_note = null
   where user_id = auth.uid() returning * into r;
  if not found then raise exception 'not_professional'; end if;
  return r;
end; $$;
revoke all on function public.submit_pro_doc(text) from public, anon;
grant execute on function public.submit_pro_doc(text) to authenticated;

-- Almacenamiento privado de justificantes: solo JPEG o PDF, máximo 5 MB. Cada profesional solo toca su carpeta.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('pro-docs', 'pro-docs', false, 5242880, array['image/jpeg', 'application/pdf'])
on conflict (id) do update
  set public = false, file_size_limit = 5242880, allowed_mime_types = array['image/jpeg', 'application/pdf'];

drop policy if exists prodocs_owner on storage.objects;
create policy prodocs_owner on storage.objects for all
  using (bucket_id = 'pro-docs' and (storage.foldername(name))[1] = auth.uid()::text)
  with check (bucket_id = 'pro-docs' and (storage.foldername(name))[1] = auth.uid()::text);

-- Cuentas que ya existían antes de este paso (por ejemplo la tuya de pruebas): apruébalas a mano con
--   update public.professionals set license_checked = true where user_id = '<id>';

-- Revisar solicitudes: profesionales sin aprobar y con justificante subido
--   select user_id, name, business, license, doc_at, license_doc from public.professionals
--    where not license_checked and license_doc is not null order by doc_at;
--   El archivo está en Supabase > Storage > pro-docs > carpeta con el user_id.
-- Aprobar:
--   update public.professionals set license_checked = true, review_note = null where user_id = '<id>';
-- Rechazar (el profesional verá el motivo y podrá subir otro justificante):
--   update public.professionals set license_checked = false, license_doc = null, doc_at = null,
--          review_note = 'La foto no se lee bien. Sube otra donde se vean tu nombre y tu número.' where user_id = '<id>';

-- 9) Administrador ---------------------------------------------------------------
-- Las cuentas de administrador se dan de alta SOLO a mano desde este editor (nunca desde la app):
--   insert into public.admins (user_id) select id from auth.users where email = 'tu-correo-de-admin@ejemplo.com';
-- Quitar a un administrador:   delete from public.admins where user_id = '<id>';
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;  -- sin políticas: nadie la lee desde la app

create or replace function public.is_admin()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- El administrador puede abrir los justificantes (solo esa carpeta de archivos)
drop policy if exists prodocs_admin on storage.objects;
create policy prodocs_admin on storage.objects for select
  using (bucket_id = 'pro-docs' and public.is_admin());

-- Lista de profesionales con su correo y nº de clientes activos
create or replace function public.admin_list_pros()
returns json
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  return coalesce((
    select json_agg(x order by x.created_at desc) from (
      select p.user_id, p.name, p.business, p.license, p.license_checked, p.license_doc, p.doc_at,
             p.review_note, p.status, p.max_clients, p.code, p.created_at, u.email,
             (select count(*) from public.client_links l where l.pro_id = p.user_id and l.status = 'active')::int as clients
        from public.professionals p join auth.users u on u.id = p.user_id
    ) x), '[]'::json);
end; $$;
revoke all on function public.admin_list_pros() from public, anon;
grant execute on function public.admin_list_pros() to authenticated;

-- Acciones sobre un profesional: approve, reject (con motivo), suspend, trial, active
create or replace function public.admin_set_pro(p_user uuid, p_action text, p_note text default null)
returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  if p_action = 'approve' then
    update public.professionals set license_checked = true, review_note = null where user_id = p_user;
  elsif p_action = 'reject' then
    if coalesce(trim(p_note), '') = '' then raise exception 'note_required'; end if;
    update public.professionals set license_checked = false, license_doc = null, doc_at = null,
           review_note = left(trim(p_note), 300) where user_id = p_user;
  elsif p_action = 'suspend' then
    update public.professionals set status = 'suspended' where user_id = p_user;
  elsif p_action = 'trial' then
    update public.professionals set status = 'trial' where user_id = p_user;
  elsif p_action = 'active' then
    update public.professionals set status = 'active' where user_id = p_user;
  else
    raise exception 'bad_action';
  end if;
  if not found then raise exception 'not_found'; end if;
end; $$;
revoke all on function public.admin_set_pro(uuid, text, text) from public, anon;
grant execute on function public.admin_set_pro(uuid, text, text) to authenticated;

-- Resumen con cifras (sin datos personales)
create or replace function public.admin_overview()
returns json
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'not_admin'; end if;
  return json_build_object(
    'users',      (select count(*) from auth.users),
    'pros',       (select count(*) from public.professionals),
    'waiting',    (select count(*) from public.professionals where not license_checked and license_doc is not null),
    'nodoc',      (select count(*) from public.professionals where not license_checked and license_doc is null),
    'approved',   (select count(*) from public.professionals where license_checked and status <> 'suspended'),
    'suspended',  (select count(*) from public.professionals where status = 'suspended'),
    'links',      (select count(*) from public.client_links where status = 'active'),
    'profiles',   (select count(*) from public.plan_profiles)
  );
end; $$;
revoke all on function public.admin_overview() from public, anon;
grant execute on function public.admin_overview() to authenticated;

-- 10) Citas y videollamadas ------------------------------------------------------
-- El profesional crea y cambia las citas; el cliente las ve y solo puede responder (confirmar / no puedo).
-- Las notas de cada visita son privadas del profesional (tabla aparte, el cliente no tiene acceso).
create table if not exists public.appointments (
  id         uuid primary key default gen_random_uuid(),
  link_id    uuid not null references public.client_links(id) on delete cascade,
  starts_at  timestamptz not null,
  minutes    int not null default 30 check (minutes between 5 and 240),
  kind       text not null default 'video' check (kind in ('video','presencial','tel')),
  place      text check (char_length(place) <= 300),   -- enlace de la videollamada, dirección o teléfono
  topic      text check (char_length(topic) <= 200),   -- lo ve el cliente
  status     text not null default 'planned' check (status in ('planned','done','cancelled')),
  client_resp text check (client_resp in ('yes','no')),
  resp_at    timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists appointments_link_idx on public.appointments(link_id, starts_at);
alter table public.appointments enable row level security;

drop policy if exists appt_select on public.appointments;
create policy appt_select on public.appointments for select
  using (exists (select 1 from public.client_links l
                 where l.id = appointments.link_id and l.status = 'active'
                   and (l.client_id = auth.uid() or (l.pro_id = auth.uid() and public.pro_ok(auth.uid())))));
drop policy if exists appt_insert on public.appointments;
create policy appt_insert on public.appointments for insert
  with check (exists (select 1 from public.client_links l
                      where l.id = appointments.link_id and l.status = 'active'
                        and l.pro_id = auth.uid() and public.pro_ok(auth.uid())));
drop policy if exists appt_update on public.appointments;
create policy appt_update on public.appointments for update
  using (exists (select 1 from public.client_links l
                 where l.id = appointments.link_id and l.status = 'active'
                   and l.pro_id = auth.uid() and public.pro_ok(auth.uid())))
  with check (exists (select 1 from public.client_links l
                      where l.id = appointments.link_id and l.status = 'active'
                        and l.pro_id = auth.uid() and public.pro_ok(auth.uid())));
drop policy if exists appt_delete on public.appointments;
create policy appt_delete on public.appointments for delete
  using (exists (select 1 from public.client_links l
                 where l.id = appointments.link_id and l.pro_id = auth.uid() and public.pro_ok(auth.uid())));

-- Notas privadas de cada visita (solo el profesional)
create table if not exists public.appointment_notes (
  appt_id    uuid primary key references public.appointments(id) on delete cascade,
  body       text check (char_length(body) <= 4000),
  updated_at timestamptz not null default now()
);
alter table public.appointment_notes enable row level security;
drop policy if exists appt_notes_all on public.appointment_notes;
create policy appt_notes_all on public.appointment_notes for all
  using (exists (select 1 from public.appointments a join public.client_links l on l.id = a.link_id
                 where a.id = appointment_notes.appt_id and l.pro_id = auth.uid() and public.pro_ok(auth.uid())))
  with check (exists (select 1 from public.appointments a join public.client_links l on l.id = a.link_id
                      where a.id = appointment_notes.appt_id and l.pro_id = auth.uid() and l.status = 'active'
                        and public.pro_ok(auth.uid())));

-- El cliente responde a una cita futura: 'yes' (confirmo) o 'no' (no puedo)
create or replace function public.appt_respond(p_appt uuid, p_resp text)
returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if p_resp not in ('yes','no') then raise exception 'bad_response'; end if;
  update public.appointments a
     set client_resp = p_resp, resp_at = now(), updated_at = now()
   where a.id = p_appt and a.status = 'planned' and a.starts_at > now()
     and exists (select 1 from public.client_links l
                 where l.id = a.link_id and l.client_id = auth.uid() and l.status = 'active');
  if not found then raise exception 'not_found'; end if;
end; $$;
revoke all on function public.appt_respond(uuid, text) from public, anon;
grant execute on function public.appt_respond(uuid, text) to authenticated;

-- 11) Notificaciones push en el móvil ----------------------------------------------
-- Cada móvil que activa los avisos guarda aquí su suscripción y los recordatorios elegidos.
-- La función "push-send" (supabase/functions/push-send) lee esta tabla cada 5 minutos y envía los avisos.
create table if not exists public.push_subs (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users(id) on delete cascade,
  profile_id text,                                  -- perfil del cliente (null en cuentas de profesional)
  endpoint   text not null unique,
  p256dh     text not null,
  auth       text not null,
  tz         text not null default 'Europe/Madrid',
  rem        jsonb not null default '{}'::jsonb,
  last_sent  jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists push_subs_user_idx on public.push_subs(user_id);
alter table public.push_subs enable row level security;
-- Sin políticas: la app solo accede con las dos funciones de abajo y la función push-send con la clave de servicio.
revoke all on public.push_subs from anon, authenticated;

create or replace function public.push_save(p_endpoint text, p_p256dh text, p_auth text, p_tz text, p_profile text, p_rem jsonb)
returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  if p_endpoint is null or p_endpoint !~ '^https://' or char_length(p_endpoint) > 1000 then raise exception 'bad_endpoint'; end if;
  insert into public.push_subs (user_id, profile_id, endpoint, p256dh, auth, tz, rem)
  values (auth.uid(), p_profile, p_endpoint, p_p256dh, p_auth, coalesce(nullif(p_tz, ''), 'Europe/Madrid'), coalesce(p_rem, '{}'::jsonb))
  on conflict (endpoint) do update
     set user_id = auth.uid(), profile_id = excluded.profile_id, p256dh = excluded.p256dh, auth = excluded.auth,
         tz = excluded.tz, rem = excluded.rem, updated_at = now(),
         last_sent = case when public.push_subs.user_id = auth.uid() then public.push_subs.last_sent else '{}'::jsonb end;
end; $$;
revoke all on function public.push_save(text, text, text, text, text, jsonb) from public, anon;
grant execute on function public.push_save(text, text, text, text, text, jsonb) to authenticated;

create or replace function public.push_remove(p_endpoint text)
returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  delete from public.push_subs where endpoint = p_endpoint and user_id = auth.uid();
end; $$;
revoke all on function public.push_remove(text) from public, anon;
grant execute on function public.push_remove(text) to authenticated;

-- Programar la función cada 5 minutos (cambia <REF> por el id de tu proyecto y <CRON_SECRET> por el secreto que pongas en la función):
--   create extension if not exists pg_cron;
--   create extension if not exists pg_net;
--   select cron.schedule('tupla-push', '*/5 * * * *', $$
--     select net.http_post(
--       url := 'https://<REF>.supabase.co/functions/v1/push-send',
--       headers := '{"Content-Type":"application/json","x-cron-secret":"<CRON_SECRET>"}'::jsonb,
--       body := '{}'::jsonb) $$);
-- Para pararlo:  select cron.unschedule('tupla-push');

-- 12) Disponibilidad del profesional y reserva de citas por el cliente ----------------
-- El profesional publica franjas semanales; el cliente ve los huecos libres y reserva uno.
-- El cliente nunca lee las citas de otros clientes: los huecos los calcula la función avail_slots.
create table if not exists public.pro_avail (
  pro_id     uuid primary key references public.professionals(user_id) on delete cascade,
  rules      jsonb not null default '[]'::jsonb check (jsonb_typeof(rules) = 'array' and jsonb_array_length(rules) <= 60),
  blocked    jsonb not null default '[]'::jsonb check (jsonb_typeof(blocked) = 'array' and jsonb_array_length(blocked) <= 200),
  slot_min   int  not null default 30 check (slot_min between 10 and 120),
  kind       text not null default 'video' check (kind in ('video','presencial','tel')),
  place      text check (char_length(place) <= 300),
  notice_h   int  not null default 12 check (notice_h between 0 and 168),
  horizon_d  int  not null default 28 check (horizon_d between 7 and 120),
  tz         text not null default 'Europe/Madrid',
  updated_at timestamptz not null default now()
);
alter table public.pro_avail enable row level security;
drop policy if exists avail_select on public.pro_avail;
create policy avail_select on public.pro_avail for select using (pro_id = auth.uid());
drop policy if exists avail_insert on public.pro_avail;
create policy avail_insert on public.pro_avail for insert with check (pro_id = auth.uid() and public.pro_ok(auth.uid()));
drop policy if exists avail_update on public.pro_avail;
create policy avail_update on public.pro_avail for update using (pro_id = auth.uid() and public.pro_ok(auth.uid())) with check (pro_id = auth.uid() and public.pro_ok(auth.uid()));

-- Huecos libres del profesional vinculado al cliente (próximos horizon_d días)
create or replace function public.avail_slots(p_link uuid)
returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare v_pro uuid; v_av public.pro_avail%rowtype; v_slots jsonb;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select l.pro_id into v_pro from public.client_links l
   where l.id = p_link and l.client_id = auth.uid() and l.status = 'active';
  if v_pro is null then raise exception 'not_found'; end if;
  select * into v_av from public.pro_avail where pro_id = v_pro;
  if not found or not public.pro_ok(v_pro) or jsonb_array_length(v_av.rules) = 0 then
    return jsonb_build_object('slots', '[]'::jsonb, 'minutes', null, 'kind', null);
  end if;
  select coalesce(jsonb_agg(x.st order by x.st), '[]'::jsonb) into v_slots from (
    select distinct ((d.d + r.s) + make_interval(mins => m.m)) at time zone v_av.tz as st
      from (select ((now() at time zone v_av.tz)::date + g) as d from generate_series(0, v_av.horizon_d) g) d
      join (select (e->>'d')::int as dow, (e->>'s')::time as s, (e->>'e')::time as en
              from jsonb_array_elements(v_av.rules) e) r
        on extract(isodow from d.d)::int = r.dow
      cross join lateral generate_series(0, (extract(epoch from (r.en - r.s)) / 60)::int - v_av.slot_min, v_av.slot_min) as m(m)
     where not jsonb_exists(v_av.blocked, d.d::text)
  ) x
  where x.st >= now() + make_interval(hours => v_av.notice_h)
    and not exists (
      select 1 from public.appointments a join public.client_links l2 on l2.id = a.link_id
       where l2.pro_id = v_pro and a.status = 'planned'
         and a.starts_at < x.st + make_interval(mins => v_av.slot_min)
         and a.starts_at + make_interval(mins => a.minutes) > x.st);
  return jsonb_build_object('slots', v_slots, 'minutes', v_av.slot_min, 'kind', v_av.kind);
end; $$;
revoke all on function public.avail_slots(uuid) from public, anon;
grant execute on function public.avail_slots(uuid) to authenticated;

-- El cliente reserva un hueco (máximo 2 citas pendientes a la vez)
create or replace function public.appt_book(p_link uuid, p_starts timestamptz)
returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare v_pro uuid; v_av public.pro_avail%rowtype; v_id uuid; v_ok boolean;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select l.pro_id into v_pro from public.client_links l
   where l.id = p_link and l.client_id = auth.uid() and l.status = 'active';
  if v_pro is null then raise exception 'not_found'; end if;
  perform pg_advisory_xact_lock(hashtext(v_pro::text));
  if (select count(*) from public.appointments a
       where a.link_id = p_link and a.status = 'planned' and a.starts_at > now()) >= 2 then
    raise exception 'too_many';
  end if;
  select exists (select 1 from jsonb_array_elements_text(public.avail_slots(p_link)->'slots') s
                  where s::timestamptz = p_starts) into v_ok;
  if not v_ok then raise exception 'slot_taken'; end if;
  select * into v_av from public.pro_avail where pro_id = v_pro;
  insert into public.appointments (link_id, starts_at, minutes, kind, place, topic, client_resp, resp_at)
  values (p_link, p_starts, v_av.slot_min, v_av.kind, v_av.place, 'Cita reservada por el cliente', 'yes', now())
  returning id into v_id;
  insert into public.chat_messages (link_id, sender_id, body)
  values (p_link, auth.uid(), 'He reservado una cita el ' || to_char(p_starts at time zone v_av.tz, 'DD/MM') || ' a las ' || to_char(p_starts at time zone v_av.tz, 'HH24:MI') || '.');
  return (select to_jsonb(a) from public.appointments a where a.id = v_id);
end; $$;
revoke all on function public.appt_book(uuid, timestamptz) from public, anon;
grant execute on function public.appt_book(uuid, timestamptz) to authenticated;

-- El cliente cancela una cita suya con la antelación mínima que fijó el profesional
create or replace function public.appt_cancel(p_appt uuid)
returns void
language plpgsql security definer set search_path = public, auth as $$
declare v_a public.appointments%rowtype; v_pro uuid; v_notice int; v_tz text;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select a.* into v_a from public.appointments a join public.client_links l on l.id = a.link_id
   where a.id = p_appt and a.status = 'planned' and l.client_id = auth.uid() and l.status = 'active';
  if not found then raise exception 'not_found'; end if;
  select l.pro_id into v_pro from public.client_links l where l.id = v_a.link_id;
  select coalesce(notice_h, 12), coalesce(tz, 'Europe/Madrid') into v_notice, v_tz from public.pro_avail where pro_id = v_pro;
  if not found then v_notice := 12; v_tz := 'Europe/Madrid'; end if;
  if v_a.starts_at < now() + make_interval(hours => v_notice) then raise exception 'too_late'; end if;
  update public.appointments set status = 'cancelled', updated_at = now() where id = p_appt;
  insert into public.chat_messages (link_id, sender_id, body)
  values (v_a.link_id, auth.uid(), 'He cancelado la cita del ' || to_char(v_a.starts_at at time zone v_tz, 'DD/MM') || ' a las ' || to_char(v_a.starts_at at time zone v_tz, 'HH24:MI') || '.');
end; $$;
revoke all on function public.appt_cancel(uuid) from public, anon;
grant execute on function public.appt_cancel(uuid) to authenticated;

-- Para activar a un profesional de pago sin límite de clientes:
--   update public.professionals set status = 'active' where user_id = '<id>';
-- Para suspenderlo:
--   update public.professionals set status = 'suspended' where user_id = '<id>';
-- Para revisar los profesionales nuevos y su nº de colegiado:
--   select user_id, name, business, license, license_checked, status, created_at from public.professionals order by created_at desc;
-- Cuando hayas comprobado el nº de colegiado:
--   update public.professionals set license_checked = true where user_id = '<id>';
