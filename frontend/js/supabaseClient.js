// One shared client, used by every HTML page.
// Relies on SUPABASE_URL and SUPABASE_ANON_KEY from config.js,
// which must be loaded BEFORE this script in the HTML file.
const isPlaceholderConfig =
  !SUPABASE_URL ||
  !SUPABASE_ANON_KEY ||
  SUPABASE_URL.includes("YOUR-PROJECT-ID") ||
  SUPABASE_ANON_KEY.includes("YOUR-ANON-PUBLIC-KEY");

const supabaseClient = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

if (isPlaceholderConfig) {
  console.warn(
    "Supabase is not connected yet. Replace the placeholder values in frontend/js/config.js with your real project URL and anon key."
  );
}
