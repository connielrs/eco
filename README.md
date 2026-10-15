# Eco

Dictado por voz para macOS, de uso personal. Todo se procesa en el Mac: la voz se transcribe con WhisperKit y el texto se limpia con Apple Intelligence (Foundation Models).

## Qué hace (MVP)

- Dictar con un atajo de teclado y pegar el texto donde esté el cursor, en cualquier app.
- Limpiar el texto: puntuación, muletillas y retractaciones ("el martes, no, el miércoles").
- Diccionario personal con nombres y términos propios.
- Historial de dictados.
- Barra flotante que muestra cuando está escuchando.
- Grabar reuniones (micrófono + audio del Mac), con transcripción y resumen.

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

## Permisos

- **Micrófono:** para escuchar lo que dictas.
- **Accesibilidad:** para detectar el atajo y pegar el texto en cualquier app.
- **Audio del sistema:** solo para grabar reuniones, se pide la primera vez que grabas una.
