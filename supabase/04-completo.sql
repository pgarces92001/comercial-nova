-- ============================================================
-- Comercial Nova · Módulos de operación completa
--   · Costo de productos y margen de ganancia
--   · Descuentos (por producto y por factura) con límite por rol
--   · Pago mixto (efectivo + tarjeta + transferencia)
--   · Anulación de facturas con nota de crédito
--   · Compras a proveedores (entrada de mercadería)
--   · Kardex: historial de movimientos por producto
--   · Bitácora de auditoría
-- Ejecutar en: Supabase → SQL Editor → New query → Run
-- ============================================================

-- ---------- Columnas nuevas ----------
alter table productos add column if not exists costo          numeric(12,2) not null default 0;
alter table productos add column if not exists modificado_por text not null default '';
update productos set costo = round(precio * 0.72, 2) where costo = 0;

alter table clientes add column if not exists correo text not null default '';

alter table ventas add column if not exists pagos          jsonb not null default '[]'::jsonb;
alter table ventas add column if not exists descuento      numeric(12,2) not null default 0;
alter table ventas add column if not exists desc_pct       numeric(5,2) not null default 0;
alter table ventas add column if not exists anulada_motivo text not null default '';
alter table ventas add column if not exists anulada_por    text not null default '';
alter table ventas add column if not exists anulada_fecha  timestamptz;
alter table ventas add column if not exists nc_numero      text not null default '';

-- Facturas anteriores: un solo pago por el total, costo y descuento 0 en cada línea
update ventas set pagos = jsonb_build_array(jsonb_build_object('forma', pago, 'monto', total))
 where pagos = '[]'::jsonb;
update ventas v set items = (
  select jsonb_agg(i || jsonb_build_object(
           'costo', coalesce((select p.costo from productos p where p.codigo = i->>'codigo'), 0),
           'desc',  coalesce((i->>'desc')::numeric, 0)))
    from jsonb_array_elements(v.items) i)
 where not (v.items->0 ? 'costo');

-- ---------- Tablas nuevas ----------
create table if not exists movimientos (
  id        bigint generated always as identity primary key,
  fecha     timestamptz not null default now(),
  codigo    text not null,
  tipo      text not null,          -- Stock inicial · Venta · Compra · Anulación · Ajuste
  documento text not null default '',
  cantidad  integer not null,       -- positivo = entrada, negativo = salida
  saldo     integer not null,
  costo     numeric(12,2) not null default 0,
  usuario   text not null default '',
  detalle   text not null default ''
);
create index if not exists movimientos_codigo on movimientos (codigo, fecha);

create table if not exists compras (
  id                bigint generated always as identity primary key,
  numero            text unique not null,
  fecha             timestamptz not null default now(),
  proveedor         jsonb not null,
  factura_proveedor text not null default '',
  items             jsonb not null,
  total             numeric(12,2) not null,
  usuario           text not null
);

create table if not exists bitacora (
  id      bigint generated always as identity primary key,
  fecha   timestamptz not null default now(),
  usuario text not null,
  accion  text not null,
  detalle text not null default ''
);

create sequence if not exists nc_seq;
create sequence if not exists compra_seq;

-- ---------- Kardex inicial a partir de las ventas existentes ----------
do $$
begin
  if not exists (select 1 from movimientos) then
    with vi as (
      select v.numero, v.fecha, v.vendedor, i->>'codigo' as codigo, (i->>'cant')::int as cant
        from ventas v cross join jsonb_array_elements(v.items) i
    ), tot as (select codigo, sum(cant) as s from vi group by codigo)
    insert into movimientos (fecha, codigo, tipo, documento, cantidad, saldo, costo, usuario)
    select coalesce((select min(fecha) from ventas), now()) - interval '1 day',
           p.codigo, 'Stock inicial', 'Inventario inicial',
           p.stock + coalesce(t.s, 0), p.stock + coalesce(t.s, 0), p.costo, 'pgarces'
      from productos p left join tot t on t.codigo = p.codigo;

    with vi as (
      select v.numero, v.fecha, v.vendedor, i->>'codigo' as codigo, (i->>'cant')::int as cant
        from ventas v cross join jsonb_array_elements(v.items) i
    )
    insert into movimientos (fecha, codigo, tipo, documento, cantidad, saldo, costo, usuario)
    select vi.fecha, vi.codigo, 'Venta', vi.numero, -vi.cant,
           m.saldo - sum(vi.cant) over (partition by vi.codigo order by vi.fecha, vi.numero),
           p.costo, vi.vendedor
      from vi join productos p on p.codigo = vi.codigo
              join movimientos m on m.codigo = vi.codigo and m.tipo = 'Stock inicial';
  end if;
end $$;

-- ---------- Kardex de cambios manuales en Inventario ----------
create or replace function tg_productos_kardex()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if coalesce(current_setting('cn.origen', true), '') = 'fn' then return new; end if;
  if tg_op = 'INSERT' then
    insert into movimientos (codigo, tipo, documento, cantidad, saldo, costo, usuario, detalle)
    values (new.codigo, 'Stock inicial', 'Alta de producto', new.stock, new.stock, new.costo, new.modificado_por, '');
  elsif new.stock <> old.stock then
    insert into movimientos (codigo, tipo, documento, cantidad, saldo, costo, usuario, detalle)
    values (new.codigo, 'Ajuste', 'Ajuste de inventario', new.stock - old.stock, new.stock, new.costo, new.modificado_por, '');
  end if;
  return new;
end $$;
drop trigger if exists productos_kardex on productos;
create trigger productos_kardex after insert or update on productos
  for each row execute function tg_productos_kardex();

-- ------------------------------------------------------------
-- emitir_factura: descuentos, pago mixto y kardex en UNA transacción
--   p_items: [{codigo, cant, desc}]  (desc = % de descuento de la línea)
--   p_pagos: [{forma, monto}]        (la suma debe ser igual al total)
--   p_desc:  % de descuento sobre toda la factura
-- Cajero: descuento máximo 10 %. Administrador: sin límite.
-- ------------------------------------------------------------
drop function if exists registrar_venta(jsonb, jsonb, text, text);

create or replace function emitir_factura(p_cliente jsonb, p_items jsonb, p_pagos jsonb, p_desc numeric, p_vendedor text)
returns ventas
language plpgsql
security definer
set search_path = public
as $$
declare
  it        jsonb;
  pg        jsonb;
  prod      productos;
  cant      integer;
  dsc       numeric;
  rol_v     text;
  bruto     numeric := 0;
  lineas    numeric := 0;
  linea     numeric;
  items_out jsonb := '[]'::jsonb;
  v_descg   numeric;
  v_sub     numeric;
  v_iva     numeric;
  v_total   numeric;
  v_pagado  numeric := 0;
  v_caja    bigint;
  v_num     text;
  v         ventas;
begin
  perform set_config('cn.origen', 'fn', true);
  select rol into rol_v from usuarios where usuario = p_vendedor;
  if rol_v is null then raise exception 'USUARIO_NO_EXISTE'; end if;
  if jsonb_array_length(p_items) = 0 then raise exception 'FACTURA_VACIA'; end if;

  select id into v_caja from cajas where usuario = p_vendedor and cierre is null;
  if v_caja is null then raise exception 'CAJA_CERRADA'; end if;

  p_desc := coalesce(p_desc, 0);
  if p_desc < 0 or p_desc > 100 then raise exception 'DESCUENTO_INVALIDO'; end if;
  if rol_v <> 'admin' and p_desc > 10 then raise exception 'DESCUENTO_NO_AUTORIZADO'; end if;

  for it in select value from jsonb_array_elements(p_items) order by value->>'codigo' loop
    cant := (it->>'cant')::integer;
    dsc  := coalesce((it->>'desc')::numeric, 0);
    if dsc < 0 or dsc > 100 then raise exception 'DESCUENTO_INVALIDO'; end if;
    if rol_v <> 'admin' and dsc > 10 then raise exception 'DESCUENTO_NO_AUTORIZADO'; end if;
    select * into prod from productos where codigo = it->>'codigo' for update;
    if not found then raise exception 'PRODUCTO_NO_EXISTE|%', it->>'codigo'; end if;
    if cant < 1 or prod.stock < cant then
      raise exception 'STOCK_INSUFICIENTE|%|%', prod.nombre, prod.stock;
    end if;
    update productos set stock = stock - cant where codigo = prod.codigo;
    linea  := round(prod.precio * cant * (1 - dsc / 100), 2);
    bruto  := bruto + prod.precio * cant;
    lineas := lineas + linea;
    items_out := items_out || jsonb_build_object('codigo', prod.codigo, 'nombre', prod.nombre, 'precio', prod.precio,
                   'cant', cant, 'desc', dsc, 'costo', prod.costo, 'saldo', prod.stock - cant);
  end loop;

  v_descg := round(lineas * p_desc / 100, 2);
  v_sub   := round(lineas - v_descg, 2);
  v_iva   := round(v_sub * 0.15, 2);
  v_total := v_sub + v_iva;

  if p_cliente->>'id' = '9999999999999' and v_total > 50 then raise exception 'CONSUMIDOR_FINAL_50'; end if;

  if jsonb_array_length(coalesce(p_pagos, '[]'::jsonb)) = 0 then raise exception 'PAGO_INCOMPLETO'; end if;
  for pg in select value from jsonb_array_elements(p_pagos) loop
    if pg->>'forma' not in ('Efectivo', 'Tarjeta', 'Transferencia') or (pg->>'monto')::numeric <= 0 then
      raise exception 'PAGO_INVALIDO';
    end if;
    v_pagado := v_pagado + (pg->>'monto')::numeric;
  end loop;
  if abs(v_pagado - v_total) > 0.01 then raise exception 'PAGO_INCOMPLETO|%|%', v_pagado, v_total; end if;

  v_num := '001-001-' || lpad(nextval('factura_seq')::text, 9, '0');

  insert into movimientos (codigo, tipo, documento, cantidad, saldo, costo, usuario)
  select i->>'codigo', 'Venta', v_num, -(i->>'cant')::int, (i->>'saldo')::int, (i->>'costo')::numeric, p_vendedor
    from jsonb_array_elements(items_out) i;

  insert into ventas (numero, cliente, items, subtotal, iva, total, pago, pagos, descuento, desc_pct, vendedor, caja_id)
  values (v_num, p_cliente, (select jsonb_agg(i - 'saldo') from jsonb_array_elements(items_out) i),
          v_sub, v_iva, v_total,
          case when jsonb_array_length(p_pagos) = 1 then p_pagos->0->>'forma' else 'Mixto' end,
          p_pagos, round(bruto - v_sub, 2), p_desc, p_vendedor, v_caja)
  returning * into v;
  return v;
end;
$$;

-- ------------------------------------------------------------
-- anular_factura: solo administrador. Devuelve el stock,
-- registra el kardex y genera la nota de crédito.
-- ------------------------------------------------------------
create or replace function anular_factura(p_numero text, p_motivo text, p_usuario text)
returns ventas
language plpgsql
security definer
set search_path = public
as $$
declare v ventas; it jsonb; nuevo integer; v_nc text;
begin
  perform set_config('cn.origen', 'fn', true);
  if not exists (select 1 from usuarios where usuario = p_usuario and rol = 'admin') then
    raise exception 'NO_AUTORIZADO';
  end if;
  if length(trim(coalesce(p_motivo, ''))) < 5 then raise exception 'MOTIVO_REQUERIDO'; end if;
  select * into v from ventas where numero = p_numero for update;
  if not found then raise exception 'FACTURA_NO_EXISTE'; end if;
  if v.estado = 'Anulada' then raise exception 'YA_ANULADA'; end if;

  v_nc := '001-001-' || lpad(nextval('nc_seq')::text, 9, '0');
  for it in select value from jsonb_array_elements(v.items) loop
    update productos set stock = stock + (it->>'cant')::int where codigo = it->>'codigo' returning stock into nuevo;
    if nuevo is not null then
      insert into movimientos (codigo, tipo, documento, cantidad, saldo, costo, usuario, detalle)
      values (it->>'codigo', 'Anulación', 'NC ' || v_nc, (it->>'cant')::int, nuevo,
              coalesce((it->>'costo')::numeric, 0), p_usuario, 'Anula factura ' || p_numero);
    end if;
  end loop;

  update ventas set estado = 'Anulada', anulada_motivo = trim(p_motivo), anulada_por = p_usuario,
                    anulada_fecha = now(), nc_numero = v_nc
   where numero = p_numero returning * into v;
  insert into bitacora (usuario, accion, detalle)
  values (p_usuario, 'Anuló factura', p_numero || ' · NC ' || v_nc || ' · ' || trim(p_motivo));
  return v;
end;
$$;

-- ------------------------------------------------------------
-- registrar_compra: solo administrador. Suma stock, actualiza
-- el costo promedio ponderado y registra el kardex.
--   p_items: [{codigo, cant, costo}]
-- ------------------------------------------------------------
create or replace function registrar_compra(p_proveedor jsonb, p_factura text, p_items jsonb, p_usuario text)
returns compras
language plpgsql
security definer
set search_path = public
as $$
declare it jsonb; prod productos; cant integer; cu numeric; total numeric := 0;
        items_out jsonb := '[]'::jsonb; v_num text; c compras;
begin
  perform set_config('cn.origen', 'fn', true);
  if not exists (select 1 from usuarios where usuario = p_usuario and rol = 'admin') then
    raise exception 'NO_AUTORIZADO';
  end if;
  if coalesce(trim(p_proveedor->>'nombre'), '') = '' then raise exception 'PROVEEDOR_REQUERIDO'; end if;
  if jsonb_array_length(coalesce(p_items, '[]'::jsonb)) = 0 then raise exception 'COMPRA_VACIA'; end if;

  v_num := 'CMP-' || lpad(nextval('compra_seq')::text, 6, '0');
  for it in select value from jsonb_array_elements(p_items) order by value->>'codigo' loop
    cant := (it->>'cant')::integer;
    cu   := round((it->>'costo')::numeric, 2);
    if cant is null or cant < 1 or cu is null or cu < 0 then raise exception 'LINEA_INVALIDA'; end if;
    select * into prod from productos where codigo = it->>'codigo' for update;
    if not found then raise exception 'PRODUCTO_NO_EXISTE|%', it->>'codigo'; end if;
    update productos set
      stock = stock + cant,
      costo = case when prod.stock + cant > 0 then round((prod.stock * prod.costo + cant * cu) / (prod.stock + cant), 2) else cu end
     where codigo = prod.codigo;
    insert into movimientos (codigo, tipo, documento, cantidad, saldo, costo, usuario, detalle)
    values (prod.codigo, 'Compra', v_num, cant, prod.stock + cant, cu, p_usuario,
            coalesce(p_proveedor->>'nombre', '') || case when coalesce(p_factura, '') <> '' then ' · Fact. ' || p_factura else '' end);
    total := total + cant * cu;
    items_out := items_out || jsonb_build_object('codigo', prod.codigo, 'nombre', prod.nombre, 'cant', cant, 'costo', cu);
  end loop;

  insert into compras (numero, proveedor, factura_proveedor, items, total, usuario)
  values (v_num, p_proveedor, coalesce(p_factura, ''), items_out, round(total, 2), p_usuario)
  returning * into c;
  insert into bitacora (usuario, accion, detalle)
  values (p_usuario, 'Registró compra', v_num || ' · ' || (p_proveedor->>'nombre') || ' · $' || round(total, 2));
  return c;
end;
$$;

-- ------------------------------------------------------------
-- cerrar_caja: ahora suma los pagos mixtos y no cuenta anuladas
-- ------------------------------------------------------------
create or replace function cerrar_caja(p_usuario text, p_contado numeric, p_obs text)
returns cajas
language plpgsql
security definer
set search_path = public
as $$
declare c cajas; n integer; tot numeric; ef numeric; tj numeric; tr numeric;
begin
  if p_contado is null or p_contado < 0 then raise exception 'MONTO_INVALIDO'; end if;
  select * into c from cajas where usuario = p_usuario and cierre is null for update;
  if not found then raise exception 'CAJA_NO_ABIERTA'; end if;

  select count(*), coalesce(sum(total), 0) into n, tot
    from ventas where caja_id = c.id and estado <> 'Anulada';
  select coalesce(sum((p->>'monto')::numeric) filter (where p->>'forma' = 'Efectivo'), 0),
         coalesce(sum((p->>'monto')::numeric) filter (where p->>'forma' = 'Tarjeta'), 0),
         coalesce(sum((p->>'monto')::numeric) filter (where p->>'forma' = 'Transferencia'), 0)
    into ef, tj, tr
    from ventas v cross join jsonb_array_elements(v.pagos) p
   where v.caja_id = c.id and v.estado <> 'Anulada';

  update cajas set
    cierre = now(), num_facturas = n, ventas_total = tot, efectivo = ef, tarjeta = tj, transferencia = tr,
    efectivo_esperado = c.monto_inicial + ef, efectivo_contado = round(p_contado, 2),
    diferencia = round(p_contado, 2) - (c.monto_inicial + ef), observacion = coalesce(p_obs, '')
  where id = c.id returning * into c;
  insert into bitacora (usuario, accion, detalle)
  values (p_usuario, 'Cerró caja', 'Caja ' || c.id || ' · ventas $' || tot || ' · diferencia $' || c.diferencia);
  return c;
end;
$$;

-- procesar_sri: una factura anulada antes de autorizarse ya no se envía
create or replace function procesar_sri(p_numero text)
returns ventas
language plpgsql
security definer
set search_path = public
as $$
declare v ventas; ident text;
begin
  select * into v from ventas where numero = p_numero for update;
  if not found then raise exception 'FACTURA_NO_EXISTE'; end if;
  if v.sri_estado = 'Autorizada' then raise exception 'YA_AUTORIZADA'; end if;
  if v.estado = 'Anulada' then raise exception 'FACTURA_ANULADA'; end if;

  if v.sri_estado in ('Pendiente', 'Devuelta') then
    ident := v.cliente->>'id';
    if ident !~ '^[0-9]{10}([0-9]{3})?$' then
      update ventas set sri_estado = 'Devuelta', sri_mensaje = 'IDENTIFICACIÓN DEL COMPRADOR NO VÁLIDA'
       where numero = p_numero returning * into v;
    elsif v.total <= 0 or jsonb_array_length(v.items) = 0 then
      update ventas set sri_estado = 'Devuelta', sri_mensaje = 'COMPROBANTE SIN DETALLE O CON VALOR CERO'
       where numero = p_numero returning * into v;
    else
      update ventas set sri_estado = 'Recibida', sri_mensaje = ''
       where numero = p_numero returning * into v;
    end if;
  elsif v.sri_estado = 'Recibida' then
    update ventas set sri_estado = 'Autorizada', sri_fecha = now(), sri_mensaje = ''
     where numero = p_numero returning * into v;
  end if;
  return v;
end;
$$;

-- ---------- Permisos ----------
alter table movimientos enable row level security;
alter table compras     enable row level security;
alter table bitacora    enable row level security;
drop policy if exists acceso_app on movimientos;
drop policy if exists acceso_app on compras;
drop policy if exists leer_app on bitacora;
drop policy if exists escribir_app on bitacora;
create policy acceso_app on movimientos for select to anon, authenticated using (true);
create policy acceso_app on compras     for select to anon, authenticated using (true);
create policy leer_app     on bitacora  for select to anon, authenticated using (true);
create policy escribir_app on bitacora  for insert to anon, authenticated with check (true);
grant select on movimientos, compras to anon, authenticated;
grant select, insert on bitacora to anon, authenticated;
revoke insert, update, delete on movimientos, compras from anon, authenticated;
revoke update, delete on bitacora from anon, authenticated;
grant execute on function emitir_factura(jsonb, jsonb, jsonb, numeric, text) to anon, authenticated;
grant execute on function anular_factura(text, text, text) to anon, authenticated;
grant execute on function registrar_compra(jsonb, text, jsonb, text) to anon, authenticated;

do $$
begin
  begin alter publication supabase_realtime add table movimientos; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table compras;     exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table bitacora;    exception when duplicate_object then null; end;
end $$;
