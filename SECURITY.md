# Politica de seguridad

Oryon mantiene un proceso coordinado para revisar hallazgos sobre contratos,
tests y herramientas de este repositorio.

## Alcance

Estan dentro del alcance:

- contratos en `src/`;
- contabilidad de supply, deuda, reservas e indices;
- controles de colateral, health factor y liquidacion;
- oraculo local, curvas de tipos y limites por activo;
- scripts de compilacion, tests y CI.

Quedan fuera del alcance credenciales locales, cambios no mantenidos por el
repositorio, redes o despliegues de terceros y dependencias modificadas fuera
del lock de entorno.

## Invariantes esperadas

- Los caps por activo limitan nuevas entradas de supply y borrow.
- La deuda individual evoluciona con el indice de borrow del mercado.
- Los repagos reducen deuda y aumentan cash del activo repagado.
- Las retiradas preservan solvencia de la cuenta.
- Una liquidacion solo procede cuando la cuenta esta bajo el umbral configurado.
- Los precios usados para riesgo deben estar activos y no vencidos.
- Los indices se actualizan antes de rutas que modifican deuda.

## Reporte privado

Incluya:

- commit o version revisada;
- componente afectado;
- precondiciones;
- comportamiento esperado y observado;
- impacto economico estimado;
- pasos minimos para reproducir;
- trazas, tests o transacciones locales.

No publique detalles tecnicos en issues publicas antes de coordinar la respuesta
con los mantenedores.

## Validacion local

```bash
python scripts/compile_contracts.py
python scripts/check_loc.py
python -m pytest -q
```

La CI ejecuta los mismos pasos sobre cada push y pull request.
