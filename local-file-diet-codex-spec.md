# Local File Diet — Specifica tecnica completa per Codex

Versione: 1.0  
Target: iPhone only  
Piattaforma: iOS 17+ consigliato, iOS 18+ se il progetto viene creato da zero nel 2026  
Linguaggio: Swift 5.10+ / Swift 6 ready  
UI: SwiftUI  
Backend: nessuno  
Account: nessuno  
Elaborazione: 100% locale sul dispositivo  
Categoria App Store suggerita: Utilities / Productivity  
Modello commerciale previsto: free trial locale + lifetime unlock con StoreKit 2

---

## 0. Missione del prodotto

Costruire una utility iPhone minimalista, professionale e local-first che consenta all'utente di ridurre file troppo grandi alla dimensione richiesta, senza caricare nulla su server esterni.

Il prodotto deve risolvere un problema preciso:

> “Ho un file troppo grande per email, WhatsApp, PEC, portali pubblici, moduli online, sistemi HR, università, assicurazioni o invii rapidi. Voglio ridurlo bene, in locale, senza perdere più qualità del necessario.”

L'app non deve essere un generico file manager, un editor PDF completo o un social media tool. Deve essere una compress utility estremamente focalizzata.

Nome provvisorio: **Local File Diet**.

Tagline provvisoria:

> Compress files to the exact size you need. Privately, on-device.

---

## 1. Principi non negoziabili

### 1.1 Local-only

Tutte le operazioni devono avvenire sul dispositivo. Vietato:

- upload di file su server;
- API cloud per compressione;
- account obbligatori;
- analytics che includano contenuti dei file;
- logging di path, nomi file sensibili o contenuto OCR;
- SDK pubblicitari;
- tracking cross-app.

Consentito:

- StoreKit 2 per acquisti;
- metriche locali aggregate opzionali, solo se non esportate;
- crash reporting solo se configurato per non includere file, path, nomi documento o dati utente. Per MVP, evitare crash SDK esterni.

### 1.2 iPhone only

Il target è solo iPhone. Non ottimizzare per iPad in questa fase. L'app deve comunque non rompersi su layout più grandi, ma la UI, le interazioni e i test principali sono per iPhone.

### 1.3 Minimalismo professionale

L'app deve sembrare moderna, veloce e pulita. Non deve avere onboarding lunghi, tab inutili, dashboard complesse o impostazioni premature.

Obiettivo UX:

1. importo file;
2. scelgo preset o target size;
3. vedo stima qualità/dimensione;
4. comprimo;
5. condivido o salvo.

### 1.4 Qualità prima della compressione estrema

La compressione non deve semplicemente “distruggere qualità finché il file pesa poco”. Deve cercare il miglior compromesso possibile, con fallback trasparenti quando il target è irrealistico.

### 1.5 Nessuna promessa falsa

L'app deve spiegare quando:

- un file è già compresso;
- il target scelto è irrealistico;
- il formato non consente riduzioni significative;
- ridurre ancora causerebbe qualità troppo bassa;
- il tipo file non è supportato.

---

## 2. Fonti tecniche Apple da rispettare

Implementare usando framework Apple nativi dove possibile.

Riferimenti:

- UniformTypeIdentifiers per riconoscere tipi file e dichiarare document types/share extension: https://developer.apple.com/documentation/uniformtypeidentifiers
- PDFKit per leggere, visualizzare e manipolare PDF: https://developer.apple.com/documentation/pdfkit
- Image I/O per leggere/scrivere immagini, metadata, JPEG/HEIC, downsampling: https://developer.apple.com/documentation/imageio
- AVFoundation / AVAssetExportSession per esportare e comprimere video: https://developer.apple.com/documentation/avfoundation/avassetexportsession
- Exporting video to alternative formats: https://developer.apple.com/documentation/avfoundation/exporting-video-to-alternative-formats
- App Intents per eventuale integrazione Shortcuts: https://developer.apple.com/documentation/appintents

Codex deve privilegiare API stabili Apple e codice idiomatico Swift moderno.

---

## 3. Scope dell'MVP

### 3.1 Tipi file supportati nella prima release

MVP deve supportare:

1. Immagini:
   - JPEG
   - PNG
   - HEIC/HEIF quando supportato dal dispositivo
   - TIFF solo in input, output preferito JPEG/HEIC/PDF a seconda del preset

2. PDF:
   - PDF immagine/scansione
   - PDF misti testo + immagini
   - PDF generici con pagine rasterizzabili

3. Video:
   - MOV
   - MP4
   - M4V

4. ZIP:
   - Creazione ZIP locale da più file
   - Non promettere compressione miracolosa di file già compressi

Non supportare nell'MVP:

- documenti Office modificabili come DOCX/XLSX/PPTX;
- archivi RAR/7z;
- audio-only;
- Live Photos come oggetto composito;
- cartelle intere da file system;
- batch massivo oltre 20 file;
- editing video avanzato;
- OCR;
- rimozione intelligente di pagine PDF;
- compressione con AI generativa.

### 3.2 Modalità di ingresso

Supportare tre ingressi:

1. **Import from Files** nell'app principale.
2. **Share Extension** da altre app.
3. **Photos picker** per foto/video dalla libreria, senza richiedere accesso completo alla libreria.

Priorità MVP:

1. App principale con DocumentPicker + PhotosPicker.
2. Share Extension.
3. App Intents/Shortcuts come fase successiva.

---

## 4. Funzionalità principali

### 4.1 Import intelligente

Quando l'utente importa un file, l'app deve:

- copiare il file in una working directory temporanea sandboxed;
- determinare UTType reale usando UniformTypeIdentifiers e, se possibile, estensione + magic bytes;
- calcolare dimensione originale;
- stimare categoria: image, pdf, video, archive, unsupported;
- mostrare anteprima leggera;
- non caricare né inviare nulla fuori dispositivo;
- ripulire file temporanei obsoleti.

Edge case da gestire:

- file senza estensione;
- estensione errata;
- file molto grande;
- file iCloud non ancora scaricato;
- URL security-scoped;
- permessi negati;
- file corrotto;
- file DRM/protetto;
- PDF password-protected.

### 4.2 Preset target size

La feature principale è comprimere sotto un limite esatto.

Preset MVP:

- Under 25 MB — email-friendly
- Under 20 MB — common upload limit
- Under 10 MB — forms / portals
- Under 5 MB — strict forms
- Under 2 MB — very strict upload
- Custom size — MB or KB

Preset opzionali localizzati per Italia:

- PEC / portale pubblico: 10 MB
- Modulo online: 5 MB
- WhatsApp quick share: 16 MB o preset configurabile
- Low data: 2 MB

Nota: non hardcodare claim come “WhatsApp max X MB” senza possibilità di aggiornare, perché i limiti cambiano. Usare nomi generici o valori modificabili.

### 4.3 Modalità qualità

Offrire tre profili:

1. **Best quality**
   - cerca riduzione minima necessaria;
   - preserva risoluzione il più possibile;
   - usa qualità alta;
   - più lento.

2. **Balanced** default
   - buon compromesso qualità/dimensione;
   - target centrato;
   - default per maggioranza utenti.

3. **Smallest file**
   - massima riduzione ragionevole;
   - può ridurre risoluzione e qualità;
   - mostra avviso se degrado visibile probabile.

### 4.4 Stima e preview

Prima della compressione, mostrare:

- dimensione originale;
- target;
- strategia prevista;
- output format;
- stima qualitativa: Excellent / Good / Acceptable / Low;
- eventuali warning.

Dopo la compressione, mostrare:

- dimensione finale;
- percentuale riduzione;
- target raggiunto sì/no;
- anteprima prima/dopo per immagini e PDF;
- durata compressione;
- pulsanti: Share, Save to Files, Replace Copy, Try Smaller, Keep Better Quality.

### 4.5 Output

L'utente deve poter:

- condividere il file compresso con UIActivityViewController;
- salvarlo in Files con UIDocumentPicker / file exporter SwiftUI;
- salvare in Photos solo per immagini/video, chiedendo permesso corretto;
- rinominare prima dell'export;
- mantenere originale intatto.

Mai sovrascrivere l'originale senza azione esplicita.

---

## 5. Compression engine — architettura

### 5.1 Modello concettuale

Creare un modulo indipendente dalla UI:

```swift
protocol CompressionEngine {
    func estimate(input: CompressionInput, settings: CompressionSettings) async throws -> CompressionEstimate
    func compress(input: CompressionInput, settings: CompressionSettings, progress: @escaping (CompressionProgress) -> Void) async throws -> CompressionResult
}
```

Implementazioni:

- ImageCompressionEngine
- PDFCompressionEngine
- VideoCompressionEngine
- ArchiveCompressionEngine
- PassthroughUnsupportedEngine

### 5.2 Tipi dati principali

Creare modelli Swift chiari:

```swift
enum FileKind: String, Codable {
    case image
    case pdf
    case video
    case archive
    case unsupported
}

struct CompressionInput: Identifiable, Codable {
    let id: UUID
    let originalURL: URL
    let workingURL: URL
    let originalFilename: String
    let fileExtension: String?
    let detectedTypeIdentifier: String?
    let fileKind: FileKind
    let originalSizeBytes: Int64
    let createdAt: Date
}

struct CompressionSettings: Codable, Equatable {
    var targetSizeBytes: Int64?
    var qualityMode: QualityMode
    var outputFormat: OutputFormat
    var stripMetadata: Bool
    var preserveTransparency: Bool
    var preferHEICWhenAvailable: Bool
    var allowResolutionDownscale: Bool
    var maxDimension: Int?
    var videoResolutionPreset: VideoResolutionPreset?
}

enum QualityMode: String, Codable, CaseIterable {
    case bestQuality
    case balanced
    case smallestFile
}

enum OutputFormat: String, Codable, CaseIterable {
    case automatic
    case jpeg
    case heic
    case png
    case pdf
    case mp4
    case mov
    case zip
    case original
}

struct CompressionEstimate: Codable {
    let estimatedSizeBytes: Int64?
    let estimatedReductionPercent: Double?
    let predictedQuality: PredictedQuality
    let warnings: [CompressionWarning]
    let plannedOperations: [CompressionOperation]
}

struct CompressionResult: Codable {
    let outputURL: URL
    let outputFilename: String
    let originalSizeBytes: Int64
    let compressedSizeBytes: Int64
    let targetReached: Bool
    let reductionPercent: Double
    let warnings: [CompressionWarning]
    let operationsApplied: [CompressionOperation]
    let durationSeconds: Double
}
```

### 5.3 Progress reporting

Progress deve essere user-friendly:

```swift
struct CompressionProgress: Sendable {
    let phase: CompressionPhase
    let fractionCompleted: Double?
    let message: String
}

enum CompressionPhase: String, Sendable {
    case preparing
    case analyzing
    case downsampling
    case encoding
    case optimizing
    case writing
    case verifying
    case completed
}
```

Per video usare progress nativo di AVAssetExportSession quando disponibile, con polling cancellabile.

### 5.4 Cancellazione

Tutte le compressioni devono essere cancellabili.

Requisiti:

- usare Swift Concurrency;
- controllare `Task.isCancelled` nei loop;
- cancellare AVAssetExportSession se l'utente annulla;
- rimuovere output parziali;
- aggiornare UI a stato idle.

---

## 6. Compressione immagini

### 6.1 Obiettivo

Ridurre immagini preservando la migliore qualità visiva possibile entro il target.

### 6.2 Input supportati

- JPEG
- PNG
- HEIC/HEIF
- TIFF
- immagini provenienti da PhotosPicker

### 6.3 Output supportati

- JPEG default universale
- HEIC se `preferHEICWhenAvailable == true` e supportato
- PNG solo se trasparenza importante o scelta manuale
- PDF se l'utente vuole trasformare immagine in PDF leggero

### 6.4 Strategia professionale

Implementare una pipeline a più passaggi:

1. Leggere metadata base con CGImageSource.
2. Determinare dimensioni pixel.
3. Decidere output format.
4. Se necessario, downsampling con `kCGImageSourceCreateThumbnailFromImageAlways` e `kCGImageSourceThumbnailMaxPixelSize`.
5. Scrivere con CGImageDestination.
6. Regolare qualità con binary search.
7. Verificare dimensione finale.
8. Se target non raggiunto, ridurre max dimension in step controllati.
9. Fallire con warning se target impossibile senza qualità pessima.

### 6.5 Binary search sulla qualità

Per JPEG/HEIC, implementare ricerca binaria su qualità:

- range iniziale Best quality: 0.72–0.95
- Balanced: 0.55–0.90
- Smallest: 0.35–0.82
- massimo 8–10 iterazioni
- stop se output <= target e differenza < 3%
- se output già sotto target, scegliere qualità massima nel range

Non usare loop infiniti.

### 6.6 Downscale controllato

Se qualità minima accettabile non basta:

- ridurre lato lungo a 4096, 3072, 2560, 2048, 1600, 1280, 1024;
- non scendere sotto 1024 px lato lungo salvo modalità Smallest e avviso;
- per screenshot/testo, evitare downscale aggressivo perché peggiora leggibilità;
- distinguere foto da screenshot quando possibile usando aspect ratio, metadata o provenienza.

### 6.7 Metadata

Default MVP:

- `stripMetadata = true` per privacy e dimensione;
- preservare orientamento corretto;
- non preservare GPS;
- non preservare EXIF completo;
- mostrare toggle “Remove metadata” nelle impostazioni avanzate.

### 6.8 PNG

PNG è spesso già compresso lossless. Per PNG:

- se contiene trasparenza e l'utente vuole preservarla, tentare ottimizzazione lossless limitata;
- se non serve trasparenza, proporre conversione JPEG/HEIC;
- spiegare che convertire PNG screenshot in JPEG può ridurre dimensione ma introdurre artefatti su testo.

### 6.9 HEIC

HEIC può dare ottimo rapporto qualità/dimensione, ma non è universalmente accettato da portali vecchi.

Regole:

- Automatic mode: JPEG per massima compatibilità;
- HEIC solo se utente abilita “Prefer smaller modern format”;
- mostrare warning “HEIC may not be accepted by older websites”.

---

## 7. Compressione PDF

### 7.1 Obiettivo

Ridurre PDF senza rompere leggibilità o struttura base.

PDF è difficile: alcuni PDF sono già ottimizzati, alcuni contengono testo vettoriale, altri sono scansioni enormi. L'app deve gestire bene almeno i PDF immagine/scansione.

### 7.2 Input

- PDF non protetti;
- PDF password-protected: rilevare e mostrare errore leggibile;
- PDF multi-pagina;
- PDF misti.

### 7.3 Strategie MVP

Implementare due modalità PDF:

#### Modalità A — Rebuild rasterizzato

Per PDF scansionati o quando l'utente vuole massima riduzione:

1. Aprire PDFDocument.
2. Renderizzare ogni pagina a risoluzione controllata.
3. Ricomprimere pagina come JPEG.
4. Creare nuovo PDF con immagini compresse.
5. Preservare dimensione pagina.
6. Verificare dimensione finale.

Pro:

- riduce molto scansioni pesanti;
- controllo qualità prevedibile.

Contro:

- perde testo selezionabile;
- perde link, annotazioni, form fields;
- può peggiorare documenti vettoriali.

Mostrare warning quando applicato.

#### Modalità B — Conservative export

Per PDF testo/vettoriali:

- evitare rasterizzazione aggressiva;
- tentare riscrittura PDFDocument se riduce overhead;
- se non si ottiene riduzione significativa, mostrare “Already optimized or mostly vector text”.

### 7.4 Riconoscimento PDF scansionato vs vettoriale

Implementare euristica:

- controllare numero pagine;
- tentare estrazione testo da PDFPage.string;
- se testo estratto molto basso e pagine grandi, probabile scansione;
- se testo estratto alto, evitare rasterizzazione di default;
- se dimensione per pagina > 1 MB e testo basso, proporre “Scan compression”.

### 7.5 DPI/render scale

Preset suggeriti:

- Best quality: 200–220 DPI
- Balanced: 150–180 DPI
- Smallest: 100–130 DPI

Per documenti con testo piccolo, non scendere sotto 150 DPI senza warning.

### 7.6 Target size per PDF

Usare strategia iterativa:

1. provare DPI/qualità del profilo;
2. calcolare output;
3. se sopra target, ridurre qualità JPEG;
4. se ancora sopra, ridurre DPI;
5. se sotto target con margine enorme, eventualmente aumentare qualità se modalità Best/Balanced;
6. limitare iterazioni.

### 7.7 Annotazioni e form

MVP:

- Non promettere preservazione di annotazioni interattive/form se si usa modalità rasterizzata.
- Se il PDF contiene annotazioni o form, mostrare warning.
- Conservative export deve preservare meglio, ma non promettere compressione forte.

---

## 8. Compressione video

### 8.1 Obiettivo

Ridurre video locali senza server, usando AVFoundation.

### 8.2 Input

- MOV
- MP4
- M4V
- video importati da Files o PhotosPicker

### 8.3 Output

- MP4 H.264 default per compatibilità;
- MOV opzionale se input MOV e l'utente vuole preservare container;
- HEVC opzionale solo come modalità “smaller modern format”, con warning compatibilità.

### 8.4 Strategie

MVP con AVAssetExportSession:

- usare preset disponibili:
  - AVAssetExportPresetHighestQuality quando non serve grande compressione;
  - AVAssetExportPresetMediumQuality;
  - AVAssetExportPresetLowQuality;
  - preset 1920x1080, 1280x720, 960x540, 640x480 se disponibili;
- output `.mp4` quando compatibile;
- `shouldOptimizeForNetworkUse = true`;
- gestire progress e cancellazione.

### 8.5 Target size video

AVAssetExportSession non consente sempre controllo preciso del bitrate con preset alti. Per MVP:

- stimare bitrate necessario:

```text
targetBitrate ≈ (targetSizeBytes * 8 / durationSeconds) - audioBitrate
```

- scegliere preset più vicino;
- eseguire export;
- se output supera target, provare preset più aggressivo;
- se output molto sotto target e qualità mode Best, provare preset migliore;
- massimo 3 tentativi.

Fase 2 professionale:

- implementare AVAssetReader + AVAssetWriter per controllo bitrate video/audio più preciso;
- configurare AVVideoCompressionPropertiesKey;
- usare H.264 baseline/main/high in base al device;
- supportare HEVC se disponibile;
- preservare orientamento e transform;
- gestire audio bitrate.

Per MVP è accettabile AVAssetExportSession, ma progettare protocollo per sostituire engine video in futuro.

### 8.6 Risoluzioni preset

UI deve offrire:

- Auto
- Keep resolution
- 1080p
- 720p
- 540p
- 480p

Auto deve scegliere in base a target, durata e dimensione originale.

### 8.7 HDR, slow motion, cinematic

MVP:

- non promettere preservazione completa HDR/Cinematic/slow motion metadata;
- mostrare warning se asset ha caratteristiche non standard;
- output compatibile prima di tutto.

---

## 9. ZIP e batch

### 9.1 ZIP locale

Per più file, offrire:

- “Compress each file”
- “Create ZIP”
- “Compress and ZIP”

Usare API Apple/Foundation per archiviazione se disponibili nel target o implementare con ZIPFoundation solo se si accetta una dipendenza esterna leggera e mantenuta.

Preferenza MVP:

- evitare dipendenze esterne se non strettamente necessarie;
- se il progetto richiede ZIP robusto, usare ZIPFoundation e documentare licenza.

### 9.2 Limiti batch MVP

- massimo 20 file;
- massimo totale 1 GB in MVP;
- mostrare warning per batch grandi;
- progress per file corrente + progress totale;
- output: cartella temporanea con risultati + ZIP opzionale.

---

## 10. UX e UI design

### 10.1 Stile

Minimal, elegante, veloce.

Caratteristiche:

- SwiftUI puro;
- supporto Dark Mode;
- Dynamic Type;
- layout one-handed friendly;
- animazioni leggere;
- nessuna schermata sovraccarica;
- massimo 1 primary action per schermata;
- colori neutri con un solo accent color;
- haptic feedback leggero su completamento/errori.

### 10.2 Architettura schermate

#### HomeView

Elementi:

- titolo: “Local File Diet” o nome finale;
- sottotitolo: “Make files smaller. Everything stays on your iPhone.”;
- grande drop/import card;
- pulsanti:
  - Import from Files
  - Pick Photo or Video
- ultimi 3 file compressi, solo metadata locali e cancellabili;
- link piccolo a Settings.

#### FileReviewView

Mostra:

- preview file;
- nome file;
- dimensione originale;
- tipo rilevato;
- target size selector;
- quality mode segmented control;
- output format automatic/manual;
- advanced disclosure;
- CTA: “Compress”.

#### CompressionProgressView

Mostra:

- progress ring/bar;
- fase corrente;
- file corrente se batch;
- pulsante Cancel;
- nessuna distrazione.

#### ResultView

Mostra:

- success/failure;
- original size → compressed size;
- percentuale riduzione;
- target reached badge;
- preview before/after se disponibile;
- CTA primaria: Share;
- secondarie: Save to Files, Try Smaller, Better Quality.

#### SettingsView

Solo impostazioni essenziali:

- default target size;
- default quality mode;
- remove metadata default;
- prefer HEIC;
- clear temporary files;
- privacy explanation;
- purchase/unlock.

### 10.3 Copywriting

Testi chiari, non tecnici.

Esempi:

- “This file already looks optimized.”
- “We can make it smaller, but text may become harder to read.”
- “Target reached.”
- “Could not reach 2 MB without severe quality loss.”
- “Everything was processed locally on your iPhone.”
- “Original file was not changed.”

### 10.4 Empty/error states

Ogni errore deve avere:

- messaggio umano;
- causa probabile;
- azione successiva.

Esempi:

- Unsupported file: “This file type is not supported yet. Try a PDF, image, or video.”
- Protected PDF: “This PDF is password-protected and cannot be compressed.”
- Not enough storage: “Free up space and try again.”
- iCloud not downloaded: “Download the file locally first or try again.”

---

## 11. Architettura app

### 11.1 Pattern consigliato

Usare MVVM + service layer, senza overengineering.

Struttura proposta:

```text
LocalFileDiet/
  App/
    LocalFileDietApp.swift
    AppEnvironment.swift
  Features/
    Home/
    FileReview/
    CompressionProgress/
    Result/
    Settings/
    Paywall/
  Core/
    Models/
    Compression/
    FileImport/
    FileExport/
    Preview/
    Persistence/
    Purchase/
    Logging/
  Extensions/
    ShareExtension/
  Resources/
    Assets.xcassets
    Localizable.xcstrings
  Tests/
    UnitTests/
    IntegrationTests/
    SnapshotTests/
```

### 11.2 Dependency injection semplice

Creare `AppEnvironment`:

```swift
struct AppEnvironment {
    let fileImportService: FileImportServicing
    let compressionRouter: CompressionRouting
    let exportService: FileExportServicing
    let temporaryFileStore: TemporaryFileStoring
    let purchaseService: PurchaseServicing
}
```

Iniettare nei ViewModel. Evitare singleton globali tranne logger leggero.

### 11.3 Swift Concurrency

- Usare `async/await`.
- ViewModel annotati `@MainActor`.
- Engine non MainActor.
- Evitare blocchi CPU pesanti sul main thread.
- Usare `Task` cancellabili.
- Per file grandi, stream/scrittura su disco, non tenere tutto in memoria.

### 11.4 Persistenza

MVP:

- SwiftData o semplice JSON locale per history leggera;
- salvare solo metadata:
  - nome file output;
  - dimensioni;
  - data;
  - tipo;
  - percentuale riduzione;
  - URL solo se ancora dentro sandbox e non sensibile.

Non salvare contenuto file in database.

### 11.5 Temporary files

Directory:

- `Caches/Working`
- `Caches/Outputs`
- `tmp/ImportStaging`

Policy:

- cancellare file temporanei vecchi > 24h;
- impostazione “Clear temporary files”;
- dopo share/save, mantenere output recente solo se necessario per history;
- non usare Documents per file temporanei.

---

## 12. Share Extension

### 12.1 Obiettivo

Permettere compressione rapida da Files, Photos, Mail, Safari, WhatsApp e altre app quando inviano file compatibili.

### 12.2 MVP Share Extension

Flusso semplice:

1. L'utente sceglie “Local File Diet” da Share Sheet.
2. Extension copia file in App Group container.
3. Apre app principale con deep link o mostra mini UI se fattibile.
4. App principale continua compressione.

Preferire app principale per pipeline completa, perché extension ha limiti di memoria/tempo.

### 12.3 App Group

Configurare App Group per condividere file temporanei tra extension e app:

```text
group.com.company.localfilediet
```

La extension deve:

- copiare file in container condiviso;
- creare manifest JSON con metadata;
- chiamare openURL verso app principale se consentito;
- gestire fallback se apertura non avviene.

### 12.4 Tipi dichiarati

Dichiarare supporto a UTType:

- public.image
- public.movie
- com.adobe.pdf
- public.zip-archive se necessario
- public.data solo con cautela, per evitare comparsa ovunque.

---

## 13. Privacy e sicurezza

### 13.1 Privacy promise

L'app deve poter dichiarare onestamente:

- No account.
- No uploads.
- No cloud compression.
- Files stay on your iPhone.
- Original files are never modified unless user explicitly exports/replaces.

### 13.2 Protezione dati

Quando si scrivono file temporanei/output:

- usare Data Protection se possibile;
- evitare backup iCloud per cache temporanee;
- applicare resource value `isExcludedFromBackup` per cache;
- usare nomi file non eccessivamente sensibili nei temp se possibile.

### 13.3 Metadata privacy

Default strip metadata per immagini e video dove tecnicamente semplice.

Per video metadata stripping completo può essere più complesso: non promettere più di quanto implementato. Mostrare “Remove common metadata” se il supporto è parziale.

### 13.4 App Privacy Label

Progettare per “Data Not Collected” se possibile.

Non integrare SDK che obbligano a dichiarazioni privacy più pesanti.

---

## 14. Monetizzazione

### 14.1 StoreKit 2

Implementare acquisto lifetime con StoreKit 2.

MVP monetization:

- 20 compressioni gratuite locali;
- lifetime unlock;
- nessun abbonamento per MVP;
- contatore compressioni salvato localmente;
- restore purchases.

### 14.2 Paywall minimal

Paywall semplice:

- “Unlock unlimited local compression”;
- bullets:
  - unlimited files;
  - batch compression;
  - custom presets;
  - no account;
  - one-time purchase;
- pulsanti: Buy, Restore, Not now.

Non bloccare compressione durante sviluppo/test.

---

## 15. Testing

### 15.1 Unit test obbligatori

Creare test per:

- File type detection;
- target size parsing;
- byte formatting;
- quality mode mapping;
- output filename generation;
- compression estimate warnings;
- temporary file cleanup;
- cancellation behavior;
- image quality binary search con fixture piccole;
- PDF scanned/vector heuristic;
- video bitrate estimate.

### 15.2 Integration test

Usare fixture locali:

```text
Fixtures/
  image_large.jpg
  screenshot_text.png
  image_heic.heic
  scan_5pages.pdf
  vector_text.pdf
  short_video.mov
  already_compressed.jpg
```

Testare:

- compressione sotto target realistico;
- target irrealistico genera warning;
- output esiste ed è leggibile;
- originale non modificato;
- cancellazione cancella output parziale.

### 15.3 Performance test

Misurare:

- tempo compressione immagine 12 MP;
- PDF 10 pagine scansione;
- video 30 secondi 1080p;
- memoria massima approssimativa;
- main thread responsiveness.

### 15.4 UI test minimi

Flussi:

- import file mock;
- selezione target;
- compressione;
- result screen;
- settings;
- paywall restore mocked.

---

## 16. Accessibilità e localizzazione

### 16.1 Accessibilità

Requisiti:

- supporto VoiceOver;
- label descrittive per pulsanti;
- Dynamic Type;
- contrasto sufficiente;
- non comunicare stato solo con colore;
- haptic non essenziale;
- target touch adeguati.

### 16.2 Localizzazione

Preparare app per:

- English base;
- Italian localization.

Usare String Catalog `.xcstrings`.

Non hardcodare testi in View.

---

## 17. Logging e diagnostica

Usare `os.Logger`.

Regole:

- non loggare path completi;
- non loggare nomi file completi se possono essere sensibili;
- non loggare contenuto file;
- loggare solo eventi tecnici generici:
  - compression_started kind=image sizeBucket=10-50MB;
  - compression_failed reason=unsupported;
  - target_not_reached.

Per MVP, i log restano locali.

---

## 18. Criteri di accettazione

### 18.1 Generali

L'implementazione è accettabile solo se:

- nessuna compressione richiede rete;
- Airplane Mode non rompe le funzioni core;
- import/export funziona con Files;
- Share Sheet importa almeno PDF, immagini e video;
- UI resta responsive durante compressione;
- l'utente può cancellare operazione;
- originale non viene modificato;
- output viene verificato prima di mostrare success;
- errori sono umani e recuperabili.

### 18.2 Immagini

- JPEG grande può essere compresso sotto target realistico;
- PNG screenshot viene gestito con warning se conversione lossy;
- metadata GPS rimossi quando stripMetadata attivo;
- orientamento corretto preservato;
- target irrealistico mostra warning, non falso successo.

### 18.3 PDF

- PDF scansione multi-pagina viene ridotto sensibilmente;
- PDF testo/vettoriale non viene distrutto senza warning;
- PDF protetto mostra errore chiaro;
- output PDF si apre correttamente.

### 18.4 Video

- video breve viene esportato in MP4;
- progress visibile;
- cancel funziona;
- target realistico tentato con preset progressivi;
- se target non raggiunto, risultato e motivo sono chiari.

---

## 19. Roadmap consigliata per Codex

### Fase 1 — Skeleton app

Obiettivi:

- creare progetto SwiftUI iPhone only;
- creare HomeView, FileReviewView, ResultView;
- implementare import da Files;
- creare modelli e protocolli;
- implementare temporary file store;
- nessuna compressione reale ancora.

Deliverable:

- app compilabile;
- import file mostra metadata.

### Fase 2 — Image engine

Obiettivi:

- implementare ImageCompressionEngine con ImageIO;
- binary search qualità;
- downsampling;
- metadata stripping;
- result screen reale.

Deliverable:

- JPEG/PNG/HEIC input;
- JPEG output;
- target size realistico.

### Fase 3 — PDF engine

Obiettivi:

- PDFKit import/preview;
- euristica scanned/vector;
- raster rebuild per scansioni;
- conservative path per PDF testuali;
- warning chiari.

Deliverable:

- PDF scansionati compressi;
- PDF testuali protetti da warning.

### Fase 4 — Video engine

Obiettivi:

- AVAssetExportSession;
- preset automatici;
- progress/cancel;
- MP4 output;
- warnings HDR/metadata.

Deliverable:

- video compressi in locale.

### Fase 5 — Share Extension

Obiettivi:

- App Group;
- import da Share Sheet;
- manifest JSON;
- handoff ad app principale.

Deliverable:

- compressione partendo da Share Sheet.

### Fase 6 — Polish + monetizzazione

Obiettivi:

- StoreKit 2;
- paywall lifetime;
- localization;
- accessibility;
- tests;
- privacy copy;
- App Store screenshots.

---

## 20. Prompt operativo per Codex

Usare questo prompt come istruzione iniziale nel repository:

```text
You are implementing Local File Diet, a professional iPhone-only SwiftUI utility that compresses images, PDFs and videos entirely on-device. There is no backend, no account system, no upload, and no tracking. Prioritize correctness, local privacy, file safety, cancellable async operations, and a minimal polished UI.

Follow the specification in local-file-diet-codex-spec.md exactly. Use native Apple frameworks first: SwiftUI, UniformTypeIdentifiers, ImageIO, PDFKit, AVFoundation, PhotosUI, StoreKit 2, os.Logger. Keep the architecture modular: UI/ViewModels must not contain compression algorithms. Implement compression engines behind protocols. Preserve originals. Write outputs to temporary/cache locations and expose explicit share/save actions.

Start with a compiling app skeleton, then implement image compression, then PDF compression, then video compression, then Share Extension. Add tests for each engine and edge case. Avoid overengineering and avoid dependencies unless the spec explicitly allows them.
```

---

## 21. Definizione di “done” per prima release pubblicabile

La prima release è pubblicabile quando:

- l'app comprime immagini in modo affidabile sotto target realistici;
- l'app comprime PDF scansionati in modo utile;
- l'app comprime video con preset locali;
- import da Files e Photos funziona;
- Share Extension funziona almeno per file singolo;
- output si può condividere e salvare;
- non c'è traffico di rete per funzioni core;
- UI è stabile, minimal e localizzata almeno EN/IT;
- non ci sono crash noti su file corrotti/protetti;
- l'app è utilizzabile in Airplane Mode;
- App Privacy Label può essere compilata coerentemente con “nessun dato raccolto”, se non vengono aggiunti SDK esterni.

---

## 22. Anti-requisiti

Non implementare nella prima release:

- account utente;
- cloud sync;
- compressione server-side;
- AI generativa;
- social feed;
- file manager completo;
- scanner documenti completo;
- OCR;
- editing PDF avanzato;
- editing video avanzato;
- analytics invasive;
- abbonamento obbligatorio;
- supporto iPad dedicato;
- widget non essenziali;
- onboarding lungo.

---

## 23. Note finali per l'agente

Questa app vince solo se è più veloce del workflow manuale e più affidabile dei tool generici. Ogni scelta tecnica deve rispondere a tre domande:

1. Il file resta locale?
2. L'utente capisce cosa succede?
3. Il risultato è più piccolo senza distruggere inutilmente la qualità?

Se una feature non migliora una di queste tre cose, rimandarla.
