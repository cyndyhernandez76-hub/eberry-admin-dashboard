import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.104.0';

// Public browser configuration only. Never place a service-role key here.
const cfg = window.__APP_CONFIG__ || {};
export const appRoot = new URL('../', import.meta.url);
export const appUrl = (path = '') => new URL(path, appRoot).href;
export const sb = createClient(
  cfg.SUPABASE_URL || 'https://opdwtijyropzoyeseoij.supabase.co',
  cfg.SUPABASE_ANON_KEY || 'sb_publishable_7nQMmXiQRYGzvmTJ6YZ4tQ_6u2XsVs9',
  {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: false,
      storageKey: 'eberry.auth',
    },
  },
);

// Preserve the current host/prefix, including non-GitHub preview deployments.
for (const el of document.querySelectorAll('[href^="/eberry-admin-dashboard/"]')) {
  el.setAttribute('href', appUrl(el.getAttribute('href').slice('/eberry-admin-dashboard/'.length)));
}

export async function requireSignIn() {
  let user;
  try {
    const result = await sb.auth.getUser();
    user = result.data?.user;
  } catch (_) {
    // A blocked storage adapter or an expired session must not start queries.
  }
  const pill = document.getElementById('auth-pill');
  if (pill) pill.textContent = user?.email || 'Not signed in';
  if (user) return true;
  document.querySelectorAll('button,input,select').forEach(el => { el.disabled = true; });
  const notice = document.createElement('div');
  notice.setAttribute('role', 'alert');
  notice.style.cssText = 'margin:20px;padding:20px;border:1px solid #b45309;border-radius:8px;background:#fffbeb;color:#78350f';
  notice.append('Sign in to the ERP Suite to use this page. ');
  const link = document.createElement('a');
  link.href = appUrl('#/login');
  link.textContent = 'Sign in';
  notice.append(link);
  document.body.prepend(notice);
  const rows = document.getElementById('rows');
  if (rows) rows.innerHTML = '<tr><td colspan="8" class="empty">Sign in required.</td></tr>';
  const content = document.getElementById('content');
  if (content) content.textContent = 'Sign in required.';
  return false;
}
