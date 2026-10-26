# Plan Sotero

App web (PWA) con plan de comidas y seguimiento de peso de 4 semanas.

- Perfiles: cada persona crea el suyo con un cuestionario (datos, objetivo, actividad, horario, dieta y alergias, salud). La app calcula calorías y macros (Mifflin-St Jeor + actividad), genera menús adaptados y un horario semanal. Cuentas con correo y contraseña (Supabase) que sincronizan los perfiles entre dispositivos; mientras `SB_URL` y `SB_KEY` estén vacías en index.html, la app funciona sin cuentas y guarda todo en el dispositivo. El plan original de Sotero sigue disponible como perfil.

- Hoy: kcal y macros del día, peso, seguimiento de agua, pasos, creatina y sueño, cómo te encuentras (energía, cansancio y hambre, con aviso de fatiga), diario con etiquetas, rachas y metas semanales, y horario de comidas con casillas.
- Comidas: menú del plan, botón Cambiar plato (alternativas con kcal y proteína parecidas, respetando la dieta y las alergias), Repetir la última vez, favoritos y usados hace poco con tus gramos, alimentos con botones +/− por unidad, copiar un día.
- Progreso: resumen semanal con informe para compartir (texto, copiar o guardar como PDF), con reparto de macros, peso con media semanal y recomendaciones, medidas (cintura y pliegues) con gráficos y fotos de progreso con comparación.
- Alimentos: comidas guardadas y alimentos propios.
- Plan: perfil, objetivos diarios, partidos (plan de Sotero), peso de referencia y reglas de ajuste.
- Cuenta: sesión, privacidad, descarga de datos, borrado de cuenta y copia de seguridad.

Los datos de entreno que se registraron antes (fuerza) se conservan en el dispositivo aunque ya no haya pestaña de entreno. Las fotos se guardan en IndexedDB, fuera de la copia de seguridad. En Cuenta > Tus datos puedes descargar y restaurar una copia.
