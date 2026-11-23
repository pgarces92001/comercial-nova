-- ============================================================
-- Comercial Nova · base de datos compartida (Supabase / PostgreSQL)
-- Ejecutar completo en: Supabase → SQL Editor → New query → Run
-- ============================================================

create table if not exists productos (
  codigo    text primary key,
  nombre    text not null,
  categoria text not null,
  precio    numeric(10,2) not null check (precio > 0),
  stock     integer not null check (stock >= 0),
  minimo    integer not null default 0 check (minimo >= 0)
);

create table if not exists clientes (
  id       text primary key,
  nombre   text not null,
  telefono text not null default '',
  fija     boolean not null default false
);

create table if not exists usuarios (
  usuario text primary key,
  nombre  text not null,
  rol     text not null check (rol in ('admin','cajero')),
  hash    text not null,
  fijo    boolean not null default false
);

create table if not exists ventas (
  numero   text primary key,
  fecha    timestamptz not null default now(),
  cliente  jsonb not null,
  items    jsonb not null,
  subtotal numeric(12,2) not null,
  iva      numeric(12,2) not null,
  total    numeric(12,2) not null,
  pago     text not null,
  vendedor text not null
);

-- Secuencial único de facturas (001-001-000000NNN), compartido por todos los cajeros
create sequence if not exists factura_seq;

-- ------------------------------------------------------------
-- registrar_venta: descuenta el stock y crea la factura en UNA
-- transacción. "for update" bloquea cada producto mientras se
-- vende, así dos cajeros no pueden vender la misma unidad.
-- ------------------------------------------------------------
create or replace function registrar_venta(p_cliente jsonb, p_items jsonb, p_pago text, p_vendedor text)
returns ventas
language plpgsql
security definer
set search_path = public
as $$
declare
  it        jsonb;
  prod      productos;
  cant      integer;
  sub       numeric := 0;
  items_out jsonb := '[]'::jsonb;
  v_iva     numeric;
  v_total   numeric;
  v         ventas;
begin
  if jsonb_array_length(p_items) = 0 then
    raise exception 'FACTURA_VACIA';
  end if;

  for it in select value from jsonb_array_elements(p_items) order by value->>'codigo' loop
    cant := (it->>'cant')::integer;
    select * into prod from productos where codigo = it->>'codigo' for update;
    if not found then
      raise exception 'PRODUCTO_NO_EXISTE|%', it->>'codigo';
    end if;
    if cant < 1 or prod.stock < cant then
      raise exception 'STOCK_INSUFICIENTE|%|%', prod.nombre, prod.stock;
    end if;
    update productos set stock = stock - cant where codigo = prod.codigo;
    sub := sub + prod.precio * cant;
    items_out := items_out || jsonb_build_object('codigo', prod.codigo, 'nombre', prod.nombre, 'precio', prod.precio, 'cant', cant);
  end loop;

  sub     := round(sub, 2);
  v_iva   := round(sub * 0.15, 2);
  v_total := sub + v_iva;

  if p_cliente->>'id' = '9999999999999' and v_total > 50 then
    raise exception 'CONSUMIDOR_FINAL_50';
  end if;

  insert into ventas (numero, cliente, items, subtotal, iva, total, pago, vendedor)
  values ('001-001-' || lpad(nextval('factura_seq')::text, 9, '0'), p_cliente, items_out, sub, v_iva, v_total, p_pago, p_vendedor)
  returning * into v;
  return v;
end;
$$;

-- ------------------------------------------------------------
-- Acceso desde la página web (clave pública "anon").
-- Proyecto académico: cualquiera con la página puede leer y escribir.
-- ------------------------------------------------------------
alter table productos enable row level security;
alter table clientes  enable row level security;
alter table usuarios  enable row level security;
alter table ventas    enable row level security;

drop policy if exists acceso_app on productos;
drop policy if exists acceso_app on clientes;
drop policy if exists acceso_app on usuarios;
drop policy if exists acceso_app on ventas;
create policy acceso_app on productos for all to anon, authenticated using (true) with check (true);
create policy acceso_app on clientes  for all to anon, authenticated using (true) with check (true);
create policy acceso_app on usuarios  for all to anon, authenticated using (true) with check (true);
create policy acceso_app on ventas    for select to anon, authenticated using (true);
-- Las ventas solo se crean con registrar_venta (no se pueden editar ni borrar desde la página)

grant execute on function registrar_venta(jsonb, jsonb, text, text) to anon, authenticated;
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on productos, clientes, usuarios to anon, authenticated;
grant select on ventas to anon, authenticated;
revoke insert, update, delete on ventas from anon, authenticated;

-- Tiempo real: avisar a todas las pantallas abiertas cuando algo cambia
do $$
begin
  begin alter publication supabase_realtime add table productos; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table clientes;  exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table usuarios;  exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table ventas;    exception when duplicate_object then null; end;
end $$;

-- ------------------------------------------------------------
-- Datos iniciales (solo se insertan si no existen)
-- ------------------------------------------------------------
insert into usuarios (usuario, nombre, rol, hash, fijo) values
  ('pgarces', 'Paul Garcés', 'admin', '38ddfdc8c43e2900197e5968f31c5f8913f226e7c555d10c8172832cfb119845', true),
  ('cajero', 'Caja 1', 'cajero', '6e369cc7f76eafc62cd4c4adb5ddb4cd672e6d63c5063a78859bb7d35cccbb35', false)
on conflict (usuario) do nothing;

insert into productos (codigo, nombre, categoria, precio, stock, minimo) values
  ('P001', 'MacBook Air 13" M5 16 GB / 512 GB', 'Laptops', 1099, 3, 2),
  ('P002', 'Lenovo IdeaPad Slim 5 14" Core Ultra 7', 'Laptops', 849, 5, 3),
  ('P003', 'ASUS TUF Gaming A15 RTX 5060', 'Laptops', 1199, 2, 2),
  ('P004', 'iPhone 18 Pro 256 GB', 'Celulares', 1299, 3, 3),
  ('P005', 'iPhone 17 256 GB', 'Celulares', 799, 6, 3),
  ('P006', 'Samsung Galaxy S26 Ultra 256 GB', 'Celulares', 1299, 4, 2),
  ('P007', 'Samsung Galaxy A57 5G 128 GB', 'Celulares', 549, 10, 4),
  ('P008', 'Xiaomi Redmi Note 15 Pro 256 GB', 'Celulares', 329, 0, 5),
  ('P009', 'Apple AirPods Pro 3', 'Audio', 249, 8, 4),
  ('P010', 'Audífonos Sony WH-1000XM6', 'Audio', 449, 3, 3),
  ('P011', 'Nintendo Switch 2', 'Consolas', 449, 4, 3),
  ('P012', 'PlayStation 5 Pro', 'Consolas', 749, 2, 2),
  ('P013', 'Monitor Samsung Odyssey G5 27" QHD 180 Hz', 'Monitores', 279, 7, 3),
  ('P014', 'Mouse Logitech MX Master 4', 'Accesorios', 119.9, 12, 5),
  ('P015', 'Cargador Anker Nano 65 W USB-C', 'Accesorios', 45.9, 25, 10),
  ('P016', 'SSD Samsung 990 EVO Plus 1 TB', 'Almacenamiento', 89.9, 18, 8),
  ('P017', 'Router TP-Link Deco BE25 Wi-Fi 7 (2 u.)', 'Redes', 199, 4, 3),
  ('P018', 'Tablet Samsung Galaxy Tab S10 FE', 'Tablets', 499, 5, 3)
on conflict (codigo) do nothing;

insert into clientes (id, nombre, telefono, fija) values
  ('9999999999999', 'Consumidor final', '', true),
  ('0912345675', 'María Fernanda Andrade', '0991234567', false),
  ('1710034065', 'Carlos Mendoza Vera', '0987654321', false),
  ('0990012345001', 'Distribuidora El Puerto S.A.', '042345678', false)
on conflict (id) do nothing;

-- Ventas de ejemplo de los últimos 7 días
insert into ventas (numero, fecha, cliente, items, subtotal, iva, total, pago, vendedor) values
  ('001-001-000000121', '2026-11-17T14:00:00.000Z', '{"id":"0912345675","nombre":"María Fernanda Andrade"}'::jsonb, '[{"codigo":"P007","nombre":"Samsung Galaxy A57 5G 128 GB","precio":549,"cant":1},{"codigo":"P017","nombre":"Router TP-Link Deco BE25 Wi-Fi 7 (2 u.)","precio":199,"cant":1}]'::jsonb, 748, 112.2, 860.2, 'Efectivo', 'cajero'),
  ('001-001-000000122', '2026-11-17T16:17:00.000Z', '{"id":"1710034065","nombre":"Carlos Mendoza Vera"}'::jsonb, '[{"codigo":"P010","nombre":"Audífonos Sony WH-1000XM6","precio":449,"cant":1},{"codigo":"P006","nombre":"Samsung Galaxy S26 Ultra 256 GB","precio":1299,"cant":1}]'::jsonb, 1748, 262.2, 2010.2, 'Tarjeta', 'cajero'),
  ('001-001-000000123', '2026-11-18T14:00:00.000Z', '{"id":"0990012345001","nombre":"Distribuidora El Puerto S.A."}'::jsonb, '[{"codigo":"P006","nombre":"Samsung Galaxy S26 Ultra 256 GB","precio":1299,"cant":1},{"codigo":"P012","nombre":"PlayStation 5 Pro","precio":749,"cant":1}]'::jsonb, 2048, 307.2, 2355.2, 'Transferencia', 'cajero'),
  ('001-001-000000124', '2026-11-18T16:17:00.000Z', '{"id":"0912345675","nombre":"María Fernanda Andrade"}'::jsonb, '[{"codigo":"P009","nombre":"Apple AirPods Pro 3","precio":249,"cant":1},{"codigo":"P001","nombre":"MacBook Air 13\" M5 16 GB / 512 GB","precio":1099,"cant":1}]'::jsonb, 1348, 202.2, 1550.2, 'Efectivo', 'cajero'),
  ('001-001-000000125', '2026-11-18T18:34:00.000Z', '{"id":"1710034065","nombre":"Carlos Mendoza Vera"}'::jsonb, '[{"codigo":"P012","nombre":"PlayStation 5 Pro","precio":749,"cant":1}]'::jsonb, 749, 112.35, 861.35, 'Tarjeta', 'cajero'),
  ('001-001-000000126', '2026-11-18T20:51:00.000Z', '{"id":"0990012345001","nombre":"Distribuidora El Puerto S.A."}'::jsonb, '[{"codigo":"P015","nombre":"Cargador Anker Nano 65 W USB-C","precio":45.9,"cant":3}]'::jsonb, 137.7, 20.65, 158.35, 'Transferencia', 'cajero'),
  ('001-001-000000127', '2026-11-19T14:00:00.000Z', '{"id":"1710034065","nombre":"Carlos Mendoza Vera"}'::jsonb, '[{"codigo":"P005","nombre":"iPhone 17 256 GB","precio":799,"cant":1},{"codigo":"P007","nombre":"Samsung Galaxy A57 5G 128 GB","precio":549,"cant":1}]'::jsonb, 1348, 202.2, 1550.2, 'Tarjeta', 'cajero'),
  ('001-001-000000128', '2026-11-19T16:17:00.000Z', '{"id":"0990012345001","nombre":"Distribuidora El Puerto S.A."}'::jsonb, '[{"codigo":"P014","nombre":"Mouse Logitech MX Master 4","precio":119.9,"cant":1}]'::jsonb, 119.9, 17.99, 137.89, 'Transferencia', 'cajero'),
  ('001-001-000000129', '2026-11-19T18:34:00.000Z', '{"id":"0912345675","nombre":"María Fernanda Andrade"}'::jsonb, '[{"codigo":"P011","nombre":"Nintendo Switch 2","precio":449,"cant":1},{"codigo":"P003","nombre":"ASUS TUF Gaming A15 RTX 5060","precio":1199,"cant":1}]'::jsonb, 1648, 247.2, 1895.2, 'Efectivo', 'cajero'),
  ('001-001-000000130', '2026-11-20T14:00:00.000Z', '{"id":"0912345675","nombre":"María Fernanda Andrade"}'::jsonb, '[{"codigo":"P004","nombre":"iPhone 18 Pro 256 GB","precio":1299,"cant":1},{"codigo":"P002","nombre":"Lenovo IdeaPad Slim 5 14\" Core Ultra 7","precio":849,"cant":1}]'::jsonb, 2148, 322.2, 2470.2, 'Efectivo', 'cajero'),
  ('001-001-000000131', '2026-11-20T16:17:00.000Z', '{"id":"1710034065","nombre":"Carlos Mendoza Vera"}'::jsonb, '[{"codigo":"P007","nombre":"Samsung Galaxy A57 5G 128 GB","precio":549,"cant":1},{"codigo":"P009","nombre":"Apple AirPods Pro 3","precio":249,"cant":1}]'::jsonb, 798, 119.7, 917.7, 'Tarjeta', 'cajero'),
  ('001-001-000000132', '2026-11-21T14:00:00.000Z', '{"id":"0990012345001","nombre":"Distribuidora El Puerto S.A."}'::jsonb, '[{"codigo":"P003","nombre":"ASUS TUF Gaming A15 RTX 5060","precio":1199,"cant":1},{"codigo":"P015","nombre":"Cargador Anker Nano 65 W USB-C","precio":45.9,"cant":1}]'::jsonb, 1244.9, 186.74, 1431.64, 'Transferencia', 'cajero'),
  ('001-001-000000133', '2026-11-21T16:17:00.000Z', '{"id":"0912345675","nombre":"María Fernanda Andrade"}'::jsonb, '[{"codigo":"P006","nombre":"Samsung Galaxy S26 Ultra 256 GB","precio":1299,"cant":1},{"codigo":"P004","nombre":"iPhone 18 Pro 256 GB","precio":1299,"cant":1}]'::jsonb, 2598, 389.7, 2987.7, 'Efectivo', 'cajero'),
  ('001-001-000000134', '2026-11-21T18:34:00.000Z', '{"id":"1710034065","nombre":"Carlos Mendoza Vera"}'::jsonb, '[{"codigo":"P009","nombre":"Apple AirPods Pro 3","precio":249,"cant":1},{"codigo":"P011","nombre":"Nintendo Switch 2","precio":449,"cant":1}]'::jsonb, 698, 104.7, 802.7, 'Tarjeta', 'cajero'),
  ('001-001-000000135', '2026-11-21T20:51:00.000Z', '{"id":"0990012345001","nombre":"Distribuidora El Puerto S.A."}'::jsonb, '[{"codigo":"P012","nombre":"PlayStation 5 Pro","precio":749,"cant":1},{"codigo":"P018","nombre":"Tablet Samsung Galaxy Tab S10 FE","precio":499,"cant":1}]'::jsonb, 1248, 187.2, 1435.2, 'Transferencia', 'cajero'),
  ('001-001-000000136', '2026-11-22T14:00:00.000Z', '{"id":"1710034065","nombre":"Carlos Mendoza Vera"}'::jsonb, '[{"codigo":"P002","nombre":"Lenovo IdeaPad Slim 5 14\" Core Ultra 7","precio":849,"cant":1},{"codigo":"P010","nombre":"Audífonos Sony WH-1000XM6","precio":449,"cant":1}]'::jsonb, 1298, 194.7, 1492.7, 'Tarjeta', 'cajero'),
  ('001-001-000000137', '2026-11-22T16:17:00.000Z', '{"id":"0990012345001","nombre":"Distribuidora El Puerto S.A."}'::jsonb, '[{"codigo":"P005","nombre":"iPhone 17 256 GB","precio":799,"cant":1},{"codigo":"P017","nombre":"Router TP-Link Deco BE25 Wi-Fi 7 (2 u.)","precio":199,"cant":1}]'::jsonb, 998, 149.7, 1147.7, 'Transferencia', 'cajero'),
  ('001-001-000000138', '2026-11-22T18:34:00.000Z', '{"id":"0912345675","nombre":"María Fernanda Andrade"}'::jsonb, '[{"codigo":"P006","nombre":"Samsung Galaxy S26 Ultra 256 GB","precio":1299,"cant":1}]'::jsonb, 1299, 194.85, 1493.85, 'Efectivo', 'cajero'),
  ('001-001-000000139', '2026-11-23T14:00:00.000Z', '{"id":"0912345675","nombre":"María Fernanda Andrade"}'::jsonb, '[{"codigo":"P001","nombre":"MacBook Air 13\" M5 16 GB / 512 GB","precio":1099,"cant":1},{"codigo":"P005","nombre":"iPhone 17 256 GB","precio":799,"cant":1}]'::jsonb, 1898, 284.7, 2182.7, 'Efectivo', 'cajero'),
  ('001-001-000000140', '2026-11-23T16:17:00.000Z', '{"id":"1710034065","nombre":"Carlos Mendoza Vera"}'::jsonb, '[{"codigo":"P004","nombre":"iPhone 18 Pro 256 GB","precio":1299,"cant":1},{"codigo":"P012","nombre":"PlayStation 5 Pro","precio":749,"cant":1}]'::jsonb, 2048, 307.2, 2355.2, 'Tarjeta', 'cajero')
on conflict (numero) do nothing;

-- El secuencial continúa después de la última factura de ejemplo
select setval('factura_seq', greatest((select coalesce(max(substring(numero from 9)::bigint), 0) from ventas), 1));
