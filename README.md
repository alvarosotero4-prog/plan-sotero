# Plan Sotero

App web (PWA) con plan de comidas, entreno y rutina de 4 semanas.

- Perfiles: cada persona crea el suyo con un cuestionario (datos, objetivo, actividad, horario, dieta y alergias, salud). La app calcula calorías y macros (Mifflin-St Jeor + actividad), genera menús adaptados y un horario semanal. Sin cuentas ni contraseñas: cada perfil vive en el dispositivo. El plan original de Sotero sigue disponible como perfil.

- Hoy: kcal y macros del día, peso, seguimiento de agua, pasos, cardio, creatina y sueño, diario con etiquetas, rachas y metas semanales, y rutina con casillas.
- Entreno: sensaciones del día (energía, cansancio, hambre) con aviso de fatiga, registro de fuerza (series, kg y repeticiones) y progresión por ejercicio.
- Comidas: menú del plan, alimentos con botones +/− por unidad, comidas guardadas, copiar un día y buscador de Mercadona (Open Food Facts) con escáner de código de barras.
- Progreso: resumen semanal con reparto de macros, peso con media semanal y recomendaciones, medidas (cintura y pliegues) con gráficos y fotos de progreso con comparación.
- Rutina: horario de cada día y de la semana, con el partido del domingo.
- Plan: objetivos, partidos, alimentos y comidas propias, y copia de seguridad.

Los datos se guardan solo en el dispositivo (localStorage); las fotos, en IndexedDB y fuera de la copia de seguridad. En Plan > Tus datos puedes descargar y restaurar una copia.
El escáner usa la API BarcodeDetector (Chrome en Android); en otros navegadores se puede escribir el código de barras en el buscador.
