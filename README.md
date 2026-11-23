# Comercial Nova

Sistema de gestión comercial para una tienda de tecnología: punto de venta y facturación con IVA 15%, inventario por categorías con alertas de stock, clientes con validación de cédula/RUC ecuatorianos, historial de ventas y acceso por roles (administrador y cajero).

**Ver en línea:** https://pgarces92001.github.io/comercial-nova/

Proyecto integrador · Lenguajes de Programación · Universidad Espíritu Santo (UEES)

## Base de datos

Los datos (usuarios, productos, clientes y ventas) están en una base de datos **Supabase (PostgreSQL)** compartida por todos los usuarios, con actualización en tiempo real.

- Cada factura se emite con la función `registrar_venta`, que descuenta el stock y crea la factura en una sola transacción. Si dos cajeros venden la última unidad al mismo tiempo, solo uno lo consigue.
- El script completo de la base de datos está en [`supabase/comercial-nova-supabase.sql`](supabase/comercial-nova-supabase.sql).
- Si la base de datos no responde, la página trabaja solo en el navegador (localStorage).

> Aplicación de demostración académica. Las facturas no tienen validez tributaria.
