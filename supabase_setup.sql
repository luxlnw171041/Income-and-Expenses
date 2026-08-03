-- ============================================================
-- ตู้ซื่อสัตย์ (Honesty Shop) — Supabase Setup Script
-- รันสคริปต์นี้ทั้งหมดใน Supabase SQL Editor (Project > SQL Editor > New query)
-- ============================================================

-- ------------------------------------------------------------
-- 1) TABLES
-- ------------------------------------------------------------
create extension if not exists pgcrypto;

create table if not exists accounts (
    id uuid primary key default gen_random_uuid(),
    name text not null,
    type text check (type in ('business', 'personal')) not null,
    balance decimal(12,2) default 0.00,
    created_at timestamp with time zone default now()
);

create table if not exists transactions (
    id uuid primary key default gen_random_uuid(),
    account_id uuid references accounts(id) on delete cascade,
    type text check (type in ('income', 'expense')) not null,
    category text not null,
    amount decimal(12,2) not null,
    note text,
    created_at timestamp with time zone default now()
);

create table if not exists buildings (
    id uuid primary key default gen_random_uuid(),
    name text not null,
    created_at timestamp with time zone default now()
);

create table if not exists shelves (
    id uuid primary key default gen_random_uuid(),
    building_id uuid references buildings(id) on delete cascade,
    floor int not null,
    created_at timestamp with time zone default now()
);

create table if not exists products (
    id uuid primary key default gen_random_uuid(),
    name text not null,
    selling_price decimal(10,2) not null,
    min_stock_alert int default 5,
    image_url text,
    created_at timestamp with time zone default now()
);

create table if not exists product_shelves (
    id uuid primary key default gen_random_uuid(),
    shelf_id uuid references shelves(id) on delete cascade,
    product_id uuid references products(id) on delete cascade,
    quantity int not null default 0,
    updated_at timestamp with time zone default now(),
    unique(shelf_id, product_id)
);

create table if not exists stock_batches (
    id uuid primary key default gen_random_uuid(),
    product_id uuid references products(id) on delete cascade,
    cost_price decimal(10,2) not null,
    initial_qty int not null,
    remaining_qty int not null,
    created_at timestamp with time zone default now()
);

create table if not exists stock_adjustments (
    id uuid primary key default gen_random_uuid(),
    product_shelf_id uuid references product_shelves(id) on delete cascade,
    expected_qty int not null,
    actual_qty int not null,
    lost_qty int not null,
    loss_value decimal(10,2) default 0.00,
    created_at timestamp with time zone default now()
);

-- ------------------------------------------------------------
-- 2) STORED PROCEDURES
-- ------------------------------------------------------------

-- process_stock_audit: เปรียบเทียบจำนวนนับได้จริงกับระบบ, คำนวณส่วนสูญหาย,
-- อัปเดต product_shelves, บันทึก stock_adjustments และลงบัญชีรายจ่าย "สินค้าสูญหาย (Loss)"
-- ใช้ต้นทุนแบบ FIFO: ตัดจาก stock_batches ล็อตเก่าสุดที่ยังมี remaining_qty > 0 ก่อน
create or replace function process_stock_audit(
    p_product_shelf_id uuid,
    p_actual_qty int
) returns jsonb
language plpgsql
security definer
as $$
declare
    v_expected_qty int;
    v_product_id uuid;
    v_lost_qty int;
    v_loss_value decimal(10,2) := 0;
    v_remaining_to_deduct int;
    v_batch record;
    v_deduct int;
    v_business_account_id uuid;
    v_product_name text;
begin
    select ps.quantity, ps.product_id into v_expected_qty, v_product_id
    from product_shelves ps where ps.id = p_product_shelf_id
    for update;

    if not found then
        raise exception 'product_shelf % not found', p_product_shelf_id;
    end if;

    select name into v_product_name from products where id = v_product_id;

    v_lost_qty := greatest(0, v_expected_qty - p_actual_qty);
    v_remaining_to_deduct := v_lost_qty;

    -- ตัดต้นทุนแบบ FIFO จากล็อตที่เก่าที่สุดก่อน
    if v_lost_qty > 0 then
        for v_batch in
            select id, cost_price, remaining_qty from stock_batches
            where product_id = v_product_id and remaining_qty > 0
            order by created_at asc
            for update
        loop
            exit when v_remaining_to_deduct <= 0;
            v_deduct := least(v_batch.remaining_qty, v_remaining_to_deduct);
            update stock_batches set remaining_qty = remaining_qty - v_deduct where id = v_batch.id;
            v_loss_value := v_loss_value + (v_deduct * v_batch.cost_price);
            v_remaining_to_deduct := v_remaining_to_deduct - v_deduct;
        end loop;
    end if;

    update product_shelves
    set quantity = p_actual_qty, updated_at = now()
    where id = p_product_shelf_id;

    insert into stock_adjustments (product_shelf_id, expected_qty, actual_qty, lost_qty, loss_value)
    values (p_product_shelf_id, v_expected_qty, p_actual_qty, v_lost_qty, v_loss_value);

    if v_lost_qty > 0 and v_loss_value > 0 then
        select id into v_business_account_id from accounts where type = 'business' order by created_at asc limit 1;
        if v_business_account_id is not null then
            insert into transactions (account_id, type, category, amount, note)
            values (v_business_account_id, 'expense', 'สินค้าสูญหาย (Loss)', v_loss_value, v_product_name);

            update accounts set balance = balance - v_loss_value where id = v_business_account_id;
        end if;
    end if;

    return jsonb_build_object(
        'expected_qty', v_expected_qty,
        'actual_qty', p_actual_qty,
        'lost_qty', v_lost_qty,
        'loss_value', v_loss_value
    );
end;
$$;

-- add_transaction: บันทึกรายรับ/รายจ่าย พร้อมอัปเดตยอดคงเหลือของบัญชีแบบ atomic
create or replace function add_transaction(
    p_account_id uuid,
    p_type text,
    p_category text,
    p_amount decimal,
    p_note text default null
) returns jsonb
language plpgsql
security definer
as $$
declare
    v_tx_id uuid;
begin
    if p_type not in ('income', 'expense') then
        raise exception 'invalid type %', p_type;
    end if;

    insert into transactions (account_id, type, category, amount, note)
    values (p_account_id, p_type, p_category, p_amount, p_note)
    returning id into v_tx_id;

    update accounts
    set balance = balance + (case when p_type = 'income' then p_amount else -p_amount end)
    where id = p_account_id;

    return jsonb_build_object('id', v_tx_id, 'account_id', p_account_id, 'type', p_type, 'amount', p_amount);
end;
$$;

-- ------------------------------------------------------------
-- 3) VIEWS
-- ------------------------------------------------------------

create or replace view view_dashboard_overview as
select
    coalesce(sum(amount) filter (where type = 'income'), 0) as total_sales,
    coalesce(sum(amount) filter (where type = 'expense'), 0) as total_expenses,
    coalesce((select sum(loss_value) from stock_adjustments), 0) as total_loss_value,
    coalesce(sum(amount) filter (where type = 'income'), 0) - coalesce(sum(amount) filter (where type = 'expense'), 0) as net_profit
from transactions;

create or replace view view_building_performance as
select
    b.id as building_id,
    b.name as building_name,
    coalesce(sum(sa.loss_value), 0) as total_loss_value,
    count(distinct sa.id) as adjustment_count
from buildings b
left join shelves sh on sh.building_id = b.id
left join product_shelves ps on ps.shelf_id = sh.id
left join stock_adjustments sa on sa.product_shelf_id = ps.id
group by b.id, b.name;

create or replace view view_low_stock_alerts as
select
    p.name as product_name,
    ps.quantity,
    p.min_stock_alert,
    b.name as building,
    sh.floor
from product_shelves ps
join products p on p.id = ps.product_id
join shelves sh on sh.id = ps.shelf_id
join buildings b on b.id = sh.building_id
where ps.quantity <= p.min_stock_alert;

-- ------------------------------------------------------------
-- 4) ROW LEVEL SECURITY (ปรับตามความต้องการจริง)
-- ตัวอย่างนี้เปิดให้ authenticated user อ่าน/เขียนได้ทั้งหมด
-- แนะนำให้ปรับ policy ให้เข้มขึ้นถ้ามีผู้ใช้หลายคน/หลายร้าน
-- ------------------------------------------------------------
alter table accounts enable row level security;
alter table transactions enable row level security;
alter table buildings enable row level security;
alter table shelves enable row level security;
alter table products enable row level security;
alter table product_shelves enable row level security;
alter table stock_batches enable row level security;
alter table stock_adjustments enable row level security;

create policy "allow all for authenticated" on accounts for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "allow all for authenticated" on transactions for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "allow all for authenticated" on buildings for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "allow all for authenticated" on shelves for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "allow all for authenticated" on products for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "allow all for authenticated" on product_shelves for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "allow all for authenticated" on stock_batches for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');
create policy "allow all for authenticated" on stock_adjustments for all using (auth.role() = 'authenticated') with check (auth.role() = 'authenticated');

-- ถ้าต้องการให้ใช้งานได้แบบไม่ต้อง login (anon key อย่างเดียว) ให้ใช้ policy นี้แทนด้านบน:
-- create policy "allow all for anon" on <table_name> for all using (true) with check (true);
