<div align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Design/AppIcon-Dark.png">
    <img src="Design/AppIcon-Default.png" width="140" alt="Icono de CleanBar">
  </picture>
  <h1>CleanBar</h1>
  <p><strong>Un organizador sencillo de la barra de menús para macOS.</strong></p>
  <p>
    <img src="https://img.shields.io/badge/macOS-27%2B-blue" alt="macOS 27+">
    <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
    <img src="https://img.shields.io/badge/SwiftUI-Liquid%20Glass-8A2BE2" alt="SwiftUI + Liquid Glass">
    <img src="https://img.shields.io/badge/idiomas-English%20%7C%20Espa%C3%B1ol-green" alt="Inglés y español">
  </p>
  <p>🇬🇧 <a href="README.md">Read in English</a></p>
</div>

---

CleanBar vive en tu barra de menús y oculta los iconos que no necesitas ver todo el tiempo: los de otras apps y los del propio macOS (Wi‑Fi, Bluetooth, Brillo del teclado…). Los iconos ocultos no se mostrarán en la barra de menús. Haz clic en el icono de CleanBar y aparecerán; vuelve a hacer clic y desaparecen. También puede mostrar la temperatura de tu Mac, con el historial de cada sensor, y ajustar la velocidad de sus ventiladores.

Hecha de forma nativa para macOS 27+ con SwiftUI y AppKit.

## Instalación

Descarga el último `.dmg` de la [página de Releases](https://github.com/juancarloslopez3/CleanBar/releases), ábrelo y arrastra **CleanBar** a tu carpeta Aplicaciones.

CleanBar tiene que ejecutarse desde **Aplicaciones**: macOS solo reconoce los iconos de la barra de menús de las apps que están en /Applications o /Library. Si se ejecuta desde otro sitio, CleanBar no podrá ocultar los iconos.

> [!IMPORTANT]
> La app está firmada localmente y no con un certificado de pago de Apple Developer, así que macOS bloquea la primera apertura. Para permitirla: abre **Ajustes del Sistema → Privacidad y seguridad**, desplázate hasta el aviso sobre CleanBar y haz clic en **Abrir igualmente**. Solo tienes que hacerlo una vez por versión.

Después, la primera vez que la abras:

1. **Permite Accesibilidad** (obligatorio) y **Grabación de pantalla** (para las imágenes de los iconos) en el panel **Permisos** de CleanBar. Haz clic en **Permitir**: Ajustes del Sistema se abre en la sección correcta, con el icono de CleanBar en un panel flotante. Arrastra el icono a la lista y listo.
2. **Sal de Bartender, Ice, Hidden Bar o Dozer** si los usas. Dos organizadores se pelean por los mismos iconos.
3. **Elige qué ocultar.** Haz clic derecho en el icono de CleanBar → **Editar la barra de menús** y arrastra iconos a **Ocultos**. No se oculta nada hasta que lo hagas.

CleanBar es un agente de la barra de menús: después de abrirla, búscala en la barra de menús, no en el Dock.

## Funciones

- **Oculta cualquier icono** — los de otras apps y los del propio macOS: Wi‑Fi, Bluetooth, Batería, Sonido, Pantalla, Brillo del teclado, Duplicar pantalla y Centro de control. También la temperatura de CleanBar. El reloj siempre será visible.
- **Un clic para mostrarlos** — haz clic en el icono de CleanBar o pulsa tu atajo. Los iconos ocultos se despliegan desde él uno tras otro y se ocualtan al terminar, pueden volver a ocultarse solos tras 1 a 60 segundos.
- **Barra flotante** — o deja los iconos ocultos fuera de la barra de menús y muéstralos en una barra bajo el icono de CleanBar. Haz clic en uno para abrir su menú: el icono vuelve a la barra de menús hasta que el menú se cierra.
- **Espacio vacío de la barra de menús** — muestra los iconos ocultos pasando el puntero o haciendo clic sobre una parte vacía de la barra de menús. Así puedes ocultar también el propio icono de CleanBar.
- **Editor de la barra de menús** — arrastra imágenes de tus iconos entre **Visibles** y **Ocultos**, o a cualquier lugar de una fila, incluidos sus extremos, para reordenar la barra de menús. CleanBar mueve los iconos por ti.
- **Iconos nuevos** — el marcador *Aquí aparecen los iconos nuevos* decide dónde van los iconos de las apps recién instaladas, incluso puedes poner que directamente a vayan a **Ocultos**.
- **Temperatura en la barra de menús** — actívala en **Ajustes → Sensores** y elige qué sensor muestra, su color y su tamaño. O muestra solo un icono para ahorrar CPU: los sensores se leen entonces cada 30 segundos en vez de cada 5.
- **Todos los sensores** — haz clic en la temperatura para ver los sensores y ventiladores que quieras, en el orden que quieras. Deja el puntero sobre uno para ver su historial de la última hora, día, semana o mes.
- **Control de ventiladores** — deja el puntero sobre **Ventiladores** para ajustar su velocidad con reguladores, elegir un perfil (25%, 50%, 75% y 100% para empezar, y los tuyos, con el nombre que quieras) o dejar que se encargue macOS, como siempre.
- **Reglas de ventiladores** — pon los ventiladores en un perfil cuando un sensor supere una temperatura, o según lo que esté haciendo el Mac: cargando, con batería, enchufado, en modo de bajo consumo, con la tapa cerrada o sobrecalentado. Un ajuste predeterminado decide qué hacen los ventiladores al abrirse CleanBar.
- **A tu gusto** — cinco símbolos para el icono (círculo, tres puntos, punto, estrella, flecha), aspecto claro, oscuro o automático, y apertura al iniciar sesión.
- **Inglés y español** — Por defecto sigue el idioma de tu Mac, o elige uno en Ajustes → General.

## Privacidad

- **Todo se queda en tu Mac.** Sin analíticas, sin cuentas. Lo único que CleanBar consulta en internet es si hay una versión nueva: una vez cada 30 días mira la última versión publicada en GitHub, y solo la descarga si tú lo dices. Los ajustes se guardan en local, las imágenes de los iconos para la barra flotante se guardan en caché en `~/Library/Caches/com.cleanbar.CleanBar` y el historial de los sensores se guarda en `~/Library/Application Support/com.cleanbar.CleanBar`.
- **Accesibilidad** se usa para encontrar los iconos de la barra de menús y moverlos, igual que harías tú con <kbd>⌘</kbd> y arrastrar.
- **Grabación de pantalla** se usa solo para captar los iconos de la barra de menús para el editor y la barra flotante. CleanBar capta la barra de menús y nada más.
- **Tu contraseña** solo se pide para ajustar la velocidad de un ventilador, la primera vez. Solo los administradores pueden cambiar los ventiladores, así que eso instala un pequeño asistente que se ejecuta como root (`/Library/PrivilegedHelperTools/com.cleanbar.CleanBar.FanHelper` y su entrada en `/Library/LaunchDaemons`). Lo único que puede hacer es ajustar los ventiladores dentro de sus propios límites y devolvérselos a macOS, y solo se ejecuta mientras los ventiladores tengan una velocidad ajustada. **Ajustes → Sensores → Eliminar asistente** lo quita de tu Mac.
- **Al salir de CleanBar vuelven todos los iconos a la normalidad** y macOS vuelve a encargarse de los ventiladores, incluso si CleanBar se ha cerrado inesperadamente.

## Atajos

| Acción | Atajo |
|---|---|
| Mostrar u ocultar los iconos ocultos | Clic en el icono de CleanBar, o tu atajo |
| Abrir el menú de CleanBar (Editar la barra de menús · Ajustes · Salir) | Clic derecho o <kbd>⌃</kbd>-clic en el icono de CleanBar |
| Mostrar los iconos ocultos sin el icono de CleanBar | Pasar el puntero o hacer clic sobre un espacio vacío de la barra de menús (opcional) |
| Abrir los ajustes con el icono de CleanBar oculto | Volver a abrir CleanBar desde Spotlight o Aplicaciones |
| Atajo para mostrar / ocultar | Configurable en Ajustes → General |
| Ver los sensores y ventiladores | Clic en la temperatura de la barra de menús |
| Ver el historial de un sensor o un ventilador | Dejar el puntero sobre su fila, o hacer clic en ella |
| Ajustar los ventiladores | Dejar el puntero sobre **Ventiladores**, arriba de la lista, o hacer clic |
| Renombrar o eliminar un perfil de ventilador que hayas añadido | Seleccionarlo en Ajustes → Sensores y pulsar <kbd>Retorno</kbd>, o hacer clic secundario en él |

## Limitaciones conocidas

- **Por app** — los iconos de una app se ocultan juntos. Los iconos del propio macOS se ocultan uno a uno, pero solo los de la lista de arriba; otros (Concentración, Ahora suena…) no se pueden ocultar.
- **Apps fuera de /Applications y /Library** — macOS no las distingue, así que sus iconos se ocultan siempre que CleanBar oculta iconos. El editor te dice cuáles son.
- **El Centro de notificaciones** no se abre por sí solo mientras hay iconos ocultos. CleanBar recoge tu clic en el reloj y lo abre por ti, así que los iconos ocultos pueden verse por un instante.
- **Barras de menús llenas** — si los iconos que dejas visibles no caben, macOS sigue poniendo algunos detrás de su botón («).
- **Las imágenes de la barra flotante no son en directo** — un icono que cambia solo (una gráfica de CPU, un temporizador) se ve como estaba la última vez que CleanBar lo vio. La primera vez que se abre una app con iconos ocultos, su icono aparece en la barra de menús durante un segundo para que CleanBar lo capte.
- **Apple no documenta los sensores ni los ventiladores** — qué sensor es cada uno viene de lo que se ha ido averiguando, chip a chip, así que algún nombre puede no ser exacto y un chip más nuevo que CleanBar puede mostrar menos sensores. Una actualización de macOS podría cambiar cómo se controlan los ventiladores.
- **Una sola app para los ventiladores** — si otra app (iStat Menus, Macs Fan Control…) está ajustando los ventiladores, CleanBar lo indica y no interfiere. Desactiva su control de ventiladores para usar el de CleanBar.
- **El historial tiene huecos** — los sensores solo se leen mientras el Mac está activo, CleanBar está abierto y el ajuste está activado.

## Compilar desde el código

Necesita **macOS 27+** y **Xcode 27+**.

```bash
open CleanBar.xcodeproj   # y después ⌘R en Xcode
```

O compila desde la línea de comandos:

```bash
xcodebuild -project CleanBar.xcodeproj -scheme CleanBar -destination 'platform=macOS' build
```

Las compilaciones Debug se instalan directamente en `/Applications/CleanBar.app` y se ejecutan desde ahí, porque macOS solo reconoce los iconos de la barra de menús de las apps que están en /Applications. Cada compilación local tiene una firma nueva, así que macOS vuelve a pedir los permisos; CleanBar borra por ti las entradas antiguas.

CleanBar es un agente de la barra de menús (`LSUIElement`): después de abrirla, búscala en la barra de menús, no en el Dock.

## Arquitectura

- **La lista de apps permitidas de la barra de menús de macOS 27** — `IconHider` incluye todas las apps e iconos del sistema salvo los ocultos mediante `MBAssessmentModeAssertion`, una API privada de MenuBarClientCore pensada para apps de exámenes (Bartender 7 también la usa), y rehace la lista cuando se abren apps.
- **Accesibilidad** — `MenuBarScanner` lee los iconos y dónde están, `ItemMover` los mueve con eventos de <kbd>⌘</kbd> y arrastrar, e `ItemImageCapture` los capta de la ventana de la barra de menús del Window Server.
- **Ajustes en SwiftUI** con paneles al estilo de Ajustes del Sistema, y AppKit (`NSStatusItem`, `NSPanel`) para el icono de CleanBar, la barra flotante y el panel de permisos.
- **Sensores** — `SMC` lee el System Management Controller con IOKit, sin necesidad de permisos, `SensorMonitor` guarda los últimos valores y `SensorHistory` los promedia en una pequeña base de datos SQLite, con una tabla de claves por chip en `SensorCatalog` (gracias a [Stats](https://github.com/exelban/stats)).
- **Ventiladores** — escribir en el SMC requiere root, así que `FanController` habla por XPC con la herramienta `FanHelper`, un daemon de launchd que se inicia cuando hace falta. Solo acepta velocidades de ventilador dentro de sus límites, nunca escrituras arbitrarias en el SMC, y devuelve los ventiladores a macOS cuando CleanBar se desconecta. Se instala con la contraseña de un administrador, ya que `SMAppService` y `SMJobBless` requieren un Developer ID.
- **Swift 6** con `MainActor` como aislamiento por defecto.
- **`AppSettings` `@Observable`** guardado en `UserDefaults`, y una hot key de Carbon para el atajo global (sin permisos extra).
- **String Catalog** (`Localizable.xcstrings`) para la traducción al español.

## Licencia

CleanBar se publica bajo la [licencia MIT](LICENSE).

---

<div align="center">Hecho por <a href="https://github.com/juancarloslopez3">Juan Carlos López</a></div>
