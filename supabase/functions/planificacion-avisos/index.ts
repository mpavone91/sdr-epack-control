// ════════════════════════════════════════════════════════════════════
// SDR Hub · Avisos por email de la planificación
//
// La llama pg_cron cada minuto (ver migración 20261029_planificacion.sql).
// Pide a planificacion_avisos_claim() los avisos pendientes (ya quedan
// marcados como enviados) y los manda por email con Resend.
//
// Secretos de la función (Edge Functions → Secrets):
//   RESEND_API_KEY   clave de https://resend.com
//   AVISOS_FROM      remitente verificado, p. ej. "SDR Hub <avisos@epackpro.com>"
//   APP_URL          URL del SDR Hub, para el botón del email
// SUPABASE_URL y SUPABASE_SERVICE_ROLE_KEY los pone Supabase solo.
// ════════════════════════════════════════════════════════════════════

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") ?? "";
const FROM = Deno.env.get("AVISOS_FROM") ?? "SDR Hub <onboarding@resend.dev>";
const APP_URL = Deno.env.get("APP_URL") ?? "";

type Aviso = {
  tipo: "inicio" | "fin" | "urgente";
  bloque_id: number | null;
  plantilla_id: number | null;
  sdr_id: number;
  nombre: string;
  email: string;
  titulo: string;
  emoji: string | null;
  prioridad: string;
  fecha: string | null;
  hora_inicio: string | null;
  duracion_min: number;
  descripcion: string | null;
  fecha_limite: string | null;
  siguiente_titulo: string | null;
  siguiente_hora: string | null;
};

const esc = (s: string | null) =>
  (s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const hhmm = (t: string | null) => (t ?? "").slice(0, 5);
function horaFin(t: string | null, min: number) {
  const [h, m] = hhmm(t).split(":").map(Number);
  const tot = h * 60 + m + min;
  return `${String(Math.floor(tot / 60) % 24).padStart(2, "0")}:${String(tot % 60).padStart(2, "0")}`;
}
const durTxt = (min: number) =>
  min % 60 === 0 ? `${min / 60} h` : min > 60 ? `${Math.floor(min / 60)} h ${min % 60} min` : `${min} min`;

function plantillaEmail(titulo: string, cuerpo: string, color: string) {
  const boton = APP_URL
    ? `<p style="margin:24px 0 0;"><a href="${APP_URL}" style="background:#7FD81F;color:#1d3942;padding:12px 22px;border-radius:10px;font-weight:700;text-decoration:none;display:inline-block;">Abrir mi planificación</a></p>`
    : "";
  return `<div style="font-family:Inter,Arial,sans-serif;background:#f4f6f5;padding:24px;">
  <div style="max-width:520px;margin:0 auto;background:#fff;border-radius:16px;overflow:hidden;border:1px solid #e2e8e6;">
    <div style="background:${color};height:6px;"></div>
    <div style="padding:24px 28px;">
      <div style="font-size:12px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:#647574;">SDR Hub · Planificación</div>
      <h1 style="font-family:Georgia,serif;font-size:22px;color:#1d3942;margin:6px 0 14px;">${titulo}</h1>
      <div style="font-size:15px;line-height:1.6;color:#15201f;">${cuerpo}</div>
      ${boton}
    </div>
  </div>
</div>`;
}

function construir(a: Aviso): { subject: string; html: string } {
  const nombre = esc(a.nombre.split(" ")[0]);
  const bloque = `${a.emoji ? a.emoji + " " : ""}${esc(a.titulo)}`;
  if (a.tipo === "inicio") {
    return {
      subject: `▶ Empieza: ${a.emoji ?? ""} ${a.titulo} (${hhmm(a.hora_inicio)})`.replace(/\s+/g, " "),
      html: plantillaEmail(
        `Hora de empezar, ${nombre}`,
        `<p>Tu bloque <b>${bloque}</b> empieza ahora: <b>${hhmm(a.hora_inicio)} – ${horaFin(a.hora_inicio, a.duracion_min)}</b> (${durTxt(a.duracion_min)}).</p>
         <p>Entra en el SDR Hub y dale a <b>▶ Play</b> para arrancar el contador.</p>`,
        "#3b7dd8",
      ),
    };
  }
  if (a.tipo === "fin") {
    const sig = a.siguiente_titulo
      ? `<p>Lo siguiente: <b>${esc(a.siguiente_titulo)}</b> a las <b>${hhmm(a.siguiente_hora)}</b>.</p>`
      : `<p>No tienes más bloques planificados hoy.</p>`;
    return {
      subject: `✓ Bloque terminado: ${a.titulo} · 15 min de descanso`,
      html: plantillaEmail(
        `¡Bloque terminado, ${nombre}! 🎉`,
        `<p>Has completado <b>${bloque}</b> (${durTxt(a.duracion_min)}).</p>
         <p>Tómate <b>15 minutos de descanso</b> antes de lo siguiente: levántate, agua, estira.</p>${sig}
         <p style="font-size:13px;color:#647574;">Recuerda marcarlo como terminado en el Hub si aún no lo has hecho.</p>`,
        "#1fa856",
      ),
    };
  }
  const limite = a.fecha_limite ? `<p>Fecha límite: <b>${a.fecha_limite.split("-").reverse().join("/")}</b>.</p>` : "";
  const desc = a.descripcion ? `<p style="background:#fdf6e8;border-radius:10px;padding:10px 14px;">${esc(a.descripcion)}</p>` : "";
  return {
    subject: `🚨 Urgente: ${a.titulo} · planifícalo hoy`,
    html: plantillaEmail(
      `Nuevo bloque urgente, ${nombre}`,
      `<p>Tu manager ha creado el bloque <b>${bloque}</b> (${durTxt(a.duracion_min)}) con prioridad <b style="color:#e23d3d;">URGENTE</b>.</p>
       ${desc}${limite}
       <p>Entra en <b>Mi planificación</b> y arrástralo a tu calendario en el primer hueco que tengas.</p>`,
      "#e23d3d",
    ),
  };
}

async function enviar(to: string, subject: string, html: string) {
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to: [to], subject, html }),
  });
  if (!r.ok) throw new Error(`Resend ${r.status}: ${await r.text()}`);
}

Deno.serve(async (req) => {
  // Solo pg_cron (con la service_role) puede disparar los envíos
  if (req.headers.get("Authorization") !== `Bearer ${SERVICE_KEY}`) {
    return new Response("forbidden", { status: 403 });
  }
  if (!RESEND_API_KEY) return new Response("Falta RESEND_API_KEY", { status: 500 });

  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/planificacion_avisos_claim`, {
    method: "POST",
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
    },
    body: "{}",
  });
  if (!r.ok) return new Response(`claim ${r.status}: ${await r.text()}`, { status: 500 });
  const avisos: Aviso[] = await r.json();

  const resultados = await Promise.allSettled(
    avisos.map((a) => {
      const { subject, html } = construir(a);
      return enviar(a.email, subject, html);
    }),
  );
  const fallos = resultados.filter((x) => x.status === "rejected") as PromiseRejectedResult[];
  fallos.forEach((f) => console.error(f.reason));
  return Response.json({ enviados: avisos.length - fallos.length, fallos: fallos.length });
});
