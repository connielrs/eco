# Arquitectura y decisiones técnicas

Eco es una app nativa en Swift que vive en la barra de menú. Es un paquete de Swift Package Manager con un solo ejecutable (`Sources/Eco`), sin proyecto de Xcode. La única dependencia externa es [WhisperKit](https://github.com/argmaxinc/WhisperKit), que corre el modelo de voz Whisper en Apple Silicon.

## Piezas principales

| Área | Archivos | Qué hace |
|---|---|---|
| App y menú | `main.swift`, `AppDelegate.swift` | Arranque, ícono y menú de la barra, ventanas |
| Ajustes | `Settings.swift`, `SettingsView.swift`, `Permissions.swift` | Preferencias guardadas en `UserDefaults`, permisos |
| Atajo de teclado | `HotkeyMonitor.swift` | Detecta Fn (u otra tecla) en cualquier app |
| Dictado | `DictationController.swift`, `AudioRecorder.swift` | Coordina grabar, transcribir, limpiar y pegar |
| Transcripción | `Transcriber.swift` | Descarga, carga y usa el modelo de voz |
| Limpieza | `TextCleaner.swift` | Puntuación, muletillas y correcciones con Apple Intelligence |
| Pegado | `TextInserter.swift` | Pega el texto donde está el cursor |
| Diccionario | `PersonalDictionary.swift`, `DictionaryView.swift`, `CorrectionLearner.swift` | Palabras propias, reemplazos y aprendizaje de correcciones |
| Interfaz | `FloatingBar.swift`, `History.swift`, `AppIcon.swift` | Barra flotante, historial, logo e ícono |
| Reuniones | `MeetingRecorder.swift`, `SystemAudioRecorder.swift`, `MeetingProcessor.swift`, `MeetingSummarizer.swift`, `Meetings.swift`, `MeetingsView.swift` | Grabación, transcripción, resumen y ventana de reuniones |
| Datos | `Paths.swift`, `JSONStore.swift` | Carpetas y archivos JSON en `Application Support/Eco` |
| Pruebas | `CommandLineTool.swift` | Modo sin interfaz para probar cada parte |

## Flujo de un dictado

```
Fn apretada ──► AudioRecorder graba el micrófono (16 kHz, mono)
                    │ niveles de voz ──► FloatingBar (onda)
Fn suelta   ──► Transcriber: el audio se divide en tramos y se transcribe con Whisper
                    │
                    ▼
            PersonalDictionary: reemplaza las variantes mal transcritas
                    │
                    ▼
            TextCleaner: limpia con Apple Intelligence solo si hace falta
                    │
                    ▼
            TextInserter: pega donde está el cursor y deja el portapapeles como estaba
                    │
                    ├──► DictationHistory: guarda el dictado y sus tiempos
                    └──► CorrectionLearner: vigila si se corrige alguna palabra
```

### Atajo de teclado

`HotkeyMonitor` usa un *event tap* de Core Graphics que recibe las teclas antes que el resto del sistema. Cuando el atajo es Fn, el evento de Fn se intercepta y no sigue hacia macOS; así no se abren los emojis ni cambia el idioma del teclado. Mientras no hay permiso de accesibilidad, se escucha el teclado sin interceptarlo y se reintenta cada pocos segundos.

El doble toque se resuelve en `DictationController`: un toque de menos de 0,3 s espera un segundo toque durante 0,4 s. Si llega, el dictado queda fijo; si no, se descarta. La grabación empieza con el primer toque, así que no se pierde nada de lo que se dice entre los dos.

### Grabación

`AudioRecorder` crea un `AVAudioEngine` nuevo en cada dictado, para tomar siempre el micrófono elegido en el sistema, y convierte el audio a 16 kHz mono, que es lo que espera Whisper. Si macOS cambia la configuración de audio a mitad del dictado (por ejemplo, al conectar audífonos), el motor se detiene: Eco escucha ese aviso y se reconecta sin perder lo grabado. Los últimos 5 dictados se guardan como WAV en `Grabaciones/` para poder revisar errores.

### Transcripción

- **Modelo:** Whisper large-v3 turbo, en dos variantes elegibles en Ajustes. *Rápido* es la versión comprimida (630 MB); *Preciso* es la versión completa (1,5 GB), que acierta más con palabras coloquiales y nombres, pero tarda el doble. Se descargan desde `argmaxinc/whisperkit-coreml` la primera vez.
- **Tramos propios:** el audio se divide en tramos de hasta 25 segundos, cortando en el momento más silencioso, y cada tramo se transcribe por separado con el detector de "sin voz" de Whisper desactivado. Con el detector activo, Whisper descartaba partes de dictados largos y pausados.
- **Sin vocabulario como pista:** WhisperKit permite pasar palabras como pista (`promptTokens`), pero con esta versión y este modelo la transcripción sale vacía. El diccionario se aplica después, con reemplazos.
- **Frases inventadas:** cuando el audio es casi silencio, Whisper a veces escribe frases como "Gracias por ver el video". Se descartan si son todo el resultado.

### Limpieza

`TextCleaner` usa el modelo de Apple Intelligence que corre en el Mac (Foundation Models). El modelo es chico y a veces cambia palabras o inventa, así que la limpieza está acotada:

1. **Solo cuando hace falta.** Si el texto no tiene muletillas, correcciones habladas, palabras repetidas ni tramos largos sin puntuación, se pega tal cual, con un formato mínimo. Esto evita esperar a la IA en la mayoría de los dictados.
2. **Por partes.** Los textos largos se limpian en partes de unas 40 palabras, porque con textos largos el modelo casi no puntúa.
3. **Sin palabras nuevas.** Si la IA agrega una palabra que no se dijo, o borra palabras con contenido sin que haya una corrección hablada, no se usa su texto: se toma solo su puntuación (comas, puntos, signos y comillas) y se aplica sobre las palabras originales.
4. **Ajustes finales.** El punto y coma pasa a coma, un punto seguido de minúscula pasa a coma, y las palabras comunes que Whisper escribe con mayúscula en medio de una frase pasan a minúscula.
5. **Diccionario acotado.** A la IA solo se le pasan las palabras del diccionario que ya aparecen en el texto. Con la lista completa, el modelo la usaba para rellenar pausas.

Si Apple Intelligence no está disponible, se pega la transcripción con el formato mínimo.

### Pegado

`TextInserter` guarda lo que había en el portapapeles, copia el texto marcado como temporal (para que los gestores de portapapeles no lo guarden), simula ⌘V y, medio segundo después, deja el portapapeles como estaba. Antes de pegar lee con Accesibilidad el carácter anterior al cursor: si es una letra o un punto, agrega un espacio para que los dictados seguidos no queden pegados.

### Aprendizaje de correcciones

Después de pegar, `CorrectionLearner` recuerda el campo de texto y lo vuelve a leer al cambiar de app, al empezar otro dictado o cada 15 segundos, durante 3 minutos. Si encuentra un solo cambio chico y parecido (por ejemplo "Cubernetes" → "Kubernetes"), lo agrega al diccionario. No aprende cambios de tildes ni de mayúsculas, que dependen del contexto, ni cambios de estilo entre palabras reales ("cositas" → "cosas"). Sí aprende si la palabra original no existe en español ni en inglés, o si la corrección es un nombre propio en medio de la frase. Solo funciona en apps que dejan leer su texto con Accesibilidad.

## Flujo de una reunión

```
Grabar reunión ──► MicrophoneFileRecorder: tu micrófono ──► microfono.caf
               └─► SystemAudioRecorder: audio del Mac (process tap de Core Audio) ──► sistema.caf
Terminar       ──► MeetingProcessor
                     ├─ transcribe cada archivo con su propio modelo cargado
                     ├─ junta las dos pistas en orden ("Tú" y "Otros")
                     ├─ descarta lo que el micrófono captó desde los parlantes
                     └─ MeetingSummarizer: resumen, acuerdos, tareas y título
```

- **Audio del Mac sin bot:** `SystemAudioRecorder` crea un *process tap* de Core Audio sobre la mezcla de salida del sistema y un dispositivo agregado privado para leerlo. Pide el permiso de "audio del sistema" (`NSAudioCaptureUsageDescription`).
- **Micrófono sin motor de audio:** el micrófono de las reuniones se graba con `AVAudioRecorder`. `AVAudioEngine` (con o sin cancelación de eco) abre también la salida de los parlantes, y eso deja en silencio la captura del audio del Mac.
- **Eco de los parlantes:** sin cancelación de eco, el micrófono capta lo que suena por los parlantes. Si una línea del micrófono se parece mucho a una de "Otros" en el mismo momento, se descarta.
- **Silencio inventado:** Whisper a veces escribe "Gracias." en cada tramo de silencio; las frases cortas repetidas tres o más veces seguidas se quitan. Si el audio del Mac quedó en silencio, la reunión avisa y ofrece abrir el permiso de audio del sistema.
- **Formato:** AAC mono a 16 kHz dentro de CAF, unos 15 MB por hora, y el archivo sigue siendo legible si la app se cierra de golpe. Al abrir Eco se retoman las reuniones que quedaron a medio procesar.
- **Transcripción por tramos:** cada pista se transcribe con los mismos tramos propios de los dictados, con tiempos por frase. Si un tramo con sonido sale vacío (le pasa a Whisper en el modo con tiempos), se reintenta sin tiempos.
- **Quién habló:** una línea del micrófono se descarta si la mayoría de sus palabras aparecen en lo que sonó en el Mac en ese momento (es eco), y también un "Gracias." suelto mientras sonaba el Mac. El resumen sabe que "Otros" puede ser un video y que un "yo" dentro de la transcripción no es "Tú".
- **Instancia aparte del modelo:** las reuniones usan otra copia del modelo de voz, para que procesar una reunión larga no bloquee los dictados. Esa copia se libera al terminar.
- **Resumen por partes:** el modelo de Apple tiene una ventana de contexto chica, así que las reuniones largas se resumen en partes de unos 5.000 caracteres y después se juntan las notas.

## Datos

Todo se guarda en `~/Library/Application Support/Eco` (o en la carpeta de `ECO_DATA_DIR`, en las pruebas), como archivos JSON escritos con `JSONStore`. No hay base de datos ni sincronización.

## Compilación sin Xcode

- `scripts/build.sh` compila con `swift build`, arma el bundle `Eco.app` (con `Resources/Info.plist`), genera el ícono con el propio ejecutable (`--render-iconset` + `iconutil`) y firma la app.
- `scripts/signing.sh` crea y usa un certificado local fijo para que macOS conserve los permisos entre compilaciones.
- Con solo las herramientas de línea de comandos, las macros de SwiftUI como `@State` no están disponibles (su plugin viene con Xcode). Por eso el estado local de las vistas usa `@StateObject` con un `ObservableObject`.
- El logo se dibuja con código (`AppIcon.swift`), así no depende de archivos de diseño: el mismo dibujo genera el ícono de la app, la versión clara y el ícono de la barra de menú.
