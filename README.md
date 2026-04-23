# EBerry Admin Dashboard

Live admin dashboard for **EBerry Harvest Company LLC** — H-2A labor contractor payroll, workers, housing, and accounting.

## Live URL

https://cyndyhernandez76-hub.github.io/eberry-admin-dashboard/

## Stack

- **Frontend:** React 19 + TypeScript + Vite + Tailwind + shadcn/ui
- **Backend:** Supabase (Postgres 15 + RLS + Auth)
- **Schemas:** `hris`, `payroll`, `accounting`, `app`, `audit`
- **Schema version:** v2 (4,691 lines, 73 tables, 8 views, 44 RLS policies)

## Admin login

- Email: `cyndyhernandez76@gmail.com`
- Password: stored in your password manager

## Security

- RLS protects every table — only authenticated users with the `admin` role see data.
- The bundled anon key is designed to be public (that's how Supabase works). All access is gated by RLS server-side.
