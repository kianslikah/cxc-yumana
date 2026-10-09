// Conexión a la base de datos. Por ahora JABELLA vive dentro del proyecto Supabase de Mercantil Yumana,
// totalmente aislada (todo con prefijo jab_). La key "publishable" es pública por diseño:
// la seguridad real está en las reglas (RLS) de la base.
window.JAB_CONFIG = {
  url: 'https://tkkiuxaamdyfbildcvtp.supabase.co',
  key: 'sb_publishable_oOCXiFi1MaOChwvqiLNSdg_IVfega0X',
  dominio: 'jabella.app' // los usuarios entran con "usuario"; por dentro es usuario@jabella.app
};
