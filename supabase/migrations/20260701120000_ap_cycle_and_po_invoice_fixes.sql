-- Run manually after review
-- =============================================================================
-- AP Cycle SOP + PO->Invoice fixes
-- Project: opdwtijyropzoyeseoij (eBerry Harvest Co. LLC tenant)
--
-- Adds, WITHOUT duplicating existing primitives:
--   1. accounting.v_ap_report            -- weekly payables snapshot view
--   2. public.admin_get_ap_report(...)   -- filtered wrapper for UI table + export
--   3. accounting.payment_import_runs    -- audit log of Jona's imported payment reports
--   4. public.admin_import_bill_payments(p_rows jsonb)
--                                        -- batch importer, wraps record_bill_payment
--                                           row-by-row with per-row try/catch
--
-- Reuses (does NOT redefine): record_bill_payment, admin_convert_po_to_bill,
-- admin_create_pass_through_invoice(_multi), admin_list_bills_v2,
-- accounting.bills, accounting.bill_payments, accounting.vendors,
-- accounting.bank_accounts, payroll.payment_method enum.
--
-- Idempotent where practical (CREATE OR REPLACE / IF NOT EXISTS).
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. accounting.v_ap_report
--    One row per open/partial/overdue/draft bill with a positive balance.
--    Columns map directly to Jackie's weekly AP Report (per SOP screenshot).
-- -----------------------------------------------------------------------------
create or replace view accounting.v_ap_report as
select
  b.bill_id,
  coalesce(v.dba_name, v.legal_name)          as vendor_name,
  coalesce(b.bill_number, b.internal_ref)      as invoice_number,
  b.bill_date                                  as invoice_date,
  b.due_date,
  b.amount_due,
  coalesce(b.description, b.notes)             as description_of_expense,
  b.notes                                      as management_notes,
  b.status,
  b.total_amount,
  b.amount_paid,
  v.vendor_id,
  b.farm_id,
  b.gl_account_code,
  b.dispute_notes,
  case
    when b.due_date is null                     then null
    when b.due_date < current_date              then 'past_due'
    when b.due_date <= current_date + 7         then 'due_this_week'
    else 'upcoming'
  end                                          as due_bucket
from accounting.bills b
left join accounting.vendors v on v.vendor_id = b.vendor_id
where b.amount_due > 0
  and b.status in ('open', 'partial', 'overdue', 'draft');

comment on view accounting.v_ap_report is
  'Weekly Accounts Payable snapshot for the AP Report SOP. One row per unpaid bill (open/partial/overdue/draft) with amount_due > 0.';

grant select on accounting.v_ap_report to anon, authenticated;

-- -----------------------------------------------------------------------------
-- 2. public.admin_get_ap_report(...)
--    Filtered wrapper over the view. Feeds both the UI table and the export.
--    p_status = NULL means "all unpaid". Drafts are excluded unless
--    p_include_draft = true OR p_status is explicitly 'draft'.
-- -----------------------------------------------------------------------------
create or replace function public.admin_get_ap_report(
  p_due_before   date    default null,
  p_status       text    default null,   -- NULL = all unpaid
  p_farm_id      uuid    default null,
  p_vendor_id    uuid    default null,
  p_include_draft boolean default false
) returns setof accounting.v_ap_report
language sql
security definer
set search_path = public, accounting
as $$
  select *
  from accounting.v_ap_report
  where (p_due_before is null or due_date <= p_due_before)
    and (p_status is null or status::text = p_status)
    and (p_farm_id is null or farm_id = p_farm_id)
    and (p_vendor_id is null or vendor_id = p_vendor_id)
    and (p_include_draft or p_status = 'draft' or status::text <> 'draft')
  order by due_date nulls last, vendor_name, invoice_number;
$$;

comment on function public.admin_get_ap_report(date, text, uuid, uuid, boolean) is
  'Filtered AP report used by the /accounting/ap-report UI and its XLSX/CSV export.';

grant execute on function public.admin_get_ap_report(date, text, uuid, uuid, boolean)
  to authenticated;

-- -----------------------------------------------------------------------------
-- 3. accounting.payment_import_runs
--    Audit log of each imported payment report so Jackie can look back.
-- -----------------------------------------------------------------------------
create table if not exists accounting.payment_import_runs (
  run_id       uuid primary key default gen_random_uuid(),
  imported_at  timestamptz not null default now(),
  imported_by  uuid,
  filename     text,
  payload      jsonb not null,
  result       jsonb not null
);

comment on table accounting.payment_import_runs is
  'History of batch payment imports (Jona''s completed payment reports) with original payload and per-row result.';

alter table accounting.payment_import_runs enable row level security;

-- Authenticated app users (anon key + signed-in JWT) may read/insert history.
drop policy if exists payment_import_runs_select on accounting.payment_import_runs;
create policy payment_import_runs_select
  on accounting.payment_import_runs
  for select
  to authenticated
  using (true);

drop policy if exists payment_import_runs_insert on accounting.payment_import_runs;
create policy payment_import_runs_insert
  on accounting.payment_import_runs
  for insert
  to authenticated
  with check (true);

grant select, insert on accounting.payment_import_runs to authenticated;

-- -----------------------------------------------------------------------------
-- 4. public.admin_import_bill_payments(p_rows jsonb)
--    Batch import of Jona's completed payment report.
--    Wraps public.record_bill_payment row-by-row inside a per-row
--    BEGIN/EXCEPTION block so one bad row never aborts the whole batch.
--    Also records the run in accounting.payment_import_runs.
-- -----------------------------------------------------------------------------
create or replace function public.admin_import_bill_payments(
  p_rows    jsonb,
  p_filename text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, accounting, payroll
as $$
declare
  v_row          jsonb;
  v_idx          int := 0;
  v_bill_id      uuid;
  v_result       jsonb;
  v_results      jsonb := '[]'::jsonb;
  v_ok           int := 0;
  v_fail         int := 0;
  v_default_bank uuid;
  v_method       text;
  v_summary      jsonb;
begin
  -- Default bank account for non-cash payments when the row omits one.
  -- Prefer an account whose name looks like the operating account.
  select bank_account_id into v_default_bank
  from accounting.bank_accounts
  where is_active = true
  order by (account_name ilike '%operating%') desc, created_at
  limit 1;

  for v_row in
    select * from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb))
  loop
    v_idx := v_idx + 1;
    v_bill_id := null;

    begin
      v_method := lower(coalesce(nullif(trim(v_row->>'payment_method'), ''), 'check'));

      -- Match invoice_number against bill_number, then internal_ref.
      select bill_id into v_bill_id
      from accounting.bills
      where (bill_number = v_row->>'invoice_number'
             or internal_ref = v_row->>'invoice_number')
        and status in ('open', 'partial', 'overdue')
      order by created_at desc
      limit 1;

      if v_bill_id is null then
        v_fail := v_fail + 1;
        v_results := v_results || jsonb_build_object(
          'row',            v_idx,
          'invoice_number', v_row->>'invoice_number',
          'status',         'error',
          'error',          'no unpaid bill matches invoice_number'
        );
        continue;
      end if;

      -- Reuse the single-payment RPC as-is.
      v_result := public.record_bill_payment(
        jsonb_build_object(
          'bill_id',         v_bill_id,
          'payment_date',    v_row->>'date_paid',
          'amount',          v_row->>'amount_paid',
          'method',          v_method,
          'check_number',    v_row->>'check_number',
          'reference',       v_row->>'reference',
          'notes',           v_row->>'notes',
          'bank_account_id', case when v_method = 'cash'
                                  then null else v_default_bank end
        )
      );

      v_ok := v_ok + 1;
      v_results := v_results || jsonb_build_object(
        'row',            v_idx,
        'invoice_number', v_row->>'invoice_number',
        'status',         'ok',
        'bill_id',        v_bill_id,
        'new_status',     v_result->>'new_status',
        'new_amount_due', v_result->>'new_amount_due'
      );

    exception when others then
      v_fail := v_fail + 1;
      v_results := v_results || jsonb_build_object(
        'row',            v_idx,
        'invoice_number', v_row->>'invoice_number',
        'status',         'error',
        'error',          sqlerrm
      );
    end;
  end loop;

  v_summary := jsonb_build_object(
    'ok_count',   v_ok,
    'fail_count', v_fail,
    'total',      v_idx,
    'results',    v_results
  );

  -- Persist the run for later reconciliation lookups. Never let logging
  -- failure roll back the payments that already succeeded.
  begin
    insert into accounting.payment_import_runs (imported_by, filename, payload, result)
    values (auth.uid(), p_filename, coalesce(p_rows, '[]'::jsonb), v_summary)
    returning run_id into v_bill_id;  -- reuse var to capture run_id
    v_summary := v_summary || jsonb_build_object('run_id', v_bill_id);
  exception when others then
    v_summary := v_summary || jsonb_build_object('run_id', null,
                                                 'run_log_error', sqlerrm);
  end;

  return v_summary;
end;
$$;

comment on function public.admin_import_bill_payments(jsonb, text) is
  'Batch import of a completed payment report. Wraps record_bill_payment row-by-row with per-row exception handling; logs the run to accounting.payment_import_runs.';

grant execute on function public.admin_import_bill_payments(jsonb, text) to authenticated;

commit;
