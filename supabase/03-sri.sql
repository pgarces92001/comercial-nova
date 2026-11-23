-- ============================================================
-- Comercial Nova · Estado de facturas y autorización (SRI)
-- Ejecutar en: Supabase → SQL Editor → New query → Run
-- Simulación académica del flujo de facturación electrónica:
--   Pendiente de envío → Recibida por el SRI → Autorizada
--   (o Devuelta si el comprobante tiene errores)
-- ============================================================

alter table ventas add column if not exists estado      text not null default 'Emitida';
alter table ventas add column if not exists sri_estado  text not null default 'Pendiente';
alter table ventas add column if not exists sri_fecha   timestamptz;
alter table ventas add column if not exists sri_mensaje text not null default '';

-- Facturas de días anteriores: ya autorizadas (datos de ejemplo)
update ventas set sri_estado = 'Autorizada', sri_fecha = fecha + interval '2 minutes'
 where sri_estado = 'Pendiente' and fecha < date_trunc('day', now());

-- ------------------------------------------------------------
-- procesar_sri: avanza la factura un paso en el flujo del SRI
--   Pendiente / Devuelta → Recibida (o Devuelta si hay errores)
--   Recibida             → Autorizada
-- ------------------------------------------------------------
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

grant execute on function procesar_sri(text) to anon, authenticated;
