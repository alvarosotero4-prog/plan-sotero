# Plan Sotero

App web (PWA) con plan de comidas y seguimiento de peso de 4 semanas.

- Perfiles: cada persona crea el suyo con un cuestionario (datos, objetivo, actividad, horario, dieta y alergias, salud). La app calcula calorías y macros (Mifflin-St Jeor + actividad), genera menús adaptados y un horario semanal. Cuentas con correo y contraseña (Supabase) que sincronizan los perfiles entre dispositivos; mientras `SB_URL` y `SB_KEY` estén vacías en index.html, la app funciona sin cuentas y guarda todo en el dispositivo. El plan original de Sotero sigue disponible como perfil.

Cinco pestañas: Hoy, Comidas, Progreso, Alimentos y Ajustes. Lo secundario va en desplegables que recuerdan si los dejaste abiertos.

- Hoy: kcal y macros del día, horario de comidas con casillas, peso, agua, pasos, creatina y sueño. Desplegables: cómo te encuentras (con aviso de fatiga), diario con etiquetas, constancia y la semana.
- Comidas: menú del plan, botón Cambiar plato (alternativas con kcal y proteína parecidas, respetando la dieta y las alergias), Repetir la última vez, favoritos y usados hace poco con tus gramos, botones +/− por unidad y copiar o vaciar el día.
- Progreso: peso con media semanal y recomendaciones, resumen semanal con informe para compartir (texto, copiar o guardar como PDF) y reparto de macros. Desplegables: medidas (cintura y pliegues) y fotos de progreso con comparación.
- Alimentos: comidas guardadas y alimentos propios.
- Ajustes: Plan (perfil, objetivos diarios, partidos de Sotero, peso de referencia y reglas) y Cuenta y datos (sesión, privacidad, descarga de datos, borrado de cuenta y copia de seguridad).

Los datos de entreno que se registraron antes (fuerza) se conservan en el dispositivo aunque ya no haya pestaña de entreno. Las fotos se guardan en IndexedDB, fuera de la copia de seguridad. En Cuenta > Tus datos puedes descargar y restaurar una copia.

## Modo nutricionista (B2B)

- Al crear cuenta se puede elegir "Soy nutricionista o dietista". Cada profesional recibe un código y un enlace (`?pro=CÓDIGO`) para invitar clientes.
- El cliente se vincula en Ajustes, Cuenta y datos, tras ver qué comparte (comidas, peso, medidas, seguimiento, notas del diario; las fotos no). Puede dejar de compartir cuando quiera.
- Panel del profesional: lista de clientes con alertas (sin registros, peso fuera de ritmo, fatiga, baja adherencia), ficha con informe semanal, gráfico de peso, medidas, diario de 7 días, objetivos (que quedan fijados para el cliente), nota para el cliente y notas privadas.
- Prueba gratuita: 3 clientes por profesional (se aplica en el servidor). Para activar un profesional de pago: `update professionals set status='active' where user_id = '…';`
- Backend: ejecutar `supabase/profesionales.sql` en el SQL Editor de Supabase (tablas, políticas RLS y funciones).
- Pendiente: cobro (Stripe) y revisión legal de las condiciones para profesionales (ahora son un borrador).
