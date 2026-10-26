# ScanBridge

Scan de codes-barres et de QR codes pour iOS. Le même code fonctionne :

- **sur iPhone/iPad** : caméra de l'appareil, décodage matériel via `AVCaptureMetadataOutput` ;
- **dans le Simulateur iOS**, qui n'a pas de caméra : la caméra du Mac est diffusée dans l'app par
  l'outil `scanbridge-host`, et le décodage est fait sur le Mac par Vision.

```
┌──────────── Mac ─────────────┐        TCP 127.0.0.1:9876        ┌──── Simulateur iOS ────┐
│ scanbridge-host              │  ─── images JPEG + codes lus ──▶ │ App                    │
│ caméra FaceTime → Vision     │  ◀──────── handshake ─────────── │  └ CodeScanner         │
└──────────────────────────────┘                                  └────────────────────────┘
```

Aucune ligne de code spécifique au Simulateur dans l'app : `CodeScanner` choisit sa source tout seul.

## Prérequis

- iOS 16+ (bibliothèque), macOS 14+ (outil hôte)
- Xcode 16+ / Swift 6

## Installation

Dans Xcode : **File › Add Package Dependencies…**, puis l'URL du dépôt. Ajoutez le produit
**ScanBridge** à la cible de l'app. Ne liez pas `scanbridge-host` : il ne s'exécute que sur le Mac.

Ou dans un `Package.swift` :

```swift
.package(url: "https://github.com/<vous>/ScanBridge.git", from: "1.0.0")
```

Ajoutez la clé suivante à l'`Info.plist` de l'app (obligatoire, sans quoi iOS termine l'app) :

```xml
<key>NSCameraUsageDescription</key>
<string>La caméra sert à scanner les codes-barres et les QR codes.</string>
```

## Utilisation

### SwiftUI

```swift
import ScanBridge
import SwiftUI

struct ScanScreen: View {
    @StateObject private var scanner = CodeScanner(
        configuration: ScannerConfiguration(symbologies: [.qr, .ean13, .code128])
    )
    @State private var result: ScannedCode?

    var body: some View {
        CodeScannerView(scanner: scanner) { code in
            result = code
            scanner.isPaused = true          // stoppe la remontée de codes pendant l'affichage
        }
        .sheet(item: $result, onDismiss: { scanner.isPaused = false }) { code in
            Text(code.payload)
        }
    }
}
```

`CodeScannerView` démarre la caméra quand elle apparaît, l'arrête quand elle disparaît, et affiche un
message si la caméra est indisponible ou si `scanbridge-host` ne tourne pas.

### Sans la vue

```swift
let scanner = CodeScanner()
let codes = scanner.codes()   // s'abonner avant de démarrer
await scanner.start()

for await code in codes {
    print(code.symbology, code.payload)
}
```

| API | Rôle |
| --- | --- |
| `start()` / `stop()` | Démarre ou arrête la caméra. Idempotents. Les erreurs passent par `state`. |
| `codes()` | `AsyncStream` de codes ; un flux indépendant par appel. |
| `state` | `.idle`, `.starting`, `.running(source)`, `.waitingForHost`, `.failed(error)`. `@Published`. |
| `lastScannedCode` | Dernier code remonté. `@Published`. |
| `isPaused` | La caméra continue de tourner mais aucun code n'est remonté. |
| `resetDuplicateSuppression()` | Fait remonter de nouveau le code actuellement visible. |

### Mode lite : flux caméra seul

Pour simplement afficher la caméra, sans aucune lecture de code :

```swift
@StateObject private var camera = CodeScanner(configuration: .lite())

var body: some View {
    CodeScannerView(scanner: camera)
}
```

- **Dans le Simulateur**, l'app signale le mode lite à `scanbridge-host`, qui se contente alors de
  retransmettre le flux de la caméra du Mac : Vision ne tourne pas et le Mac consomme moins de CPU.
- **Sur iPhone**, seul l'aperçu de la caméra est affiché ; aucun décodage n'est activé.

Le Mac décide pour chaque connexion : un simulateur en mode lite et un autre en mode scan peuvent
être connectés en même temps. Pour forcer le flux seul quels que soient les clients :
`swift run scanbridge-host --lite`.

### Configuration

```swift
ScannerConfiguration(
    mode: .scan,                                     // .lite = flux caméra seul
    symbologies: Symbology.twoDimensional,           // .qr, .ean13… ; moins = plus rapide et plus fiable
    duplicateSuppressionInterval: .seconds(2),       // nil = un événement à chaque image
    simulatorHost: SimulatorHost(port: 9876)         // ignoré sur appareil
)
```

Un code maintenu devant la caméra n'est remonté **qu'une fois**. Il ne l'est de nouveau qu'après
être resté hors champ pendant `duplicateSuppressionInterval`.

## Utiliser la caméra du Mac dans le Simulateur

1. Dans un terminal, depuis le dossier du package :

   ```bash
   swift run -c release scanbridge-host
   ```

   La première fois, macOS demande l'accès à la caméra pour le terminal. En cas de refus :
   **Réglages Système › Confidentialité et sécurité › Caméra**.

2. Lancez l'app dans le Simulateur. La connexion est automatique et se rétablit si l'hôte redémarre.

La caméra du Mac ne s'allume que lorsqu'au moins un simulateur est connecté. Le serveur n'écoute que
sur `127.0.0.1` : le flux n'est jamais exposé au réseau.

Options utiles :

```bash
swift run scanbridge-host --list-cameras          # caméras disponibles (y compris iPhone en Continuity Camera)
swift run scanbridge-host --camera "Logitech"     # choisir une caméra
swift run scanbridge-host --lite                  # flux seul, jamais d'analyse de codes
swift run scanbridge-host --port 9000 --fps 30    # voir --help
```

Si le package a été ajouté par URL dans Xcode, son code source se trouve dans
`~/Library/Developer/Xcode/DerivedData/<Projet>-*/SourcePackages/checkouts/ScanBridge`. Le plus simple
reste de cloner le dépôt une fois et de compiler l'outil :

```bash
swift build -c release --product scanbridge-host
cp .build/release/scanbridge-host /usr/local/bin/
```

> **Astuce :** une app iOS lancée sur Mac Apple Silicon (« Designed for iPad ») ou en Mac Catalyst
> n'est pas un simulateur : elle utilise directement la caméra du Mac, sans `scanbridge-host`.

## Architecture

| Cible | Plateforme | Contenu |
| --- | --- | --- |
| `ScanBridge` | iOS | `CodeScanner`, `CodeScannerView`, backends caméra et Simulateur |
| `ScanBridgeCore` | iOS, macOS | `Symbology`, protocole réseau (encodage/décodage incrémental) |
| `ScanBridgeHost` | macOS | Outil `scanbridge-host` : capture, Vision, serveur TCP |

Protocole : messages `"SB" | type (1 octet) | longueur (4 octets) | payload`, avec négociation de
version à la connexion. Un hôte et une app dont les versions diffèrent l'indiquent clairement
(`ScannerError.incompatibleHost`), sans planter.

## Tests

```bash
swift test                                    # protocole, filtre de doublons, client réseau, options CLI
xcodebuild test -scheme ScanBridge-Package \
  -destination "platform=iOS Simulator,name=iPhone 18 Pro" \
  -only-testing:ScanBridgeTests -only-testing:ScanBridgeCoreTests
```
