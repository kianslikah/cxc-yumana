// Función del servidor para manejar usuarios de JABELLA.
// Usa la llave de servicio (solo existe en el servidor de Supabase, nunca en la app).
//   accion "bootstrap": crea la primera dueña. Solo funciona si todavía no hay ningún usuario.
//   accion "crear":     la dueña crea un usuario (vendedora o dueña).
//   accion "clave":     la dueña le pone una clave nueva a un usuario.
import { createClient } from "jsr:@supabase/supabase-js@2";

const DOMINIO = "jabella.app"; // los usuarios entran con "usuario"; por dentro es usuario@jabella.app
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return responder({ error: "Método no permitido" }, 405);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, llaveServicio(), {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  let b: Record<string, unknown>;
  try {
    b = await req.json();
  } catch {
    return responder({ error: "Datos no válidos" }, 400);
  }
  const accion = String(b.accion ?? "");
  const usuario = String(b.usuario ?? "").trim().toLowerCase();
  const nombre = String(b.nombre ?? "").trim();
  const clave = String(b.clave ?? "");
  const rol = String(b.rol ?? "vendedora");

  const validarNuevo = (): string | null => {
    if (!/^[a-z0-9._-]{3,30}$/.test(usuario)) return "El usuario debe tener de 3 a 30 letras o números, sin espacios.";
    if (!nombre) return "Escribe el nombre.";
    if (clave.length < 6) return "La clave debe tener al menos 6 caracteres.";
    if (rol !== "duena" && rol !== "vendedora") return "Rol no válido.";
    return null;
  };

  const crear = async (rolFinal: string) => {
    const { data, error } = await admin.auth.admin.createUser({
      email: `${usuario}@${DOMINIO}`,
      password: clave,
      email_confirm: true,
      user_metadata: { nombre },
    });
    if (error || !data.user) {
      const msg = /already|registered|exists/i.test(error?.message ?? "") ? "Ese usuario ya existe." : (error?.message ?? "No se pudo crear");
      return responder({ error: msg }, 400);
    }
    const { error: e2 } = await admin.from("jab_usuarios").insert({
      id: data.user.id, usuario, nombre, rol: rolFinal, activo: true, debe_cambiar_clave: true,
    });
    if (e2) {
      await admin.auth.admin.deleteUser(data.user.id);
      return responder({ error: "No se pudo guardar el usuario: " + e2.message }, 400);
    }
    return responder({ ok: true, id: data.user.id });
  };

  // Primera dueña: solo si la tabla está vacía
  if (accion === "bootstrap") {
    const { count, error } = await admin.from("jab_usuarios").select("id", { count: "exact", head: true });
    if (error) return responder({ error: error.message }, 500);
    if ((count ?? 0) > 0) return responder({ error: "Ya hay usuarios creados." }, 403);
    const err = validarNuevo();
    if (err) return responder({ error: err }, 400);
    return await crear("duena");
  }

  // Todo lo demás: solo una dueña activa
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: quien, error: eAuth } = await admin.auth.getUser(token);
  if (eAuth || !quien?.user) return responder({ error: "Sesión no válida. Vuelve a entrar." }, 401);
  const { data: yo } = await admin.from("jab_usuarios").select("id, rol, activo").eq("id", quien.user.id).maybeSingle();
  if (!yo || !yo.activo || yo.rol !== "duena") return responder({ error: "Solo la dueña puede manejar usuarios." }, 403);

  if (accion === "crear") {
    const err = validarNuevo();
    if (err) return responder({ error: err }, 400);
    return await crear(rol);
  }

  if (accion === "clave") {
    const id = String(b.id ?? "");
    if (clave.length < 6) return responder({ error: "La clave debe tener al menos 6 caracteres." }, 400);
    const { data: destino } = await admin.from("jab_usuarios").select("id").eq("id", id).maybeSingle();
    if (!destino) return responder({ error: "Ese usuario no existe." }, 404);
    const { error } = await admin.auth.admin.updateUserById(id, { password: clave });
    if (error) return responder({ error: error.message }, 400);
    // Si la dueña le pone clave a otra persona, esa persona debe cambiarla al entrar
    await admin.from("jab_usuarios").update({ debe_cambiar_clave: id !== yo.id }).eq("id", id);
    return responder({ ok: true });
  }

  return responder({ error: "Acción no válida" }, 400);
});
