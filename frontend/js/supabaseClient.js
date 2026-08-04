// One shared client, used by every HTML page.
// Relies on SUPABASE_URL and SUPABASE_ANON_KEY from config.js,
// which must be loaded BEFORE this script in the HTML file.
const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
