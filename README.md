# Plan Sotero

App web (PWA) para el plan de definición de 4 semanas.

- Hoy: kcal y macros del día, peso, seguimiento de agua, creatina y sueño, y rutina con casillas.
- Comidas: menú del plan, alimentos con botones +/− por unidad, comidas guardadas, copiar un día y buscador de Mercadona (Open Food Facts) con escáner de código de barras.
- Progreso: resumen semanal, peso con media semanal y recomendaciones, y medidas (cintura y pliegues) con gráficos.
- Rutina: horario de cada día y de la semana, con el partido del domingo.
- Plan: objetivos, partidos, alimentos y comidas propias, y copia de seguridad.

Los datos se guardan solo en el dispositivo (localStorage). En Plan > Tus datos puedes descargar y restaurar una copia.
El escáner usa la API BarcodeDetector (Chrome en Android); en otros navegadores se puede escribir el código de barras en el buscador.
