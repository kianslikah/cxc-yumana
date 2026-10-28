// Función del servidor: avisos de vales al teléfono (app Personal, personal.html).
// Usa la llave de servicio (solo existe en el servidor de Supabase, nunca en la app).
//   accion "clave":  devuelve la clave pública con la que el teléfono se suscribe a los avisos.
//   accion "vale":   avisa un vale recién anotado ("Bassma le dio $10 a Javier") a los admin que activaron
//                    los avisos, menos a quien lo anotó. Cada vale se avisa una sola vez (emp_movimientos.aviso_en).
//   accion "prueba": manda un aviso de prueba a los teléfonos de quien llama.
// Solo entra un admin activo de usuarios_app.
// Las claves VAPID se generan aquí la primera vez y se guardan en emp_push_claves (tabla cerrada a la API):
// la clave privada nunca pasa por el repo, que es público.
import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";
import * as webpush from "jsr:@negrel/webpush@0.5.0";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const responder = (cuerpo: unknown, status = 200) =>
  new Response(JSON.stringify(cuerpo), { status, headers: { ...cors, "Content-Type": "application/json" } });

function llaveServicio(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  try {
    return JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}").default ?? "";
  } catch {
    return "";
  }
}

// El servidor de avisos se arma una vez por instancia
let servidor: webpush.ApplicationServer | null = null;
let clavePublica = "";
async function prepararServidor(admin: SupabaseClient) {
  if (servidor) return;
  let { data, error } = await admin.from("emp_push_claves").select("vapid, publica").eq("id", 1).maybeSingle();
  if (error) throw error;
  if (!data) {
    const nuevas = await webpush.generateVapidKeys({ extractable: true });
    const fila = { id: 1, vapid: await webpush.exportVapidKeys(nuevas), publica: await webpush.exportApplicationServerKey(nuevas) };
    const ins = await admin.from("emp_push_claves").insert(fila);
    // Si otra instancia las creó al mismo tiempo, se usan las que quedaron guardadas
    const r = await admin.from("emp_push_claves").select("vapid, publica").eq("id", 1).single();
    if (r.error) throw ins.error ?? r.error;
    data = r.data;
  }
  servidor = await webpush.ApplicationServer.new({
    contactInformation: "https://app.mercantilyumana.com",
    vapidKeys: await webpush.importVapidKeys(data.vapid),
  });
  clavePublica = data.publica;
}

type Suscripcion = { id: number; usuario_id: string; endpoint: string; p256dh: string; auth: string };

// Teléfonos de admin activos (quien deja de ser admin deja de recibir avisos)
async function suscripciones(admin: SupabaseClient, filtro: { solo?: string; excepto?: string | null }) {
  const { data: admins, error: e1 } = await admin.from("usuarios_app").select("id").eq("rol", "admin").eq("activo", true);
  if (e1) throw e1;
  const ids = new Set((admins ?? []).map((u) => u.id as string));
  const { data, error } = await admin.from("emp_push_suscripciones")
    .select("id, usuario_id, endpoint, p256dh, auth").is("deleted_at", null);
  if (error) throw error;
  return ((data ?? []) as Suscripcion[]).filter((s) =>
    ids.has(s.usuario_id) && (!filtro.solo || s.usuario_id === filtro.solo) &&
    (!filtro.excepto || s.usuario_id !== filtro.excepto)
  );
}

async function enviar(admin: SupabaseClient, subs: Suscripcion[], aviso: Record<string, string>) {
  let enviados = 0;
  const fallos: string[] = [];
  await Promise.all(subs.map(async (s) => {
    try {
      await servidor!.subscribe({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } })
        .pushTextMessage(JSON.stringify(aviso), { urgency: webpush.Urgency.High, ttl: 86400 });
      enviados++;
      await admin.from("emp_push_suscripciones").update({ ultimo_ok: new Date().toISOString() }).eq("id", s.id);
    } catch (e) {
      const estado = (e as { response?: Response }).response?.status;
      fallos.push(String(estado ?? (e as Error).message ?? e));
      // 404/410: el teléfono ya no tiene esa suscripción (se borró la app o se apagaron los avisos)
      if (estado === 404 || estado === 410) {
        await admin.from("emp_push_suscripciones").update({ deleted_at: new Date().toISOString() }).eq("id", s.id);
      }
    }
  }));
  return { enviados, fallos };
}

const primerNombre = (n: string | null) => String(n ?? "").trim().split(/\s+/)[0] || "Alguien";
const dinero = (n: number) => "$" + (Number.isInteger(n) ? String(n) : n.toFixed(2));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return responder({ error: "Método no permitido" }, 405);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, llaveServicio(), {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Solo un admin activo
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: quien, error: eAuth } = await admin.auth.getUser(token);
  if (eAuth || !quien?.user) return responder({ error: "Sesión no válida. Vuelve a entrar." }, 401);
  const { data: yo } = await admin.from("usuarios_app").select("id, rol, activo").eq("id", quien.user.id).maybeSingle();
  if (!yo || !yo.activo || yo.rol !== "admin") return responder({ error: "Solo un administrador recibe avisos." }, 403);

  let b: Record<string, unknown>;
  try {
    b = await req.json();
  } catch {
    return responder({ error: "Datos no válidos" }, 400);
  }

  try {
    await prepararServidor(admin);
    const accion = String(b.accion ?? "");

    if (accion === "clave") return responder({ publica: clavePublica });

    if (accion === "prueba") {
      const subs = await suscripciones(admin, { solo: yo.id });
      if (!subs.length) return responder({ error: "Este usuario no tiene teléfonos con avisos activos." }, 400);
      return responder(await enviar(admin, subs, {
        title: "Avisos activos",
        body: "Aquí te llega cada vale que se anote en Personal.",
        url: "personal.html",
        tag: "prueba",
      }));
    }

    if (accion === "vale") {
      const id = Number(b.movimiento_id);
      if (!Number.isInteger(id) || id <= 0) return responder({ error: "Vale no válido" }, 400);
      // Se marca como avisado ANTES de mandar, de forma atómica: si la app reintenta, no llega dos veces.
      // Solo vales vivos y recientes (15 minutos): esto no sirve para mandar avisos viejos.
      const { data: mov, error } = await admin.from("emp_movimientos")
        .update({ aviso_en: new Date().toISOString() })
        .eq("id", id).eq("tipo", "vale").is("aviso_en", null).is("deleted_at", null)
        .gte("creado_en", new Date(Date.now() - 15 * 60 * 1000).toISOString())
        .select("id, empleado_id, monto, nota, registrado_por, registrado_nombre").maybeSingle();
      if (error) throw error;
      if (!mov) return responder({ enviados: 0, motivo: "Ya se avisó o no es un vale reciente." });

      const { data: emp } = await admin.from("emp_empleados").select("nombre").eq("id", mov.empleado_id).single();
      const { data: cuentas } = await admin.rpc("emp_cuentas");
      const lleva = Number((cuentas ?? []).find((c: { empleado_id: number }) => c.empleado_id === mov.empleado_id)?.vales_pend ?? 0);
      const monto = Number(mov.monto);
      const nombre = emp?.nombre ?? "un empleado";
      let cuerpo = `${primerNombre(mov.registrado_nombre)} le dio ${dinero(monto)} a ${nombre}`;
      if (mov.nota) cuerpo += ` (${mov.nota})`;
      cuerpo += `. Lleva ${dinero(Math.round(lleva * 100) / 100)} en vales sin descontar.`;

      const subs = await suscripciones(admin, { excepto: mov.registrado_por });
      return responder(await enviar(admin, subs, {
        title: `Vale de ${dinero(monto)}`,
        body: cuerpo,
        url: `personal.html#cuenta-${mov.empleado_id}`,
        tag: `vale-${mov.id}`,
      }));
    }

    return responder({ error: "Acción no válida" }, 400);
  } catch (e) {
    return responder({ error: (e as Error).message ?? String(e) }, 500);
  }
});
