# Eco

Dictado por voz para macOS, de uso personal. Todo se procesa en el Mac: la voz se transcribe con WhisperKit y el texto se limpia con Apple Intelligence (Foundation Models).

## Qué hace (MVP)

- Dictar con un atajo de teclado y pegar el texto donde esté el cursor, en cualquier app.
- Limpiar el texto: puntuación, muletillas y retractaciones ("el martes, no, el miércoles").
- Diccionario personal con nombres y términos propios.
- Historial de dictados.
- Barra flotante que muestra cuando está escuchando.
- Grabar reuniones (micrófono + audio del Mac), con transcripción y resumen.

## Cómo se usa

- **Dictar:** mantén apretada la tecla Fn (o la que elijas en Ajustes), habla y suelta. El texto aparece donde está el cursor.
- **Dictado fijo:** aprieta Fn dos veces para hablar sin mantenerla. Otra vez Fn para terminar, o Esc para descartar.
- **Aprende de tus correcciones:** si después de dictar corriges una palabra mal transcrita, Eco la agrega sola al diccionario. Funciona en apps que dejan leer su texto (Notas, Mail, Mensajes); en algunas apps web o Electron no.
- **Reuniones:** en el menú de Eco, "Grabar reunión". Al terminar se transcribe y se resume solo; todo queda en "Reuniones…".
- **Diccionario:** en Ajustes → Diccionario, agrega nombres y cómo suelen salir mal (por ejemplo "Gurubik" → "Guruvic").
- **Historial:** en el menú, "Historial de dictados…".

Los datos quedan en `~/Library/Application Support/Eco` (modelo de voz, diccionario, historial y audios de reuniones).

## Requisitos

- Mac con Apple Silicon y macOS 26 o superior.
- Apple Intelligence activado en Ajustes del Sistema.

## Cómo compilar e instalar

No hace falta Xcode ni cuenta de Apple Developer, basta con las herramientas de línea de comandos de Apple (Swift 6).

```bash
./scripts/build.sh --install
```

Compila la app, la firma con un certificado local y la deja en `~/Applications/Eco.app`. La primera compilación tarda unos minutos porque descarga las dependencias.

El certificado local (`Eco Local Signing`) se crea solo la primera vez, en un llavero propio (`~/Library/Keychains/eco-signing.keychain-db`). Gracias a él macOS reconoce la app como la misma en cada compilación y no vuelve a pedir los permisos.

## Pruebas por línea de comandos

```bash
build/Eco.app/Contents/MacOS/Eco --transcribe audio.wav es      # transcribe y limpia un audio
build/Eco.app/Contents/MacOS/Eco --clean "eh hola o sea mañana"  # prueba solo la limpieza
ECO_DATA_DIR=/tmp/eco-prueba build/Eco.app/Contents/MacOS/Eco --test-meeting yo.wav otros.wav
```

## Permisos

- **Micrófono:** para escuchar lo que dictas.
- **Accesibilidad:** para detectar el atajo y pegar el texto en cualquier app.
- **Audio del sistema:** solo para grabar reuniones, se pide la primera vez que grabas una.
