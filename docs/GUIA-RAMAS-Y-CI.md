# Guía de ramas, control de cambios e integración continua

Proyecto: **Alerta Ciudadana — Aplicación móvil (Flutter + Kotlin nativo)**
Repositorio: `RyujiItsuka/Seguridad-Panico` (fork mantenido por el equipo;
el repositorio original es `titinashe123/Seguridad-Panico`)

Esta guía describe cómo se aplica el procedimiento de control de cambios de la
Semana 11 en este repositorio. Es de cumplimiento obligatorio: el pipeline y la
protección de rama impiden que un cambio llegue a producción sin pasar por aquí.

---

## 1. Modelo de ramas

| Rama | Para qué sirve | ¿Admite push directo? |
|---|---|---|
| `main` | Versión estable / APK entregable. Solo recibe merges desde `develop`. | No (bloqueado) |
| `develop` | Integración continua del trabajo del sprint. | No (bloqueado) |
| `feature/<id>-<descripcion>` | Un cambio concreto (una historia o tarea). | Sí, es de trabajo |
| `hotfix/<id>-<descripcion>` | Corrección urgente que nace de `main`. | Sí, es de trabajo |

Regla de oro: **un cambio = una solicitud = una rama = un pull request**.
Ningún cambio se escribe directamente sobre `main` ni sobre `develop`.

Remotos del repositorio local:

| Remoto | URL | Uso |
|---|---|---|
| `origin` | `RyujiItsuka/Seguridad-Panico` | Repositorio de trabajo (aquí se abren los PR) |
| `upstream` | `titinashe123/Seguridad-Panico` | Repositorio original del equipo (solo lectura / sincronización) |

---

## 2. Flujo obligatorio

1. **Solicitud.** Se registra el cambio (plantilla de solicitud del plan) y se
   abre/usa el issue del sprint con su etiqueta de prioridad.
2. **Rama.** Se crea desde `develop`:
   `git checkout develop && git pull && git checkout -b feature/S6-xx-descripcion`
3. **Desarrollo.** Commits pequeños con la convención de la sección 5.
4. **Push de la rama.** `git push -u origin feature/S6-xx-descripcion`
5. **Pull request a `develop`.** El PR describe qué cambia, por qué, cómo se
   probó y cómo se revierte. El CI corre automáticamente.
6. **Revisión.** El PR se aprueba y se fusiona solo con el CI en verde.
7. **Integración a `main`.** Cuando `develop` está estable se abre un PR
   `develop` → `main` (requiere revisión) y se fusiona.
8. **Cierre.** Se cierra el issue, se compila el APK release de esa versión y se
   actualiza el manifiesto SHA-256 del paquete de entrega.

### Reversión

- Antes del merge: se cierra el PR (no deja rastro en `main`).
- Después del merge: `git revert <commit>` en una rama `hotfix/...` y PR a
  `main` y `develop`. Nunca se reescribe el historial (`--force`) en ramas
  protegidas.
- APK: se vuelve a compilar desde el commit anterior; el manifiesto SHA-256
  identifica sin ambigüedad el binario válido del entregable.

---

## 3. Protección de rama configurada

| Regla | `main` | `develop` |
|---|---|---|
| Cambios solo por pull request | Sí | Sí |
| Revisión obligatoria | 1 aprobación | No |
| Estado de CI obligatorio antes del merge | Sí (`Analizar y probar`) | Sí (`Analizar y probar`) |
| Push forzado | Bloqueado | Bloqueado |
| Borrado de la rama | Bloqueado | Bloqueado |
| Aplicable también a administradores | No (ver nota) | Sí |

**Nota sobre `main`:** el repositorio de trabajo tiene un único mantenedor con
permisos de administración. Si la regla se aplicara también al administrador,
ningún PR podría fusionarse (GitHub no permite aprobar el propio PR). Por eso en
`main` la exigencia de aprobación rige para todos los colaboradores, pero la
cuenta administradora conserva la capacidad de fusionar. En cuanto se incorpore
un segundo revisor con permisos, se activa la opción *"Do not allow bypassing
the above settings"* y la regla pasa a ser total.

**Nota sobre el repositorio original:** en `titinashe123/Seguridad-Panico` la
cuenta del equipo no tiene permisos de administración, por lo que la protección
de rama no se puede configurar allí. Por eso el flujo se aplica en el fork, y el
cambio se propone al original mediante pull request cuando corresponda.

---

## 4. Integración continua

Archivo: `.github/workflows/ci.yml`

| Elemento | Valor |
|---|---|
| Workflow | `CI` |
| Job | `Analizar y probar` |
| Se ejecuta en | `pull_request` y `push` a `main` y `develop` |
| Qué valida | `flutter pub get` + `flutter analyze` + `flutter test --exclude-tags e2e` |
| Efecto | Si falla, el PR queda bloqueado y no se puede fusionar |

Las pruebas etiquetadas `e2e` se excluyen a propósito: consultan la Edge Function
`reniec` por internet y dependen del entorno desplegado, así que se ejecutan a
mano antes de una entrega. No hay secretos en el repositorio; la clave del
proveedor de mensajería vive únicamente en el servidor (Edge Function), nunca en
el APK.

---

## 5. Convención de commits

```
tipo(alcance): descripción breve en imperativo

Cuerpo opcional: qué cambia y por qué.
Refs #<issue>
```

Tipos: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`.

---

## 6. Roles del proceso (CAB)

| Rol | Responsabilidad |
|---|---|
| Responsable del cambio (desarrollador) | Abre la solicitud, la rama y el PR; documenta pruebas y reversión |
| Responsable técnico del componente | Revisa el PR y aprueba el cambio |
| Responsable de operaciones / Central | Autoriza la ventana, verifica el servicio después del despliegue |

Para un cambio **urgente** (emergencia en producción) se permite la rama
`hotfix/...`, merge directo a `main` con el CI en verde y aprobación
retroactiva del CAB en la siguiente reunión.
