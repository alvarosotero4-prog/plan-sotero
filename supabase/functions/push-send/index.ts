// @ts-nocheck
// Envía los recordatorios push de Tupla. Se ejecuta cada 5 minutos (ver sección 11 de profesionales.sql).
// Secretos necesarios (Edge Functions > Secrets): VAPID_PUBLIC, VAPID_PRIVATE, VAPID_SUBJECT, CRON_SECRET.
// Desactiva "Verify JWT" al desplegarla: se protege con la cabecera x-cron-secret.
import { createClient } from 'npm:@supabase/supabase-js@2';
import webpush from 'npm:web-push@3.6.7';

// ---- lógica de qué avisos tocan (sin dependencias, probada aparte) ----
const KIND_L = { video: 'Videollamada', presencial: 'En consulta', tel: 'Llamada' };
function pad(n) { return String(n).padStart(2, '0'); }
function localParts(nowMs, tz) {
  let f;
  try { f = new Intl.DateTimeFormat('en-CA', { timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }); }
  catch (_e) { f = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Madrid', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }); }
  const p = {}; f.formatToParts(new Date(nowMs)).forEach((x) => { p[x.type] = x.value; });
  return { date: p.year + '-' + p.month + '-' + p.day, min: (+p.hour) * 60 + (+p.minute) };
}
function addDays(ymd, n) { const d = new Date(ymd + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); }
function hmMin(hm) { const q = String(hm).split(':'); return (+q[0]) * 60 + (+q[1]); }
function hasLog(data, d) {
  const L = (data && data.logs && data.logs[d]) || {};
  return Object.keys(L).some((k) => Array.isArray(L[k]) && L[k].some((e) => e && e.g > 0));
}
function hmIn(iso, tz) {
  try { return new Intl.DateTimeFormat('es-ES', { timeZone: tz, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(new Date(iso)); }
  catch (_e) { return iso.slice(11, 16); }
}
function relDay(iso, tz, today) {
  const d = localParts(Date.parse(iso), tz).date;
  return d === today ? 'Hoy' : d === addDays(today, 1) ? 'Mañana' : d;
}
function apptNotes(appts, tz, who, nowMs, today) {
  const out = [];
  (appts || []).forEach((a) => {
    const dt = Date.parse(a.starts_at) - nowMs, label = (who ? who + ' · ' : '') + hmIn(a.starts_at, tz) + ' · ' + (KIND_L[a.kind] || 'Cita');
    if (dt > 0 && dt <= 3600e3) out.push({ key: 'a1:' + a.id, title: 'Cita en menos de una hora', body: label });
    else if (dt > 3600e3 && dt <= 26 * 3600e3) out.push({ key: 'a24:' + a.id, title: relDay(a.starts_at, tz, today) + ' tienes una cita', body: label });
  });
  return out;
}
// sub: {rem, last_sent, tz, isPro}; data: perfil del cliente; appts: citas ya filtradas de este usuario
function computeDue(sub, data, appts, who, nowMs) {
  const rem = sub.rem || {}, last = sub.last_sent || {}, tz = sub.tz || 'Europe/Madrid';
  const lp = localParts(nowMs, tz), t = lp.date, mins = lp.min, out = [];
  if (sub.isPro) {
    apptNotes(appts, tz, who, nowMs, t).forEach((n) => { if (!last[n.key]) out.push(n); });
    return out;
  }
  if (!rem.on) return out;
  const inWin = (hm) => mins >= hmMin(hm) && mins < hmMin(hm) + 180;
  const w = (k) => rem[k] && rem[k].on && /^\d{1,2}:\d{2}$/.test(rem[k].t || '');
  if (w('weigh') && inWin(rem.weigh.t) && last.weigh !== t && !(data && data.weights && data.weights[t] != null))
    out.push({ key: 'weigh', title: 'Tupla', body: 'Pésate en ayunas y apúntalo en Hoy.' });
  if (w('water') && inWin(rem.water.t) && last.water !== t) {
    const kg = (data && data.settings && +data.settings.kg) || 70, goal = kg * 0.0375, got = +((data && data.track && data.track[t] && data.track[t].water) || 0);
    if (got < goal) out.push({ key: 'water', title: 'Tupla', body: 'Llevas ' + got.toFixed(1).replace('.', ',') + ' L de agua; tu objetivo de hoy es ' + goal.toFixed(1).replace('.', ',') + ' L.' });
  }
  if (w('meals') && inWin(rem.meals.t) && last.meals !== t && !hasLog(data, t))
    out.push({ key: 'meals', title: 'Tupla', body: 'Todavía no has registrado comidas hoy.' });
  if (rem.cons && rem.cons.on && mins >= 9 * 60 && mins < 12 * 60 && last.cons !== t) {
    const y = addDays(t, -1);
    if (!hasLog(data, y) && !hasLog(data, t) && Object.keys((data && data.logs) || {}).some((d) => d < y && hasLog(data, d)))
      out.push({ key: 'cons', title: 'Tupla', body: 'Ayer no registraste comidas. Un día suelto no pasa nada: retoma hoy.' });
  }
  if (rem.appt && rem.appt.on) apptNotes(appts, tz, who, nowMs, t).forEach((n) => { if (!last[n.key]) out.push(n); });
  return out;
}
function pruneLast(last, today) {
  const lim = addDays(today, -10), o = {};
  Object.keys(last || {}).forEach((k) => { if (String(last[k]) >= lim) o[k] = last[k]; });
  return o;
}
// ---- fin de la lógica ----

Deno.serve(async (req) => {
  if (req.headers.get('x-cron-secret') !== Deno.env.get('CRON_SECRET') || !Deno.env.get('CRON_SECRET'))
    return new Response('forbidden', { status: 403 });
  webpush.setVapidDetails(Deno.env.get('VAPID_SUBJECT') || 'mailto:admin@example.com', Deno.env.get('VAPID_PUBLIC')!, Deno.env.get('VAPID_PRIVATE')!);
  const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  const nowMs = Date.now();
  const { data: subs, error } = await sb.from('push_subs').select('*');
  if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500 });
  if (!subs || !subs.length) return new Response(JSON.stringify({ subs: 0, sent: 0 }));

  const clientIds = [...new Set(subs.filter((s) => s.profile_id).map((s) => s.user_id))];
  const proIds = [...new Set(subs.filter((s) => !s.profile_id).map((s) => s.user_id))];
  const links: any[] = [];
  if (clientIds.length) { const r = await sb.from('client_links').select('id,pro_id,client_id,profile_id,client_name,professionals(name)').eq('status', 'active').in('client_id', clientIds); links.push(...(r.data || [])); }
  if (proIds.length) { const r = await sb.from('client_links').select('id,pro_id,client_id,profile_id,client_name,professionals(name)').eq('status', 'active').in('pro_id', proIds); links.push(...(r.data || [])); }
  const linkIds = links.map((l) => l.id);
  let appts: any[] = [];
  if (linkIds.length) {
    const r = await sb.from('appointments').select('id,link_id,starts_at,minutes,kind').eq('status', 'planned')
      .gte('starts_at', new Date(nowMs).toISOString()).lte('starts_at', new Date(nowMs + 27 * 3600e3).toISOString()).in('link_id', linkIds);
    appts = r.data || [];
  }
  const needData = subs.some((s) => s.profile_id && s.rem && s.rem.on && (s.rem.weigh?.on || s.rem.water?.on || s.rem.meals?.on || s.rem.cons?.on));
  const profiles: Record<string, any> = {};
  if (needData && clientIds.length) {
    const r = await sb.from('plan_profiles').select('user_id,id,data').in('user_id', clientIds);
    (r.data || []).forEach((p) => { profiles[p.user_id + '|' + p.id] = p.data; });
  }

  let sent = 0, removed = 0;
  for (const s of subs) {
    let due: any[] = [];
    if (s.profile_id) {
      const l = links.find((x) => x.client_id === s.user_id && x.profile_id === s.profile_id);
      const mine = l ? appts.filter((a) => a.link_id === l.id) : [];
      const pr = l && l.professionals; const who = (Array.isArray(pr) ? pr[0] : pr)?.name || '';
      due = computeDue({ rem: s.rem, last_sent: s.last_sent, tz: s.tz }, profiles[s.user_id + '|' + s.profile_id], mine, who, nowMs);
    } else {
      const mineL = links.filter((x) => x.pro_id === s.user_id);
      const out: any[] = [];
      for (const l of mineL) {
        computeDue({ isPro: true, last_sent: s.last_sent, tz: s.tz }, null, appts.filter((a) => a.link_id === l.id), l.client_name || 'Cliente', nowMs).forEach((n) => out.push(n));
      }
      due = out;
    }
    if (!due.length) continue;
    const today = localParts(nowMs, s.tz).date, last = pruneLast(s.last_sent, today);
    let gone = false;
    for (const n of due) {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify({ title: n.title, body: n.body, tag: n.key, url: './' }), { TTL: 3600 });
        last[n.key] = today; sent++;
      } catch (e: any) {
        if (e && (e.statusCode === 404 || e.statusCode === 410)) { gone = true; break; }
      }
    }
    if (gone) { await sb.from('push_subs').delete().eq('id', s.id); removed++; }
    else await sb.from('push_subs').update({ last_sent: last }).eq('id', s.id);
  }
  return new Response(JSON.stringify({ subs: subs.length, sent, removed }), { headers: { 'Content-Type': 'application/json' } });
});
