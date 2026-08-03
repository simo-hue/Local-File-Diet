#!/usr/bin/env python3
"""
Generate the static site in docs/ from one source of truth.

This is OPTIONAL tooling. The site itself has no build step: docs/ contains
plain HTML that GitHub Pages serves directly. This script exists only so the
shared header/footer and the four language versions cannot drift apart.

    python3 Scripts/build_site.py

Regenerates: index/support in en, it, es, de + privacy, terms, 404 (en only),
plus sitemap.xml. Never touches assets/.
"""
import json
import os

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs")
SITE = "https://simo-hue.github.io/Local-File-Diet"
APPSTORE = "https://apps.apple.com/app/id6773253471"
APPID = "6773253471"
ASSET_V = "3"
EFFECTIVE = "26 May 2026"

LANGS = ["en", "it", "es", "de"]
BADGE = {"en": "en-us", "it": "it-it", "es": "es-es", "de": "de-de"}

MARK = (
    '<svg class="brand-mark" viewBox="0 0 24 24" fill="none" aria-hidden="true">'
    '<path class="jaw" d="M8 4H4.5v16H8M16 4h3.5v16H16" stroke-width="1.7" stroke-linecap="square"/>'
    '<path class="target" d="M12 7.5v9" stroke-width="1.7" stroke-linecap="square"/>'
    "</svg>"
)

TICK = (
    '<svg class="claim-tick" viewBox="0 0 24 24" fill="none" aria-hidden="true">'
    '<path d="M4 12.5l5 5L20 6.5" stroke="currentColor" stroke-width="1.9" stroke-linecap="square"/></svg>'
)

# --------------------------------------------------------------------------
# Strings
# --------------------------------------------------------------------------
T = {}

T["en"] = {
    "locale": "en",
    "nav": ["Overview", "Privacy", "Support", "Terms"],
    "badge_alt": "Download Local File Diet on the App Store",
    "skip": "Skip to content",
    "lang_label": "Language",

    "idx_title": "Local File Diet — Compress files to an exact size, on your iPhone",
    "idx_desc": "Compress videos, PDFs, images and archives to the exact size a form or mailbox demands. Everything runs on your iPhone: no uploads, no account, no tracking.",
    "og_title": "Local File Diet — Compress files to an exact size",
    "og_desc": "Videos, PDFs, images and archives, compressed to the number you need. Entirely on your iPhone.",

    "hero_eyebrow": "iPhone · Utilities",
    "hero_h1": "Land on the exact size you need.",
    "hero_lead": "Videos, PDFs, images and archives, compressed to the number a form or a mailbox demands — computed entirely on your iPhone.",
    "hero_notes": ["iOS 17+", "iPhone", "Pay once", "No subscription"],
    "shot_result_alt": "The result screen in Local File Diet, showing a compressed file and its new size.",
    "shot_batch_alt": "The batch result screen listing several compressed files.",
    "shot_review_alt": "The review screen showing a chosen target size and the estimated plan.",

    "spec": [("Processing", "On-device"), ("Network use", "None"),
             ("Account", "Not required"), ("Formats", "Video · PDF · Image · ZIP")],

    "rail_precision": "Precision",
    "prec_h2": "Set a target. It lands inside it.",
    "prec_p": "Most compressors give you “low, medium, high” and let you find out afterwards. Local File Diet works the other way round: you name the size, and it solves for the settings that reach it — a resolution ladder and bitrate calculation for video, per-page analysis for PDFs.",
    "seg": ["Video", "PDF", "Image"],
    "seg_label": "File type",
    "disclaim": "Illustrative — modelled, not measured",
    "ro": ["Original", "Target", "Result", "Reduction"],
    "cap_full": "Full range",
    "cap_detail": "Landing detail",
    "legend_limit": "Limit",
    "slider_lab": "Target size",
    "msg_ok": "Lands at {result}, inside the {target} limit. The shaded window is the ≈4% band the app aims for in a single pass.",
    "msg_over": "Target is the original size — nothing to do. The app tells you when a file is already small enough instead of recompressing it.",

    "rail_formats": "Formats",
    "fmt_h2": "Four file types, four different jobs.",
    "fmt_p": "Each format gets an approach built for it, rather than one generic quality slider applied to everything.",
    "formats": [
        ("Video", 'Steps down a <b>resolution ladder</b> and solves for the bitrate that reaches your number. Targets land within about <b>4% in a single pass</b>.',
         ["MOV · MP4 · M4V", "Resolution ladder", "Single-pass bitrate solve"]),
        ("PDF", 'Recompresses image-heavy pages and <b>leaves the text layer alone</b>, so the document stays selectable and searchable.',
         ["Scanned &amp; mixed documents", "Text stays selectable", "Warns before flattening"]),
        ("Image", 'Strips metadata, <b>keeps transparency intact</b>, and downsamples only as far as the target actually requires.',
         ["JPEG · PNG · HEIC/HEIF · TIFF", "Alpha channel preserved", "Metadata removed"]),
        ("Archive", 'Packs a finished batch into <b>one ZIP on the device</b> — useful when a portal wants a single attachment.',
         ["Local ZIP creation", "Batch output", "Nothing uploaded"]),
    ],

    "rail_through": "Throughput",
    "thr_h2": "Built for a folder, not just a file.",
    "thr": [
        ("Compress a whole selection",
         "Pick several files at once and run them through in one pass. Save them individually, or pack the finished batch straight into a single ZIP.",
         ["Mixed types", "One target", "ZIP output"], "batch"),
        ("Start from the share sheet",
         "Send a file straight in from Mail, Messages, Files or any other app. You do not have to open Local File Diet first, and the original stays where it was.",
         ["Share extension", "No app switch", "Original untouched"], "review"),
    ],

    "rail_privacy": "Privacy",
    "priv_h2": "Nothing to upload, so nothing to leak.",
    "priv_p": "Compression runs on your iPhone using the frameworks already in iOS. There is no server in the loop, which means there is no queue, no file-size cap, and no copy of your document sitting on someone else’s disk.",
    "claims": [
        ("Files stay on the device", "They leave only when you choose to share, save or export the result yourself.", "On-device"),
        ("No account, no sign-in", "Install it and use it. There is nothing to register and no email to hand over.", "Not required"),
        ("No analytics or tracking SDKs", "No advertising identifiers, no usage telemetry, no third-party frameworks watching.", "None"),
        ("Originals are never modified", "The app works from a temporary copy and writes a new file alongside it.", "Preserved"),
        ("Local history you can clear", "Recent-compression details stay on the phone and can be wiped from settings.", "Clearable"),
    ],
    "nutrition_k": "App Store privacy label",
    "nutrition_v": "Data Not Collected",
    "nutrition_p": "Apple’s own summary of what this app gathers about you.",

    "rail_how": "How it works",
    "how_h2": "Three steps, start to finish.",
    "steps": [
        ("Bring in a file", "Pick from Files or Photos, or send something in from the iOS share sheet."),
        ("Name the size", "Choose 25, 10 or 5 MB, or type the exact number the form is asking for, in MB or KB."),
        ("Compress and send", "Share the result, save it to Files or Photos, or pack a whole batch into one ZIP."),
    ],

    "closer_h2": "Get under the limit.",
    "closer_lead": "Local File Diet is on the App Store for iPhone, running iOS 17 or later.",
    "closer_notes": ["Pay once", "No subscription", "No account", "No ads"],

    "foot_tagline": "Compress videos, PDFs, images and archives to an exact size — privately, on your iPhone.",
    "foot_product": "Product",
    "foot_legal": "Help &amp; legal",
    "foot_links_product": [("How targeting works", "#precision"), ("Privacy design", "#privacy"), ("App Store", APPSTORE)],
    "foot_links_legal": [("Support", "support.html"), ("Privacy policy", "privacy.html"), ("Terms of use", "terms.html")],
    "foot_made": "Made for iPhone · No trackers on this site",
    "dock_sub": "Compress to an exact size",

    # ---- support page
    "sup_title": "Support — Local File Diet",
    "sup_desc": "Help, troubleshooting and contact for Local File Diet.",
    "sup_eyebrow": "Support",
    "sup_h1": "Help with Local File Diet",
    "sup_lead": "Questions about how compression behaves, bug reports, or anything about privacy — here is how to reach a human.",
    "sup_meta": ["Version 2.0", "iOS 17 or later", "iPhone"],
    "contact": [
        ("Email", "Write to me directly", "Best for anything involving your own files, an account question, or a privacy request. Nothing you send becomes public.", "simone.mattioli@iite.eu", "mailto:simone.mattioli@iite.eu"),
        ("Bug reports", "Open a GitHub issue", "Best for reproducible bugs and feature requests. Issues are public — never attach private documents or screenshots containing personal data.", "github.com/simo-hue/Local-File-Diet", "https://github.com/simo-hue/Local-File-Diet/issues"),
    ],
    "contact_rail": "Contact",
    "e404_eyebrow": "Not found",
    "faq_rail": "Common questions",
    "faq_h2": "Before you write in.",
    "faq": [
        ("Why did my file barely get smaller?",
         ["Some files are already compressed as far as they usefully go — an H.264 video exported at a low bitrate, or a PDF that is mostly text, has little left to remove.",
          "When a target is not reachable without visible damage, the app says so rather than producing a file that looks broken."]),
        ("Are my files uploaded anywhere?",
         ["No. Compression runs on your iPhone. There is no server involved, and the app works with no network connection at all.",
          "Files leave the device only when you choose to share, save or export the result yourself."]),
        ("Will the app change my original file?",
         ["No. Local File Diet copies your selection into a temporary workspace and writes a new compressed file. The original is left exactly as it was."]),
        ("Why can a compressed PDF lose selectable text?",
         ["Aggressive PDF compression can rebuild pages as flat images, which is sometimes the only way to hit a small target on a scanned document.",
          "The app warns you before taking that route, because it also removes links, form fields and annotations."]),
        ("How do I remove local data?",
         ["Clear temporary files from the app settings, clear recent history from the home screen, and delete any exported files wherever you saved them.",
          "Deleting the app removes everything it stored on the device."]),
        ("Is there a subscription?",
         ["No. Local File Diet is a one-time purchase with no subscription, no account and no in-app purchases. Every feature is unlocked from the start."]),
    ],

    # ---- legal shared
    "legal_effective": "Effective date",
    "toc_title": "On this page",
    "priv_title": "Privacy Policy — Local File Diet",
    "priv_desc": "Privacy Policy for Local File Diet, a local-first iPhone file compression app.",
    "terms_title": "Terms of Use — Local File Diet",
    "terms_desc": "Terms of Use for Local File Diet.",

    # ---- 404
    "e404_title": "Page not found — Local File Diet",
    "e404_h1": "This page does not exist.",
    "e404_p": "The link may be out of date, or the address may have a typo in it.",
    "e404_btn": "Back to the overview",
    "e404_sup": "Go to support",
}

T["it"] = dict(T["en"], **{
    "locale": "it",
    "nav": ["Panoramica", "Privacy", "Supporto", "Termini"],
    "badge_alt": "Scarica Local File Diet su App Store",
    "skip": "Vai al contenuto",
    "lang_label": "Lingua",

    "idx_title": "Local File Diet — Comprimi i file alla dimensione esatta, su iPhone",
    "idx_desc": "Comprimi video, PDF, immagini e archivi alla dimensione esatta richiesta da un modulo o da una casella di posta. Tutto avviene su iPhone: nessun caricamento, nessun account, nessun tracciamento.",
    "og_title": "Local File Diet — Comprimi i file alla dimensione esatta",
    "og_desc": "Video, PDF, immagini e archivi, compressi alla dimensione che ti serve. Interamente sul tuo iPhone.",

    "hero_eyebrow": "iPhone · Utility",
    "hero_h1": "Arriva alla dimensione esatta.",
    "hero_lead": "Video, PDF, immagini e archivi, compressi alla dimensione richiesta da un modulo o da una email — calcolata interamente sul tuo iPhone.",
    "hero_notes": ["iOS 17+", "iPhone", "Paghi una volta", "Nessun abbonamento"],
    "shot_result_alt": "La schermata del risultato in Local File Diet, con il file compresso e la nuova dimensione.",
    "shot_batch_alt": "La schermata del risultato multiplo con l’elenco dei file compressi.",
    "shot_review_alt": "La schermata di revisione con la dimensione obiettivo e il piano stimato.",

    "spec": [("Elaborazione", "Sul dispositivo"), ("Uso della rete", "Nessuno"),
             ("Account", "Non richiesto"), ("Formati", "Video · PDF · Foto · ZIP")],

    "rail_precision": "Precisione",
    "prec_h2": "Imposti un obiettivo. Il file ci rientra.",
    "prec_p": "La maggior parte dei compressori offre “bassa, media, alta” e ti lascia scoprire il risultato dopo. Local File Diet fa il contrario: indichi la dimensione e l’app calcola le impostazioni per raggiungerla — scala di risoluzione e calcolo del bitrate per i video, analisi pagina per pagina per i PDF.",
    "seg": ["Video", "PDF", "Immagine"],
    "seg_label": "Tipo di file",
    "disclaim": "Illustrativo — simulato, non misurato",
    "ro": ["Originale", "Obiettivo", "Risultato", "Riduzione"],
    "cap_full": "Intervallo completo",
    "cap_detail": "Dettaglio di arrivo",
    "legend_limit": "Limite",
    "slider_lab": "Dimensione obiettivo",
    "msg_ok": "Arriva a {result}, entro il limite di {target}. La fascia evidenziata è il margine di circa il 4% che l’app punta a ottenere in un solo passaggio.",
    "msg_over": "L’obiettivo coincide con la dimensione originale: non c’è nulla da fare. L’app ti avvisa quando un file è già abbastanza piccolo invece di ricomprimerlo.",

    "rail_formats": "Formati",
    "fmt_h2": "Quattro tipi di file, quattro lavori diversi.",
    "fmt_p": "Ogni formato riceve un approccio pensato per lui, invece di un unico cursore di qualità applicato a tutto.",
    "formats": [
        ("Video", 'Scende lungo una <b>scala di risoluzione</b> e calcola il bitrate necessario per raggiungere la dimensione indicata. Gli obiettivi vengono centrati entro circa il <b>4% in un solo passaggio</b>.',
         ["MOV · MP4 · M4V", "Scala di risoluzione", "Calcolo bitrate in un passaggio"]),
        ("PDF", 'Ricomprime le pagine ricche di immagini e <b>lascia intatto il livello di testo</b>, così il documento resta selezionabile e ricercabile.',
         ["Documenti scansionati e misti", "Il testo resta selezionabile", "Avvisa prima di appiattire"]),
        ("Immagini", 'Rimuove i metadati, <b>preserva la trasparenza</b> e riduce le dimensioni solo quanto serve per raggiungere l’obiettivo.',
         ["JPEG · PNG · HEIC/HEIF · TIFF", "Canale alfa preservato", "Metadati rimossi"]),
        ("Archivi", 'Raccoglie un lotto completato in <b>un unico ZIP sul dispositivo</b> — utile quando un portale accetta un solo allegato.',
         ["Creazione ZIP locale", "Output multiplo", "Nessun caricamento"]),
    ],

    "rail_through": "Produttività",
    "thr_h2": "Pensato per una cartella, non per un solo file.",
    "thr": [
        ("Comprimi un’intera selezione",
         "Scegli più file insieme ed elaborali in un solo passaggio. Salvali singolarmente oppure impacchetta il lotto finito direttamente in un unico ZIP.",
         ["Tipi misti", "Un obiettivo", "Output ZIP"], "batch"),
        ("Parti dal menu di condivisione",
         "Invia un file direttamente da Mail, Messaggi, File o da qualsiasi altra app. Non devi aprire prima Local File Diet e l’originale resta dov’era.",
         ["Estensione di condivisione", "Nessun cambio di app", "Originale intatto"], "review"),
    ],

    "rail_privacy": "Privacy",
    "priv_h2": "Niente da caricare, quindi niente da esporre.",
    "priv_p": "La compressione avviene sul tuo iPhone usando i framework già presenti in iOS. Non c’è alcun server nel processo: niente code, nessun limite di dimensione e nessuna copia dei tuoi documenti sul disco di qualcun altro.",
    "claims": [
        ("I file restano sul dispositivo", "Escono solo quando scegli tu di condividere, salvare o esportare il risultato.", "Sul dispositivo"),
        ("Nessun account, nessun accesso", "Installi e usi. Non c’è nulla da registrare e nessuna email da fornire.", "Non richiesto"),
        ("Nessun SDK di analisi o tracciamento", "Nessun identificatore pubblicitario, nessuna telemetria d’uso, nessun framework di terze parti.", "Nessuno"),
        ("Gli originali non vengono mai modificati", "L’app lavora su una copia temporanea e crea un nuovo file accanto all’originale.", "Preservati"),
        ("Cronologia locale cancellabile", "I dettagli delle compressioni recenti restano sul telefono e si possono eliminare dalle impostazioni.", "Cancellabile"),
    ],
    "nutrition_k": "Etichetta privacy App Store",
    "nutrition_v": "Nessun dato raccolto",
    "nutrition_p": "Il riepilogo di Apple su ciò che questa app raccoglie su di te.",

    "rail_how": "Come funziona",
    "how_h2": "Tre passaggi, dall’inizio alla fine.",
    "steps": [
        ("Aggiungi un file", "Scegli da File o Foto, oppure invialo dal menu di condivisione di iOS."),
        ("Indica la dimensione", "Scegli 25, 10 o 5 MB, oppure digita il valore esatto richiesto dal modulo, in MB o KB."),
        ("Comprimi e invia", "Condividi il risultato, salvalo in File o Foto, o raccogli un intero lotto in un unico ZIP."),
    ],

    "closer_h2": "Rientra nel limite.",
    "closer_lead": "Local File Diet è su App Store per iPhone, con iOS 17 o successivo.",
    "closer_notes": ["Paghi una volta", "Nessun abbonamento", "Nessun account", "Nessuna pubblicità"],

    "foot_tagline": "Comprimi video, PDF, immagini e archivi alla dimensione esatta — in privato, sul tuo iPhone.",
    "foot_product": "Prodotto",
    "foot_legal": "Aiuto e note legali",
    "foot_links_product": [("Come funziona l’obiettivo", "#precision"), ("Progettazione privacy", "#privacy"), ("App Store", APPSTORE)],
    "foot_links_legal": [("Supporto", "support.html"), ("Informativa privacy", "../privacy.html"), ("Termini d’uso", "../terms.html")],
    "foot_made": "Realizzata per iPhone · Nessun tracciamento su questo sito",
    "dock_sub": "Comprimi alla dimensione esatta",

    "sup_title": "Supporto — Local File Diet",
    "sup_desc": "Aiuto, risoluzione dei problemi e contatti per Local File Diet.",
    "sup_eyebrow": "Supporto",
    "sup_h1": "Assistenza per Local File Diet",
    "sup_lead": "Domande sul comportamento della compressione, segnalazioni di bug o dubbi sulla privacy: ecco come parlare con una persona.",
    "sup_meta": ["Versione 2.0", "iOS 17 o successivo", "iPhone"],
    "contact": [
        ("Email", "Scrivimi direttamente", "Ideale per tutto ciò che riguarda i tuoi file, domande sull’acquisto o richieste sulla privacy. Nulla di ciò che invii diventa pubblico.", "simone.mattioli@iite.eu", "mailto:simone.mattioli@iite.eu"),
        ("Segnalazioni", "Apri una issue su GitHub", "Ideale per bug riproducibili e richieste di funzionalità. Le issue sono pubbliche: non allegare documenti privati o screenshot con dati personali.", "github.com/simo-hue/Local-File-Diet", "https://github.com/simo-hue/Local-File-Diet/issues"),
    ],
    "contact_rail": "Contatti",
    "e404_eyebrow": "Non trovata",
    "faq_rail": "Domande frequenti",
    "faq_h2": "Prima di scrivere.",
    "faq": [
        ("Perché il file si è ridotto così poco?",
         ["Alcuni file sono già compressi al massimo utile: un video H.264 esportato a bitrate basso, o un PDF composto quasi solo da testo, hanno poco da rimuovere.",
          "Quando un obiettivo non è raggiungibile senza danni visibili, l’app te lo dice invece di produrre un file rovinato."]),
        ("I miei file vengono caricati da qualche parte?",
         ["No. La compressione avviene sul tuo iPhone. Non c’è alcun server e l’app funziona anche senza connessione.",
          "I file lasciano il dispositivo solo quando scegli tu di condividere, salvare o esportare il risultato."]),
        ("L’app modifica il file originale?",
         ["No. Local File Diet copia la selezione in un’area temporanea e crea un nuovo file compresso. L’originale resta esattamente com’era."]),
        ("Perché un PDF compresso può perdere il testo selezionabile?",
         ["Una compressione aggressiva può ricostruire le pagine come immagini piatte: a volte è l’unico modo per raggiungere un obiettivo ridotto su un documento scansionato.",
          "L’app ti avvisa prima di procedere, perché questa strada rimuove anche link, campi modulo e annotazioni."]),
        ("Come rimuovo i dati locali?",
         ["Elimina i file temporanei dalle impostazioni dell’app, cancella la cronologia recente dalla schermata iniziale ed elimina i file esportati dove li hai salvati.",
          "Disinstallando l’app viene rimosso tutto ciò che aveva salvato sul dispositivo."]),
        ("Esiste un abbonamento?",
         ["No. Local File Diet è un acquisto unico, senza abbonamenti, senza account e senza acquisti in-app. Tutte le funzioni sono disponibili da subito."]),
    ],

    "e404_title": "Pagina non trovata — Local File Diet",
    "e404_h1": "Questa pagina non esiste.",
    "e404_p": "Il link potrebbe non essere più valido, oppure l’indirizzo contiene un errore.",
    "e404_btn": "Torna alla panoramica",
    "e404_sup": "Vai al supporto",
})

T["es"] = dict(T["en"], **{
    "locale": "es",
    "nav": ["Resumen", "Privacidad", "Soporte", "Términos"],
    "badge_alt": "Descarga Local File Diet en el App Store",
    "skip": "Ir al contenido",
    "lang_label": "Idioma",

    "idx_title": "Local File Diet — Comprime archivos al tamaño exacto, en tu iPhone",
    "idx_desc": "Comprime vídeos, PDF, imágenes y archivos al tamaño exacto que exige un formulario o un correo. Todo ocurre en tu iPhone: sin subidas, sin cuenta, sin rastreo.",
    "og_title": "Local File Diet — Comprime archivos al tamaño exacto",
    "og_desc": "Vídeos, PDF, imágenes y archivos, comprimidos al tamaño que necesitas. Íntegramente en tu iPhone.",

    "hero_eyebrow": "iPhone · Utilidades",
    "hero_h1": "Llega al tamaño exacto.",
    "hero_lead": "Vídeos, PDF, imágenes y archivos, comprimidos al tamaño que pide un formulario o un buzón de correo — calculado íntegramente en tu iPhone.",
    "hero_notes": ["iOS 17+", "iPhone", "Pago único", "Sin suscripción"],
    "shot_result_alt": "La pantalla de resultado de Local File Diet, con el archivo comprimido y su nuevo tamaño.",
    "shot_batch_alt": "La pantalla de resultado por lotes con la lista de archivos comprimidos.",
    "shot_review_alt": "La pantalla de revisión con el tamaño objetivo elegido y el plan estimado.",

    "spec": [("Procesamiento", "En el dispositivo"), ("Uso de red", "Ninguno"),
             ("Cuenta", "No necesaria"), ("Formatos", "Vídeo · PDF · Imagen · ZIP")],

    "rail_precision": "Precisión",
    "prec_h2": "Fija un objetivo. El archivo entra en él.",
    "prec_p": "La mayoría de los compresores ofrecen “baja, media, alta” y te dejan descubrir el resultado después. Local File Diet funciona al revés: indicas el tamaño y la app calcula los ajustes para alcanzarlo — escala de resolución y cálculo de tasa de bits para vídeo, análisis página a página para PDF.",
    "seg": ["Vídeo", "PDF", "Imagen"],
    "seg_label": "Tipo de archivo",
    "disclaim": "Ilustrativo — simulado, no medido",
    "ro": ["Original", "Objetivo", "Resultado", "Reducción"],
    "cap_full": "Rango completo",
    "cap_detail": "Detalle de llegada",
    "legend_limit": "Límite",
    "slider_lab": "Tamaño objetivo",
    "msg_ok": "Llega a {result}, dentro del límite de {target}. La franja sombreada es el margen de aproximadamente el 4% que la app busca en una sola pasada.",
    "msg_over": "El objetivo coincide con el tamaño original: no hay nada que hacer. La app te avisa cuando un archivo ya es lo bastante pequeño en lugar de recomprimirlo.",

    "rail_formats": "Formatos",
    "fmt_h2": "Cuatro tipos de archivo, cuatro trabajos distintos.",
    "fmt_p": "Cada formato recibe un enfoque pensado para él, en lugar de un único control de calidad aplicado a todo.",
    "formats": [
        ("Vídeo", 'Baja por una <b>escala de resolución</b> y calcula la tasa de bits necesaria para alcanzar tu cifra. Los objetivos se cumplen con un margen de aproximadamente el <b>4% en una sola pasada</b>.',
         ["MOV · MP4 · M4V", "Escala de resolución", "Cálculo de tasa en una pasada"]),
        ("PDF", 'Recomprime las páginas con muchas imágenes y <b>deja intacta la capa de texto</b>, de modo que el documento sigue siendo seleccionable y buscable.',
         ["Documentos escaneados y mixtos", "El texto sigue seleccionable", "Avisa antes de aplanar"]),
        ("Imágenes", 'Elimina los metadatos, <b>conserva la transparencia</b> y reduce la resolución solo lo que el objetivo realmente exige.',
         ["JPEG · PNG · HEIC/HEIF · TIFF", "Canal alfa conservado", "Metadatos eliminados"]),
        ("Archivos", 'Empaqueta un lote terminado en <b>un solo ZIP en el dispositivo</b> — útil cuando un portal admite un único adjunto.',
         ["Creación de ZIP local", "Salida por lotes", "Sin subidas"]),
    ],

    "rail_through": "Rendimiento",
    "thr_h2": "Pensado para una carpeta, no solo para un archivo.",
    "thr": [
        ("Comprime una selección entera",
         "Elige varios archivos a la vez y procésalos en una sola pasada. Guárdalos por separado o empaqueta el lote terminado directamente en un único ZIP.",
         ["Tipos mixtos", "Un objetivo", "Salida ZIP"], "batch"),
        ("Empieza desde el menú de compartir",
         "Envía un archivo directamente desde Mail, Mensajes, Archivos o cualquier otra app. No necesitas abrir antes Local File Diet y el original se queda donde estaba.",
         ["Extensión de compartir", "Sin cambiar de app", "Original intacto"], "review"),
    ],

    "rail_privacy": "Privacidad",
    "priv_h2": "Nada que subir, así que nada que filtrar.",
    "priv_p": "La compresión se ejecuta en tu iPhone con los frameworks que ya incluye iOS. No hay ningún servidor de por medio: sin colas, sin límite de tamaño y sin copias de tus documentos en el disco de otra persona.",
    "claims": [
        ("Los archivos se quedan en el dispositivo", "Solo salen cuando tú decides compartir, guardar o exportar el resultado.", "En el dispositivo"),
        ("Sin cuenta, sin inicio de sesión", "Instalar y usar. No hay nada que registrar ni ningún correo que facilitar.", "No necesaria"),
        ("Sin SDK de analítica ni de rastreo", "Sin identificadores publicitarios, sin telemetría de uso, sin frameworks de terceros observando.", "Ninguno"),
        ("Los originales nunca se modifican", "La app trabaja sobre una copia temporal y crea un archivo nuevo junto al original.", "Conservados"),
        ("Historial local que puedes borrar", "Los detalles de las compresiones recientes se quedan en el teléfono y se pueden borrar desde los ajustes.", "Borrable"),
    ],
    "nutrition_k": "Etiqueta de privacidad del App Store",
    "nutrition_v": "No se recopilan datos",
    "nutrition_p": "El resumen de Apple sobre lo que esta app recopila de ti.",

    "rail_how": "Cómo funciona",
    "how_h2": "Tres pasos, de principio a fin.",
    "steps": [
        ("Añade un archivo", "Elige desde Archivos o Fotos, o envíalo desde el menú de compartir de iOS."),
        ("Indica el tamaño", "Elige 25, 10 o 5 MB, o escribe la cifra exacta que pide el formulario, en MB o KB."),
        ("Comprime y envía", "Comparte el resultado, guárdalo en Archivos o Fotos, o empaqueta todo un lote en un ZIP."),
    ],

    "closer_h2": "Entra en el límite.",
    "closer_lead": "Local File Diet está en el App Store para iPhone, con iOS 17 o posterior.",
    "closer_notes": ["Pago único", "Sin suscripción", "Sin cuenta", "Sin anuncios"],

    "foot_tagline": "Comprime vídeos, PDF, imágenes y archivos al tamaño exacto — en privado, en tu iPhone.",
    "foot_product": "Producto",
    "foot_legal": "Ayuda y aspectos legales",
    "foot_links_product": [("Cómo funciona el objetivo", "#precision"), ("Diseño de privacidad", "#privacy"), ("App Store", APPSTORE)],
    "foot_links_legal": [("Soporte", "support.html"), ("Política de privacidad", "../privacy.html"), ("Términos de uso", "../terms.html")],
    "foot_made": "Hecha para iPhone · Sin rastreadores en este sitio",
    "dock_sub": "Comprime al tamaño exacto",

    "sup_title": "Soporte — Local File Diet",
    "sup_desc": "Ayuda, resolución de problemas y contacto para Local File Diet.",
    "sup_eyebrow": "Soporte",
    "sup_h1": "Ayuda con Local File Diet",
    "sup_lead": "Dudas sobre cómo se comporta la compresión, informes de fallos o cualquier cuestión de privacidad: así puedes hablar con una persona.",
    "sup_meta": ["Versión 2.0", "iOS 17 o posterior", "iPhone"],
    "contact": [
        ("Correo", "Escríbeme directamente", "Lo mejor para cualquier cosa relacionada con tus archivos, con la compra o con una petición de privacidad. Nada de lo que envíes se hace público.", "simone.mattioli@iite.eu", "mailto:simone.mattioli@iite.eu"),
        ("Informes de fallos", "Abre una incidencia en GitHub", "Lo mejor para fallos reproducibles y peticiones de funciones. Las incidencias son públicas: nunca adjuntes documentos privados ni capturas con datos personales.", "github.com/simo-hue/Local-File-Diet", "https://github.com/simo-hue/Local-File-Diet/issues"),
    ],
    "contact_rail": "Contacto",
    "e404_eyebrow": "No encontrada",
    "faq_rail": "Preguntas frecuentes",
    "faq_h2": "Antes de escribir.",
    "faq": [
        ("¿Por qué mi archivo apenas se ha reducido?",
         ["Algunos archivos ya están comprimidos todo lo que resulta útil: un vídeo H.264 exportado con tasa baja, o un PDF casi todo texto, tienen poco que quitar.",
          "Cuando un objetivo no se puede alcanzar sin daños visibles, la app te lo dice en lugar de producir un archivo estropeado."]),
        ("¿Se suben mis archivos a algún sitio?",
         ["No. La compresión se ejecuta en tu iPhone. No hay ningún servidor y la app funciona incluso sin conexión.",
          "Los archivos salen del dispositivo solo cuando tú decides compartir, guardar o exportar el resultado."]),
        ("¿La app modifica mi archivo original?",
         ["No. Local File Diet copia tu selección en un espacio temporal y crea un archivo comprimido nuevo. El original se queda tal cual estaba."]),
        ("¿Por qué un PDF comprimido puede perder el texto seleccionable?",
         ["Una compresión agresiva puede reconstruir las páginas como imágenes planas, que a veces es la única forma de alcanzar un objetivo pequeño en un documento escaneado.",
          "La app te avisa antes de tomar ese camino, porque también elimina enlaces, campos de formulario y anotaciones."]),
        ("¿Cómo elimino los datos locales?",
         ["Borra los archivos temporales desde los ajustes de la app, limpia el historial reciente desde la pantalla de inicio y elimina los archivos exportados donde los hayas guardado.",
          "Al eliminar la app se borra todo lo que hubiera guardado en el dispositivo."]),
        ("¿Hay suscripción?",
         ["No. Local File Diet es una compra única, sin suscripción, sin cuenta y sin compras dentro de la app. Todas las funciones están disponibles desde el principio."]),
    ],

    "e404_title": "Página no encontrada — Local File Diet",
    "e404_h1": "Esta página no existe.",
    "e404_p": "Puede que el enlace esté desactualizado o que la dirección tenga una errata.",
    "e404_btn": "Volver al resumen",
    "e404_sup": "Ir a soporte",
})

T["de"] = dict(T["en"], **{
    "locale": "de",
    "nav": ["Überblick", "Datenschutz", "Support", "Nutzungsbedingungen"],
    "badge_alt": "Local File Diet im App Store laden",
    "skip": "Zum Inhalt springen",
    "lang_label": "Sprache",

    "idx_title": "Local File Diet — Dateien exakt auf Zielgröße komprimieren, auf dem iPhone",
    "idx_desc": "Komprimiere Videos, PDFs, Bilder und Archive exakt auf die Größe, die ein Formular oder Postfach verlangt. Alles läuft auf deinem iPhone: keine Uploads, kein Konto, kein Tracking.",
    "og_title": "Local File Diet — Dateien exakt auf Zielgröße komprimieren",
    "og_desc": "Videos, PDFs, Bilder und Archive, komprimiert auf die Größe, die du brauchst. Vollständig auf deinem iPhone.",

    "hero_eyebrow": "iPhone · Dienstprogramme",
    "hero_h1": "Genau die Zielgröße treffen.",
    "hero_lead": "Videos, PDFs, Bilder und Archive, komprimiert auf die Größe, die ein Formular oder Postfach verlangt — vollständig auf deinem iPhone berechnet.",
    "hero_notes": ["iOS 17+", "iPhone", "Einmal zahlen", "Kein Abo"],
    "shot_result_alt": "Der Ergebnisbildschirm von Local File Diet mit der komprimierten Datei und ihrer neuen Größe.",
    "shot_batch_alt": "Der Stapel-Ergebnisbildschirm mit der Liste der komprimierten Dateien.",
    "shot_review_alt": "Der Prüfbildschirm mit gewählter Zielgröße und geschätztem Plan.",

    "spec": [("Verarbeitung", "Auf dem Gerät"), ("Netzwerknutzung", "Keine"),
             ("Konto", "Nicht nötig"), ("Formate", "Video · PDF · Bild · ZIP")],

    "rail_precision": "Präzision",
    "prec_h2": "Zielgröße festlegen. Die Datei bleibt darunter.",
    "prec_p": "Die meisten Kompressoren bieten „niedrig, mittel, hoch“ und lassen dich das Ergebnis hinterher herausfinden. Local File Diet macht es umgekehrt: Du nennst die Größe, und die App berechnet die Einstellungen, die sie erreichen — Auflösungsleiter und Bitratenberechnung für Video, seitenweise Analyse für PDFs.",
    "seg": ["Video", "PDF", "Bild"],
    "seg_label": "Dateityp",
    "disclaim": "Beispielhaft — modelliert, nicht gemessen",
    "ro": ["Original", "Zielgröße", "Ergebnis", "Reduktion"],
    "cap_full": "Gesamtbereich",
    "cap_detail": "Ziellandung im Detail",
    "legend_limit": "Grenze",
    "slider_lab": "Zielgröße",
    "msg_ok": "Landet bei {result} und damit unter der Grenze von {target}. Der schattierte Bereich ist die Spanne von etwa 4%, die die App in einem Durchgang anpeilt.",
    "msg_over": "Die Zielgröße entspricht der Originalgröße — hier gibt es nichts zu tun. Die App sagt dir, wenn eine Datei bereits klein genug ist, statt sie erneut zu komprimieren.",

    "rail_formats": "Formate",
    "fmt_h2": "Vier Dateitypen, vier verschiedene Aufgaben.",
    "fmt_p": "Jedes Format bekommt ein eigenes Verfahren statt eines einzigen Qualitätsreglers für alles.",
    "formats": [
        ("Video", 'Geht eine <b>Auflösungsleiter</b> hinunter und berechnet die Bitrate, die deine Zielgröße erreicht. Ziele werden meist mit etwa <b>4% Abweichung in einem Durchgang</b> getroffen.',
         ["MOV · MP4 · M4V", "Auflösungsleiter", "Bitratenberechnung in einem Durchgang"]),
        ("PDF", 'Komprimiert bildlastige Seiten neu und <b>lässt die Textebene unangetastet</b>, sodass das Dokument markierbar und durchsuchbar bleibt.',
         ["Gescannte und gemischte Dokumente", "Text bleibt markierbar", "Warnt vor dem Verflachen"]),
        ("Bilder", 'Entfernt Metadaten, <b>erhält die Transparenz</b> und verkleinert nur so weit, wie die Zielgröße es wirklich verlangt.',
         ["JPEG · PNG · HEIC/HEIF · TIFF", "Alphakanal erhalten", "Metadaten entfernt"]),
        ("Archive", 'Packt einen fertigen Stapel in <b>ein ZIP auf dem Gerät</b> — praktisch, wenn ein Portal nur einen Anhang zulässt.',
         ["Lokale ZIP-Erstellung", "Stapelausgabe", "Keine Uploads"]),
    ],

    "rail_through": "Durchsatz",
    "thr_h2": "Gemacht für einen Ordner, nicht nur für eine Datei.",
    "thr": [
        ("Eine ganze Auswahl komprimieren",
         "Wähle mehrere Dateien auf einmal und verarbeite sie in einem Durchgang. Speichere sie einzeln oder packe den fertigen Stapel direkt in ein einziges ZIP.",
         ["Gemischte Typen", "Eine Zielgröße", "ZIP-Ausgabe"], "batch"),
        ("Aus dem Teilen-Menü starten",
         "Schicke eine Datei direkt aus Mail, Nachrichten, Dateien oder jeder anderen App hinein. Du musst Local File Diet nicht vorher öffnen, und das Original bleibt, wo es war.",
         ["Teilen-Erweiterung", "Kein App-Wechsel", "Original unberührt"], "review"),
    ],

    "rail_privacy": "Datenschutz",
    "priv_h2": "Nichts hochzuladen, also nichts zu verlieren.",
    "priv_p": "Die Kompression läuft auf deinem iPhone mit den Frameworks, die iOS ohnehin mitbringt. Es ist kein Server beteiligt: keine Warteschlange, keine Größenbegrenzung und keine Kopie deines Dokuments auf fremden Festplatten.",
    "claims": [
        ("Dateien bleiben auf dem Gerät", "Sie verlassen es nur, wenn du das Ergebnis selbst teilst, sicherst oder exportierst.", "Auf dem Gerät"),
        ("Kein Konto, keine Anmeldung", "Installieren und benutzen. Es gibt nichts zu registrieren und keine E-Mail-Adresse anzugeben.", "Nicht nötig"),
        ("Keine Analyse- oder Tracking-SDKs", "Keine Werbe-IDs, keine Nutzungstelemetrie, keine Frameworks von Dritten, die mitlesen.", "Keine"),
        ("Originale werden nie verändert", "Die App arbeitet mit einer temporären Kopie und legt eine neue Datei daneben an.", "Erhalten"),
        ("Lokaler Verlauf, den du löschen kannst", "Angaben zu jüngsten Kompressionen bleiben auf dem Gerät und lassen sich in den Einstellungen entfernen.", "Löschbar"),
    ],
    "nutrition_k": "App-Store-Datenschutzlabel",
    "nutrition_v": "Keine Daten erfasst",
    "nutrition_p": "Apples eigene Zusammenfassung dessen, was diese App über dich sammelt.",

    "rail_how": "So funktioniert es",
    "how_h2": "Drei Schritte, von Anfang bis Ende.",
    "steps": [
        ("Datei hinzufügen", "Wähle aus Dateien oder Fotos, oder schicke etwas über das iOS-Teilen-Menü hinein."),
        ("Größe festlegen", "Wähle 25, 10 oder 5 MB, oder tippe den genauen Wert ein, den das Formular verlangt — in MB oder KB."),
        ("Komprimieren und senden", "Teile das Ergebnis, sichere es in Dateien oder Fotos, oder packe einen ganzen Stapel in ein ZIP."),
    ],

    "closer_h2": "Unter die Grenze kommen.",
    "closer_lead": "Local File Diet gibt es im App Store für iPhone ab iOS 17.",
    "closer_notes": ["Einmal zahlen", "Kein Abo", "Kein Konto", "Keine Werbung"],

    "foot_tagline": "Komprimiere Videos, PDFs, Bilder und Archive exakt auf Zielgröße — privat, auf deinem iPhone.",
    "foot_product": "Produkt",
    "foot_legal": "Hilfe &amp; Rechtliches",
    "foot_links_product": [("So funktioniert die Zielgröße", "#precision"), ("Datenschutz-Konzept", "#privacy"), ("App Store", APPSTORE)],
    "foot_links_legal": [("Support", "support.html"), ("Datenschutzerklärung", "../privacy.html"), ("Nutzungsbedingungen", "../terms.html")],
    "foot_made": "Für iPhone gemacht · Keine Tracker auf dieser Website",
    "dock_sub": "Exakt auf Zielgröße komprimieren",

    "sup_title": "Support — Local File Diet",
    "sup_desc": "Hilfe, Fehlerbehebung und Kontakt für Local File Diet.",
    "sup_eyebrow": "Support",
    "sup_h1": "Hilfe zu Local File Diet",
    "sup_lead": "Fragen zum Verhalten der Kompression, Fehlerberichte oder alles rund um den Datenschutz — so erreichst du einen Menschen.",
    "sup_meta": ["Version 2.0", "iOS 17 oder neuer", "iPhone"],
    "contact": [
        ("E-Mail", "Schreib mir direkt", "Am besten für alles, was deine eigenen Dateien, den Kauf oder eine Datenschutzanfrage betrifft. Nichts davon wird öffentlich.", "simone.mattioli@iite.eu", "mailto:simone.mattioli@iite.eu"),
        ("Fehlerberichte", "Öffne ein GitHub-Issue", "Am besten für reproduzierbare Fehler und Funktionswünsche. Issues sind öffentlich — hänge niemals private Dokumente oder Screenshots mit persönlichen Daten an.", "github.com/simo-hue/Local-File-Diet", "https://github.com/simo-hue/Local-File-Diet/issues"),
    ],
    "contact_rail": "Kontakt",
    "e404_eyebrow": "Nicht gefunden",
    "faq_rail": "Häufige Fragen",
    "faq_h2": "Bevor du schreibst.",
    "faq": [
        ("Warum ist meine Datei kaum kleiner geworden?",
         ["Manche Dateien sind bereits so weit komprimiert, wie es sinnvoll ist: ein H.264-Video mit niedriger Bitrate oder ein PDF, das fast nur aus Text besteht, hat wenig zu entfernen.",
          "Wenn eine Zielgröße ohne sichtbare Schäden nicht erreichbar ist, sagt die App das, statt eine ruinierte Datei zu erzeugen."]),
        ("Werden meine Dateien irgendwohin hochgeladen?",
         ["Nein. Die Kompression läuft auf deinem iPhone. Es ist kein Server beteiligt, und die App funktioniert ganz ohne Netzverbindung.",
          "Dateien verlassen das Gerät nur, wenn du das Ergebnis selbst teilst, sicherst oder exportierst."]),
        ("Verändert die App meine Originaldatei?",
         ["Nein. Local File Diet kopiert deine Auswahl in einen temporären Bereich und schreibt eine neue komprimierte Datei. Das Original bleibt unverändert."]),
        ("Warum kann ein komprimiertes PDF markierbaren Text verlieren?",
         ["Starke PDF-Kompression kann Seiten als flache Bilder neu aufbauen — manchmal ist das der einzige Weg, bei einem gescannten Dokument eine kleine Zielgröße zu erreichen.",
          "Die App warnt vorher, denn dabei gehen auch Links, Formularfelder und Anmerkungen verloren."]),
        ("Wie entferne ich lokale Daten?",
         ["Lösche temporäre Dateien in den App-Einstellungen, leere den Verlauf auf dem Startbildschirm und entferne exportierte Dateien dort, wo du sie gespeichert hast.",
          "Beim Löschen der App wird alles entfernt, was sie auf dem Gerät gespeichert hat."]),
        ("Gibt es ein Abo?",
         ["Nein. Local File Diet ist ein einmaliger Kauf ohne Abo, ohne Konto und ohne In-App-Käufe. Alle Funktionen sind von Anfang an freigeschaltet."]),
    ],

    "e404_title": "Seite nicht gefunden — Local File Diet",
    "e404_h1": "Diese Seite gibt es nicht.",
    "e404_p": "Der Link ist möglicherweise veraltet, oder die Adresse enthält einen Tippfehler.",
    "e404_btn": "Zurück zum Überblick",
    "e404_sup": "Zum Support",
})


# --------------------------------------------------------------------------
# Legal content (English only — the authoritative version)
# --------------------------------------------------------------------------
PRIVACY = [
    ("Summary", ["Local File Diet is designed to compress files locally on your iPhone. The app does not require an account, does not upload your files to a server, does not include advertising, and does not track you across apps or websites."]),
    ("Who this policy covers", ["This policy applies to the Local File Diet iOS app and this public website."]),
    ("Data collected by the app", ["The app does not collect personal data for the developer. It does not send file contents, file names, document paths, analytics events, advertising identifiers, or tracking identifiers to the developer."]),
    ("Data processed locally on your device", ["When you choose a file, photo, video, or PDF, the app processes that item on your device to create a compressed output. Local File Diet may create temporary working copies and local compression history metadata so the app can show recent results. This data stays on your device unless you choose to share, export, or save the output yourself."]),
    ("Files, Photos, and permissions", ["The app uses the iOS document picker, Photos picker, share sheet, and save-to-library permission only for actions you start. Selecting a photo or video does not give the app full photo library access. Saving compressed media to Photos happens only when you request it."]),
    ("Payments", ["Local File Diet is sold as a paid upfront App Store app. App Store payments are handled by Apple. The app does not process payment card details and does not include in-app purchases, subscriptions, trials, or runtime purchase accounts."]),
    ("Third-party services", ['The iOS app does not include third-party analytics, advertising SDKs, crash reporting SDKs, or cloud compression services. This website is hosted with GitHub Pages, so GitHub may process standard hosting logs under the <a href="https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement">GitHub Privacy Statement</a>. This website does not set advertising cookies, does not run analytics scripts, and loads no third-party resources of any kind.']),
    ("Sharing", ["The developer does not sell personal data and does not share app data with advertisers or data brokers. Files leave your device only if you choose to export, share, save, or send them through another app or service."]),
    ("Retention and deletion", ["Because the app does not maintain a server account, there is no server-side app profile to delete. You can clear temporary files from the app settings, clear recent history in the app, delete exported files wherever you saved them, or uninstall the app to remove app-local data from your device."]),
    ("Support requests", ['If you contact support by email, your message is used only to answer you. If you contact support through GitHub Issues, your message and GitHub profile information may be public depending on how you submit the issue. Do not upload private documents, screenshots with personal data, or files you do not want to make public.']),
    ("Children", ["Local File Diet is not designed to knowingly collect personal data from children. The app does not create accounts and does not collect developer-accessible user data."]),
    ("Changes to this policy", ["If Local File Diet changes how it handles data, this policy will be updated before those changes are submitted for public release when required."]),
    ("Contact", ['For support, privacy questions, or correction requests, use the <a href="support.html">support page</a> or write to <a href="mailto:simone.mattioli@iite.eu">simone.mattioli@iite.eu</a>.']),
]

TERMS = [
    ("Use of the app", ["Local File Diet is a utility for compressing user-selected files on iPhone. You are responsible for choosing files you have the right to process and for reviewing compressed outputs before sharing, uploading, archiving, or deleting originals elsewhere."]),
    ("Paid access", ["Local File Diet is sold as a paid upfront App Store app. After download, app features are available without subscriptions, trials, accounts, or in-app purchases. App Store purchases, refunds, taxes, and regional availability are handled by Apple under Apple media services terms."]),
    ("No guarantee of compression results", ["Compression results depend on the file type, original quality, metadata, resolution, codec, and target size. Some files are already optimized or cannot be reduced meaningfully without quality loss. The app may warn when a target is unrealistic."]),
    ("Privacy", ['Your use of the app is also covered by the <a href="privacy.html">Privacy Policy</a>, which explains the local-first data handling model.']),
    ("Acceptable use", ["Do not use Local File Diet to process or distribute content that violates applicable law, third-party rights, or platform rules. Do not attempt to misuse the support channels, website, or public issue tracker."]),
    ("Limitation of liability", ["Local File Diet is provided as a utility. To the maximum extent permitted by law, the developer is not responsible for indirect losses, lost files outside the app workflow, rejected uploads on third-party services, or decisions made from compressed outputs without user review."]),
    ("Changes", ["These terms may be updated as the product changes. Continued use after an update means you accept the updated terms where permitted by law."]),
    ("Contact", ['For questions about these terms, use the <a href="support.html">support page</a>.']),
]


# --------------------------------------------------------------------------
# Partials
# --------------------------------------------------------------------------
def head(t, lang, page, title, desc, up, canonical, extra="", alts=True):
    # index pages are addressed as a directory, so hreflang must match canonical
    href_page = "" if page == "index.html" else page
    alt_tags = ""
    if alts:
        alt_tags = "\n".join(
            f'<link rel="alternate" hreflang="{l}" href="{SITE}/{"" if l == "en" else l + "/"}{href_page}">'
            for l in LANGS
        ) + f'\n<link rel="alternate" hreflang="x-default" href="{SITE}/{href_page}">'
    return f"""<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>{title}</title>
<meta name="description" content="{desc}">
<link rel="canonical" href="{canonical}">
{alt_tags}
<meta name="apple-itunes-app" content="app-id={APPID}">
<meta name="theme-color" content="#04090a">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Local File Diet">
<meta property="og:title" content="{t['og_title']}">
<meta property="og:description" content="{t['og_desc']}">
<meta property="og:url" content="{canonical}">
<meta property="og:image" content="{SITE}/assets/og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:locale" content="{t['locale']}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{t['og_title']}">
<meta name="twitter:description" content="{t['og_desc']}">
<meta name="twitter:image" content="{SITE}/assets/og.png">
<link rel="icon" href="{up}assets/icon-64.png" type="image/png" sizes="64x64">
<link rel="apple-touch-icon" href="{up}assets/apple-touch-icon.png">
<link rel="preload" href="{up}assets/fonts/ibm-plex-sans-latin-wght-normal.woff2" as="font" type="font/woff2" crossorigin>
<link rel="preload" href="{up}assets/fonts/ibm-plex-mono-latin-500-normal.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="{up}assets/site.css?v={ASSET_V}">
{extra}</head>
"""


def masthead(t, lang, page, up, absolute=False, legal=False):
    """`absolute` is for 404.html, which GitHub Pages serves from any depth,
    so every link there must be root-relative rather than page-relative.
    `legal` marks the English-only pages: there is no translated counterpart,
    so switching language goes to that language's home page instead."""
    if legal:
        home = "index.html"
        nav_targets = ["index.html", "privacy.html", "support.html", "terms.html"]
        langs = [f'        <a href="index.html" hreflang="en" aria-current="true">EN</a>'] + [
            f'        <a href="{l}/index.html" hreflang="{l}">{l.upper()}</a>'
            for l in LANGS if l != "en"
        ]
    elif absolute:
        base = "/Local-File-Diet/"
        home = base
        nav_targets = [base, base + "privacy.html", base + "support.html", base + "terms.html"]
        langs = [f'        <a href="{base}" hreflang="en" aria-current="true">EN</a>'] + [
            f'        <a href="{base}{l}/" hreflang="{l}">{l.upper()}</a>'
            for l in LANGS if l != "en"
        ]
    else:
        home = "index.html" if page == "index.html" else f"{up}index.html"
        nav_targets = ["index.html", f"{up}privacy.html", "support.html", f"{up}terms.html"]
        if lang == "en":
            nav_targets = ["index.html", "privacy.html", "support.html", "terms.html"]
        langs = []
        for l in LANGS:
            if l == "en":
                href = f"{up}{page}"
            else:
                href = f"{page}" if l == lang else f"{up}{l}/{page}"
            cur = ' aria-current="true"' if l == lang else ""
            langs.append(f'        <a href="{href}" hreflang="{l}"{cur}>{l.upper()}</a>')

    nav = "\n".join(
        f'        <a href="{h}">{lbl}</a>'
        for lbl, h in zip(t["nav"], nav_targets)
    )
    return f"""<body>
<a class="skip" href="#main">{t['skip']}</a>

<header class="masthead">
  <div class="shell masthead-in">
    <a class="brand" href="{home}">{MARK}<span>Local File Diet</span></a>

    <nav class="nav" aria-label="{t['nav'][0]}">
{nav}
    </nav>

    <div class="masthead-end">
      <nav class="langs" aria-label="{t['lang_label']}">
{chr(10).join(langs)}
      </nav>
      <a class="head-cta" href="{APPSTORE}">App&nbsp;Store</a>
    </div>
  </div>
</header>
"""


def badge(t, lang, up, h=52):
    w = round(h * 158 / 52)
    return (f'<a class="badge" href="{APPSTORE}">'
            f'<img src="{up}assets/badges/appstore-{BADGE[lang]}.svg" '
            f'alt="{t["badge_alt"]}" width="{w}" height="{h}"></a>')


def footer(t, lang, page, up, absolute=False):
    # in-page anchors only resolve on the home page; elsewhere prefix the home page
    anchor_base = "" if page == "index.html" else "index.html"
    if absolute:
        base = "/Local-File-Diet/"
        home = base
        prod_links = []
        for lbl, h in t["foot_links_product"]:
            if h.startswith("http"):
                prod_links.append((lbl, h))
            elif h.startswith("#"):
                prod_links.append((lbl, base + h))  # anchors live on the home page
            else:
                prod_links.append((lbl, base + h))
        legal_links = [("Support", base + "support.html"),
                       ("Privacy policy", base + "privacy.html"),
                       ("Terms of use", base + "terms.html")]
    else:
        home = "index.html" if page == "index.html" else f"{up}index.html"
        prod_links = []
        for lbl, h in t["foot_links_product"]:
            if h.startswith("http"):
                prod_links.append((lbl, h))
            elif h.startswith("#"):
                prod_links.append((lbl, anchor_base + h))
            else:
                prod_links.append((lbl, up + h))
        legal_links = t["foot_links_legal"] if lang != "en" else [
            ("Support", "support.html"), ("Privacy policy", "privacy.html"),
            ("Terms of use", "terms.html")]

    prod = "\n".join(f'          <li><a href="{h}">{lbl}</a></li>' for lbl, h in prod_links)
    legal = "\n".join(f'          <li><a href="{h}">{lbl}</a></li>' for lbl, h in legal_links)
    return f"""
<footer class="foot">
  <div class="shell">
    <div class="foot-in">
      <div class="foot-brand">
        <a class="brand" href="{home}">{MARK}<span>Local File Diet</span></a>
        <p>{t['foot_tagline']}</p>
      </div>

      <div>
        <h4>{t['foot_product']}</h4>
        <ul>
{prod}
        </ul>
      </div>

      <div>
        <h4>{t['foot_legal']}</h4>
        <ul>
{legal}
        </ul>
      </div>
    </div>

    <div class="foot-base">
      <span>© <span data-year>2026</span> Simone Mattioli</span>
      <span>{t['foot_made']}</span>
    </div>
  </div>
</footer>

<div class="dock">
  <p class="dock-txt"><b>Local File Diet</b>{t['dock_sub']}</p>
  {badge(t, lang, up, 38)}
</div>

<script src="{up}assets/site.js?v={ASSET_V}" defer></script>
</body>
</html>
"""


def notes(items):
    lis = "\n".join(f"          <li>{i}</li>" for i in items)
    return f'        <ul class="hero-note">\n{lis}\n        </ul>'


# --------------------------------------------------------------------------
# Pages
# --------------------------------------------------------------------------
def build_index(lang):
    t = T[lang]
    up = "" if lang == "en" else "../"
    canonical = f"{SITE}/" if lang == "en" else f"{SITE}/{lang}/"

    ld = f"""<script type="application/ld+json">
{{
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  "name": "Local File Diet",
  "applicationCategory": "UtilitiesApplication",
  "operatingSystem": "iOS 17.0 or later",
  "softwareVersion": "2.0",
  "url": "{canonical}",
  "installUrl": "{APPSTORE}",
  "image": "{SITE}/assets/icon-512.png",
  "inLanguage": "{t['locale']}",
  "description": "{t['idx_desc']}",
  "author": {{ "@type": "Person", "name": "Simone Mattioli" }}
}}
</script>
"""

    spec = "\n".join(
        f'      <div class="spec"><dt>{k}</dt><dd>{v}</dd></div>' for k, v in t["spec"]
    )
    ro = "\n".join(
        f'              <div class="ro{" ro-sig" if i == 2 else ""}"><dt>{lbl}</dt>'
        f'<dd data-out-{k}>{d}</dd></div>'
        for i, (lbl, k, d) in enumerate(zip(
            t["ro"], ["original", "target", "result", "delta"],
            ["112.4 MB", "10.0 MB", "9.62 MB", "−91.4%"]))
    )
    seg = "\n".join(
        f'              <button type="button" role="radio" data-kind="{k}" '
        f'aria-checked="{"true" if i == 0 else "false"}" tabindex="{0 if i == 0 else -1}">{lbl}</button>'
        for i, (lbl, k) in enumerate(zip(t["seg"], ["video", "pdf", "image"]))
    )
    fmts = "\n".join(
        f"""          <article class="format">
            <p class="format-name">{name}</p>
            <p class="format-what">{what}</p>
            <p class="format-spec">{"".join(f"<span>{s}</span>" for s in specs)}</p>
          </article>""" for name, what, specs in t["formats"]
    )
    thr = "\n".join(
        f"""          <article class="panel">
            <div class="panel-body">
              <h3>{h3}</h3>
              <p class="prose">{p}</p>
              <div class="chips">{"".join(f'<span class="chip">{c}</span>' for c in chips)}</div>
            </div>
            <div class="panel-shot panel-shot-clip">
              <div class="device"><div class="device-screen">
                <img src="{up}assets/shots/{shot}.png" alt="{t['shot_' + shot + '_alt']}" width="1206" height="2622" loading="lazy">
              </div></div>
            </div>
          </article>""" for h3, p, chips, shot in t["thr"]
    )
    claims = "\n".join(
        f"""          <div class="claim">{TICK}
            <p class="claim-txt"><strong>{s}</strong><span>{d}</span></p>
            <p class="claim-val">{v}</p>
          </div>""" for s, d, v in t["claims"]
    )
    steps = "\n".join(
        f"""          <li class="step">
            <span class="step-n">0{i + 1}</span>
            <h3>{h}</h3>
            <p>{p}</p>
          </li>""" for i, (h, p) in enumerate(t["steps"])
    )

    body = f"""
<main id="main">

  <section class="hero" data-scroll-trigger>
    <div class="shell hero-in">
      <div class="hero-copy">
        <p class="label">{t['hero_eyebrow']}</p>
        <h1>{t['hero_h1']}</h1>
        <p class="lead">{t['hero_lead']}</p>
        <div class="cta-row">{badge(t, lang, up)}</div>
{notes(t['hero_notes'])}
      </div>

      <div class="device-stage">
        <div class="device">
          <div class="device-screen">
            <img src="{up}assets/shots/result.png" alt="{t['shot_result_alt']}" width="1206" height="2622" fetchpriority="high">
          </div>
          <p class="device-tag num"><s>112.4 MB</s> 9.6 MB</p>
        </div>
      </div>
    </div>
  </section>

  <div class="specstrip">
    <dl class="shell specstrip-in">
{spec}
    </dl>
  </div>

  <section class="band" id="precision">
    <div class="shell band-in">
      <div class="rail"><p class="label">{t['rail_precision']}</p></div>
      <div class="rv">
        <div class="band-head">
          <h2>{t['prec_h2']}</h2>
          <p class="prose">{t['prec_p']}</p>
        </div>

        <div class="instrument" data-instrument
             data-msg-ok="{t['msg_ok']}"
             data-msg-over="{t['msg_over']}">
          <div class="instrument-bar">
            <div class="seg" data-seg role="radiogroup" aria-label="{t['seg_label']}">
{seg}
            </div>
            <p class="disclaim">{t['disclaim']}</p>
          </div>

          <div class="instrument-body">
            <dl class="readout">
{ro}
            </dl>

            <div class="scale">
              <div class="scale-row">
                <p class="scale-cap">{t['cap_full']}</p>
                <div class="track track-coarse">
                  <div class="scale-fill" data-scale-fill style="width:8.6%"></div>
                </div>
                <div class="scale-legend"><span>0</span><span data-legend-max>112.4 MB</span></div>
              </div>

              <div class="scale-row">
                <p class="scale-cap">{t['cap_detail']} <em data-zoom>×45</em></p>
                <div class="track track-detail">
                  <div class="detail-over" aria-hidden="true"></div>
                  <div class="detail-band" data-detail-band style="left:64.8%;width:15.2%"></div>
                  <div class="detail-result" data-detail-result style="left:64.8%"></div>
                  <div class="detail-limit" aria-hidden="true"></div>
                </div>
                <div class="scale-ticks" data-ticks aria-hidden="true"></div>
                <div class="scale-legend">
                  <span data-detail-lo>8.00 MB</span>
                  <span class="legend-mid">{t['legend_limit']}</span>
                  <span data-detail-hi>10.5 MB</span>
                </div>
              </div>
            </div>

            <div class="slider-row">
              <div>
                <label class="slider-lab" for="target">{t['slider_lab']}</label>
                <input id="target" type="range" min="0" max="240" value="120" step="1"
                       data-slider aria-describedby="verdict">
              </div>
              <output class="slider-val" data-slider-val for="target">10.0 MB</output>
            </div>

            <p class="verdict" id="verdict" data-verdict data-state="ok" role="status"></p>
          </div>
        </div>
      </div>
    </div>
  </section>

  <section class="band" id="formats">
    <div class="shell band-in">
      <div class="rail"><p class="label">{t['rail_formats']}</p></div>
      <div class="rv">
        <div class="band-head">
          <h2>{t['fmt_h2']}</h2>
          <p class="prose">{t['fmt_p']}</p>
        </div>
        <div class="formats">
{fmts}
        </div>
      </div>
    </div>
  </section>

  <section class="band" id="batch">
    <div class="shell band-in">
      <div class="rail"><p class="label">{t['rail_through']}</p></div>
      <div class="rv">
        <div class="band-head"><h2>{t['thr_h2']}</h2></div>
        <div class="duo">
{thr}
        </div>
      </div>
    </div>
  </section>

  <section class="band" id="privacy">
    <div class="shell band-in">
      <div class="rail"><p class="label">{t['rail_privacy']}</p></div>
      <div class="rv">
        <div class="band-head">
          <h2>{t['priv_h2']}</h2>
          <p class="prose">{t['priv_p']}</p>
        </div>
        <div class="claims">
{claims}
        </div>
        <div class="nutrition">
          <span class="nutrition-k">{t['nutrition_k']}</span>
          <span class="nutrition-v">{t['nutrition_v']}</span>
          <p>{t['nutrition_p']}</p>
        </div>
      </div>
    </div>
  </section>

  <section class="band" id="how">
    <div class="shell band-in">
      <div class="rail"><p class="label">{t['rail_how']}</p></div>
      <div class="rv">
        <div class="band-head"><h2>{t['how_h2']}</h2></div>
        <ol class="steps">
{steps}
        </ol>
      </div>
    </div>
  </section>

  <section class="closer">
    <div class="shell closer-in">
      <h2>{t['closer_h2']}</h2>
      <p class="lead">{t['closer_lead']}</p>
      {badge(t, lang, up)}
{notes(t['closer_notes'])}
    </div>
  </section>

</main>
"""
    return (head(t, lang, "index.html", t["idx_title"], t["idx_desc"], up, canonical, ld)
            + masthead(t, lang, "index.html", up) + body + footer(t, lang, "index.html", up))


def build_support(lang):
    t = T[lang]
    up = "" if lang == "en" else "../"
    canonical = f"{SITE}/support.html" if lang == "en" else f"{SITE}/{lang}/support.html"

    cards = "\n".join(
        f"""        <a class="contact-card" href="{href}">
          <p class="label">{kind}</p>
          <strong>{title}</strong>
          <span>{body}</span>
          <em>{addr}</em>
        </a>""" for kind, title, body, addr, href in t["contact"]
    )
    faq_items = "\n".join(
        f"""          <details>
            <summary>{q}</summary>
            <div class="faq-a">{"".join(f"<p>{p}</p>" for p in ps)}</div>
          </details>""" for q, ps in t["faq"]
    )
    faq_ld = {
        "@context": "https://schema.org",
        "@type": "FAQPage",
        "inLanguage": t["locale"],
        "mainEntity": [
            {"@type": "Question", "name": q,
             "acceptedAnswer": {"@type": "Answer", "text": " ".join(ps)}}
            for q, ps in t["faq"]
        ],
    }
    ld = ('<script type="application/ld+json">\n'
          + json.dumps(faq_ld, ensure_ascii=False, indent=2)
          + "\n</script>\n")

    body = f"""
<main id="main">
  <section class="page-head" data-scroll-trigger>
    <div class="shell">
      <p class="label">{t['sup_eyebrow']}</p>
      <h1>{t['sup_h1']}</h1>
      <p class="lead">{t['sup_lead']}</p>
      <p class="page-meta">{"".join(f"<span>{m}</span>" for m in t['sup_meta'])}</p>
    </div>
  </section>

  <section class="band">
    <div class="shell band-in">
      <div class="rail"><p class="label">{t['contact_rail']}</p></div>
      <div class="rv">
        <div class="contact contact-lead">
{cards}
        </div>
      </div>
    </div>
  </section>

  <section class="band">
    <div class="shell band-in">
      <div class="rail"><p class="label">{t['faq_rail']}</p></div>
      <div class="rv">
        <div class="band-head"><h2>{t['faq_h2']}</h2></div>
        <div class="faq">
{faq_items}
        </div>
      </div>
    </div>
  </section>

  <section class="closer">
    <div class="shell closer-in">
      <h2>{t['closer_h2']}</h2>
      <p class="lead">{t['closer_lead']}</p>
      {badge(t, lang, up)}
{notes(t['closer_notes'])}
    </div>
  </section>
</main>
"""
    return (head(t, lang, "support.html", t["sup_title"], t["sup_desc"], up, canonical, ld)
            + masthead(t, lang, "support.html", up) + body + footer(t, lang, "support.html", up))


def build_legal(page, title, desc, eyebrow, heading, sections):
    t = T["en"]
    up = ""
    canonical = f"{SITE}/{page}"

    def sid(name):
        return name.lower().replace(",", "").replace("’", "").replace(" ", "-")

    toc = "\n".join(
        f'          <li><a href="#{sid(n)}">{n}</a></li>' for n, _ in sections
    )
    secs = "\n".join(
        f"""        <section class="doc-sec">
          <h2 id="{sid(n)}"><i>{i + 1:02d}</i>{n}</h2>
          {"".join(f"<p>{p}</p>" for p in ps)}
        </section>""" for i, (n, ps) in enumerate(sections)
    )

    body = f"""
<main id="main">
  <section class="page-head" data-scroll-trigger>
    <div class="shell">
      <p class="label">{eyebrow}</p>
      <h1>{heading}</h1>
      <p class="page-meta">
        <span>{t['legal_effective']}: {EFFECTIVE}</span>
        <span>Local File Diet 2.0</span>
      </p>
    </div>
  </section>

  <div class="shell doc">
    <nav class="toc" aria-label="{t['toc_title']}">
      <h2>{t['toc_title']}</h2>
      <ul>
{toc}
      </ul>
    </nav>

    <article class="doc-body">
      <div class="callout lang-note">
        <p><strong>English only.</strong> This is the authoritative version of this document.</p>
        <p lang="it">Questo documento è disponibile solo in inglese.</p>
        <p lang="es">Este documento solo está disponible en inglés.</p>
        <p lang="de">Dieses Dokument ist nur auf Englisch verfügbar.</p>
      </div>
{secs}
    </article>
  </div>
</main>
"""
    return (head(t, "en", page, title, desc, up, canonical, alts=False)
            + masthead(t, "en", page, up, legal=True) + body + footer(t, "en", page, up))


def build_404():
    t = T["en"]
    body = f"""
<main id="main" class="shell void">
  <p class="label">{t['e404_eyebrow']}</p>
  <p class="void-code num">404</p>
  <h1>{t['e404_h1']}</h1>
  <p class="lead">{t['e404_p']}</p>
  <p class="cta-row">
    <a class="btn" href="/Local-File-Diet/">{t['e404_btn']}</a>
    <a class="btn btn-ghost" href="/Local-File-Diet/support.html">{t['e404_sup']}</a>
  </p>
</main>
"""
    h = head(t, "en", "404.html", t["e404_title"], "Page not found.", "/Local-File-Diet/",
             f"{SITE}/404.html", '<meta name="robots" content="noindex">\n', alts=False)
    return h + masthead(t, "en", "404.html", "/Local-File-Diet/", absolute=True) + body \
        + footer(t, "en", "404.html", "/Local-File-Diet/", absolute=True)


def build_sitemap():
    urls = []
    for lang in LANGS:
        pre = "" if lang == "en" else f"{lang}/"
        for page in ["", "support.html"]:
            loc = f"{SITE}/{pre}{page}"
            alts = "\n".join(
                f'    <xhtml:link rel="alternate" hreflang="{l}" '
                f'href="{SITE}/{"" if l == "en" else l + "/"}{page}"/>' for l in LANGS
            )
            urls.append(f"  <url>\n    <loc>{loc}</loc>\n{alts}\n  </url>")
    for page in ["privacy.html", "terms.html"]:
        urls.append(f"  <url>\n    <loc>{SITE}/{page}</loc>\n  </url>")
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"\n'
            '        xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
            + "\n".join(urls) + "\n</urlset>\n")


def write(rel, content):
    path = os.path.normpath(os.path.join(ROOT, rel))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"  {rel:28} {len(content.encode()):>7,} bytes")


def main():
    print("Building docs/")
    for lang in LANGS:
        pre = "" if lang == "en" else f"{lang}/"
        write(f"{pre}index.html", build_index(lang))
        write(f"{pre}support.html", build_support(lang))
    write("privacy.html", build_legal(
        "privacy.html", T["en"]["priv_title"], T["en"]["priv_desc"],
        "Privacy Policy", "How Local File Diet handles your data", PRIVACY))
    write("terms.html", build_legal(
        "terms.html", T["en"]["terms_title"], T["en"]["terms_desc"],
        "Terms of Use", "Terms of use", TERMS))
    write("404.html", build_404())
    write("sitemap.xml", build_sitemap())
    print("Done.")


if __name__ == "__main__":
    main()
