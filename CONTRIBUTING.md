# Contribuir a Oryon

Abra un cambio acotado con motivo, contratos o módulos afectados y pruebas
reproducibles. No incluya claves, snapshots de cuentas ajenas ni información
de seguridad no coordinada. Para cambios económicos, documente unidades,
redondeos, estado inicial y final, y la relación con los parámetros del
mercado.

Antes de solicitar revisión:

```bash
bash scripts/ci.sh
```

El PR debe explicar el comportamiento esperado, aportar tests de flujos
normales y señalar cualquier cambio de interfaz o de evento. Los cambios de
parámetros o roles requieren además una evaluación operativa y un plan de
reversión. Reporte cuestiones de seguridad por la vía privada indicada en
[SECURITY.md](SECURITY.md).
