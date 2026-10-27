# Avisos push de Tupla

La app guarda en Supabase la suscripción de cada móvil (tabla `push_subs`, sección 11 de `profesionales.sql`) y esta función, ejecutada cada 5 minutos, decide qué recordatorios tocan y los envía.

## Puesta en marcha (una sola vez)

1. En Supabase, SQL Editor: ejecuta la **sección 11** de `supabase/profesionales.sql` (la parte sin comentar: tabla y dos funciones).
2. Edge Functions → Deploy a new function → nombre `push-send` → pega el contenido de `index.ts`. **Desactiva "Verify JWT"** (se protege con un secreto).
3. Edge Functions → Secrets, crea:
   - `VAPID_PUBLIC` — la clave pública (la misma que lleva `VAPID_PUB` en `index.html`)
   - `VAPID_PRIVATE` — la clave privada (no se sube a GitHub)
   - `VAPID_SUBJECT` — `mailto:` y tu correo
   - `CRON_SECRET` — una contraseña larga inventada
4. SQL Editor: activa `pg_cron` y `pg_net` y programa la función (bloque comentado al final de la sección 11), cambiando `<REF>` y `<CRON_SECRET>`.
5. En el móvil: abre la app (dos veces tras actualizar), Ajustes → Cuenta y datos → Recordatorios → "Activar avisos push".

En iPhone funciona solo con la app añadida a la pantalla de inicio (iOS 16.4 o superior).

## Cómo comprobarlo
`select * from public.push_subs;` debe mostrar una fila por móvil activado. Para forzar un envío, llama a la función con la cabecera `x-cron-secret`; devuelve `{subs, sent, removed}`.

## Qué avisa
Peso en ayunas, agua, registrar comidas y constancia (solo si falta hacerlo, según lo último que haya sincronizado el cliente) y citas (24 h y 1 h antes; también al profesional). Cada aviso se envía una vez al día.

## Reservas de citas
La sección 12 de `profesionales.sql` añade la disponibilidad del profesional (`pro_avail`) y las funciones `avail_slots`, `appt_book` y `appt_cancel`. Cuando un cliente reserva o cancela, se envía un mensaje al chat del profesional.
