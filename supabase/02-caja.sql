-- ============================================================
-- Comercial Nova · Apertura y cierre de caja
-- Ejecutar en: Supabase → SQL Editor → New query → Run
-- ============================================================

create table if not exists cajas (
  id                bigint generated always as identity primary key,
  usuario           text not null,
  apertura          timestamptz not null default now(),
  monto_inicial     numeric(12,2) not null check (monto_inicial >= 0),
  cierre            timestamptz,
  num_facturas      integer,
  ventas_total      numeric(12,2),
  efectivo          numeric(12,2),
  tarjeta           numeric(12,2),
  transferencia     numeric(12,2),
  efectivo_esperado numeric(12,2),
  efectivo_contado  numeric(12,2),
  diferencia        numeric(12,2),
  observacion       text not null default ''
);

-- Cada usuario puede tener solo UNA caja abierta a la vez
create unique index if not exists una_caja_abierta on cajas (usuario) where cierre is null;

-- Cada venta queda asociada a la caja en la que se cobró
alter table ventas add column if not exists caja_id bigint references cajas(id);

-- ------------------------------------------------------------
-- abrir_caja: registra el monto inicial (fondo de cambio)
-- ------------------------------------------------------------
create or replace function abrir_caja(p_usuario text, p_monto numeric)
returns cajas
language plpgsql
security definer
set search_path = public
as $$
declare c cajas;
begin
  if p_monto is null or p_monto < 0 then
    raise exception 'MONTO_INVALIDO';
  end if;
  if exists (select 1 from cajas where usuario = p_usuario and cierre is null) then
    raise exception 'CAJA_YA_ABIERTA';
  end if;
  insert into cajas (usuario, monto_inicial) values (p_usuario, round(p_monto, 2)) returning * into c;
  return c;
end;
$$;

-- ------------------------------------------------------------
-- cerrar_caja: suma las ventas de la caja por forma de pago,
-- calcula el efectivo esperado y la diferencia con lo contado
-- ------------------------------------------------------------
create or replace function cerrar_caja(p_usuario text, p_contado numeric, p_obs text)
returns cajas
language plpgsql
security definer
set search_path = public
as $$
declare
  c      cajas;
  n      integer;
  tot    numeric;
  ef     numeric;
  tj     numeric;
  tr     numeric;
begin
  if p_contado is null or p_contado < 0 then
    raise exception 'MONTO_INVALIDO';
  end if;
  select * into c from cajas where usuario = p_usuario and cierre is null for update;
  if not found then
    raise exception 'CAJA_NO_ABIERTA';
  end if;

  select count(*),
         coalesce(sum(total), 0),
         coalesce(sum(total) filter (where pago = 'Efectivo'), 0),
         coalesce(sum(total) filter (where pago = 'Tarjeta'), 0),
         coalesce(sum(total) filter (where pago = 'Transferencia'), 0)
    into n, tot, ef, tj, tr
    from ventas where caja_id = c.id;

  update cajas set
    cierre            = now(),
    num_facturas      = n,
    ventas_total      = tot,
    efectivo          = ef,
    tarjeta           = tj,
    transferencia     = tr,
    efectivo_esperado = c.monto_inicial + ef,
    efectivo_contado  = round(p_contado, 2),
    diferencia        = round(p_contado, 2) - (c.monto_inicial + ef),
    observacion       = coalesce(p_obs, '')
  where id = c.id
  returning * into c;
  return c;
end;
$$;

-- ------------------------------------------------------------
-- registrar_venta: ahora exige una caja abierta del vendedor
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
  v_caja    bigint;
  v         ventas;
begin
  if jsonb_array_length(p_items) = 0 then
    raise exception 'FACTURA_VACIA';
  end if;

  select id into v_caja from cajas where usuario = p_vendedor and cierre is null;
  if v_caja is null then
    raise exception 'CAJA_CERRADA';
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

  insert into ventas (numero, cliente, items, subtotal, iva, total, pago, vendedor, caja_id)
  values ('001-001-' || lpad(nextval('factura_seq')::text, 9, '0'), p_cliente, items_out, sub, v_iva, v_total, p_pago, p_vendedor, v_caja)
  returning * into v;
  return v;
end;
$$;

-- Permisos: la página solo lee cajas; abrir y cerrar se hace con las funciones
alter table cajas enable row level security;
drop policy if exists acceso_app on cajas;
create policy acceso_app on cajas for select to anon, authenticated using (true);
grant select on cajas to anon, authenticated;
revoke insert, update, delete on cajas from anon, authenticated;
grant execute on function abrir_caja(text, numeric) to anon, authenticated;
grant execute on function cerrar_caja(text, numeric, text) to anon, authenticated;
grant execute on function registrar_venta(jsonb, jsonb, text, text) to anon, authenticated;

-- Tiempo real para las cajas
do $$
begin
  begin alter publication supabase_realtime add table cajas; exception when duplicate_object then null; end;
end $$;
