// Lumen — делает из обычной (SDR) фотографии HDR-файл с gain map:
// база остаётся обычной картинкой, а HDR-экраны (Mac XDR, iPhone, Android, Chrome,
// Instagram/Threads) по карте усиления поднимают светлые места выше белого.
import AppKit
import SwiftUI
import MetalKit
import CoreImage
import UniformTypeIdentifiers

// MARK: - Ядро

struct Params: Equatable {
    var balance: Double = 50   // 0 — светятся только самые яркие места, 100 — и средние тона
    var power: Double = 70     // 0..100 → 0..maxStops стопов подъёма
}

final class Engine {
    static let shared = Engine()
    static let maxStops = 3.0  // ×8 над белым — потолок, который iPhone/Android реально показывают

    let device: MTLDevice
    let queue: MTLCommandQueue
    let ctx: CIContext
    let kernel: CIColorKernel

    private init() {
        device = MTLCreateSystemDefaultDevice()!
        queue = device.makeCommandQueue()!
        ctx = CIContext(mtlDevice: device, options: [.workingFormat: CIFormat.RGBAh, .cacheIntermediates: true])
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let url = Bundle.main.url(forResource: "Lumen", withExtension: "metallib")
            ?? exe.deletingLastPathComponent().appendingPathComponent("../Resources/Lumen.metallib").standardized
        guard let data = try? Data(contentsOf: url),
              let k = try? CIColorKernel(functionName: "lumenBoost", fromMetalLibraryData: data)
        else { fatalError("Lumen.metallib не найден: \(url.path)") }
        kernel = k
    }

    static func stops(_ p: Params) -> Double { p.power / 100 * maxStops }

    /// SDR → HDR (линейный, значения > 1 — то, что светит выше белого).
    func hdr(from sdr: CIImage, _ p: Params) -> CIImage {
        let ext = sdr.extent
        // радиус в долях кадра — превью (уменьшенное) и экспорт (полный размер) совпадают
        let sigma = max(0.5, Double(min(ext.width, ext.height)) / 900)
        let guide = sdr.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: ext)
        let t = 0.85 - 0.6 * p.balance / 100
        let st = Self.stops(p)
        let out = kernel.apply(extent: ext, arguments: [sdr, guide, Float(t), Float(st)]) ?? sdr
        return out.settingContentHeadroom(Float(max(1.0, exp2(st))))
    }

    /// Загрузка с уже применённой ориентацией (и с Orientation=1 в метаданных,
    /// чтобы при записи не повернуло второй раз).
    func load(_ url: URL) throws -> CIImage {
        guard let img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw NSError(domain: "Lumen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не открывается как картинка: \(url.lastPathComponent)"])
        }
        var props = img.properties
        props[kCGImagePropertyOrientation as String] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            props[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        // Если в файле уже был gain map — берём только базу, карту строим свою.
        props.removeValue(forKey: "{MakerApple}")
        let moved = img.transformed(by: .init(translationX: -img.extent.minX, y: -img.extent.minY))
        return moved.settingProperties(props)
    }

    enum Format: String { case jpeg, heic }

    func export(source: URL, to dest: URL, params p: Params, format: Format, quality: Double = 0.92) throws {
        let sdr = try load(source)
        let hdr = hdr(from: sdr, p)
        // База в цветовом пространстве исходника (обычно sRGB или P3): вьюверы без
        // поддержки gain map покажут ровно то, что было.
        let cs: CGColorSpace = {
            if let c = sdr.colorSpace, c.model == .rgb, c.name != nil { return c }
            return CGColorSpace(name: CGColorSpace.sRGB)!
        }()
        let opts: [CIImageRepresentationOption: Any] = [
            .hdrImage: hdr,
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality,
        ]
        switch format {
        case .jpeg: try ctx.writeJPEGRepresentation(of: sdr, to: dest, colorSpace: cs, options: opts)
        case .heic: try ctx.writeHEIFRepresentation(of: sdr, to: dest, format: .RGBA8, colorSpace: cs, options: opts)
        }
    }

    static func defaultOutput(for src: URL, _ f: Format) -> URL {
        src.deletingPathExtension().appendingPathExtension("hdr").appendingPathExtension(f == .jpeg ? "jpg" : "heic")
    }
}

// MARK: - Документ

final class Doc: ObservableObject {
    static let shared = Doc()

    struct Toast: Equatable { var text: String; var isError = false; var reveal: URL? }

    @Published var url: URL?
    @Published var preview: CIImage?     // уменьшенный SDR (уже декодированный) для живого превью
    @Published var params = Params() { didSet { saveDefaults() } }
    @Published var comparing = false
    @Published var toast: Toast?
    @Published var loading = false
    @Published var exporting = false

    var busy: Bool { loading || exporting }
    var canExport: Bool { preview != nil && !busy }

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: "balance") != nil {
            params = Params(balance: d.double(forKey: "balance"), power: d.double(forKey: "power"))
        }
    }

    private func saveDefaults() {
        UserDefaults.standard.set(params.balance, forKey: "balance")
        UserDefaults.standard.set(params.power, forKey: "power")
    }

    var shown: CIImage? {
        guard let p = preview else { return nil }
        return comparing ? p : Engine.shared.hdr(from: p, params)
    }

    /// Декодирование и уменьшение — в фоне, превью материализуется в float-буфер,
    /// чтобы ползунки не перечитывали исходник на каждом кадре.
    func open(_ url: URL) {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () throws -> CIImage in
                let e = Engine.shared
                let full = try e.load(url)
                let s = min(1, 2560 / max(full.extent.width, full.extent.height))
                let small = s < 1
                    ? full.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: s, kCIInputAspectRatioKey: 1])
                    : full
                let lin = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
                guard let cg = e.ctx.createCGImage(small, from: small.extent, format: .RGBAh, colorSpace: lin) else {
                    throw NSError(domain: "Lumen", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось декодировать \(url.lastPathComponent)"])
                }
                return CIImage(cgImage: cg)
            }
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let img):
                    self.preview = img
                    self.url = url
                    NSDocumentController.shared.noteNewRecentDocumentURL(url)
                case .failure(let err):
                    self.flash(.init(text: err.localizedDescription, isError: true))
                }
            }
        }
    }

    func openPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { open(u) }
    }

    func export(_ f: Engine.Format) {
        guard canExport, let src = url else { return }
        comparing = false
        let p = NSSavePanel()
        p.allowedContentTypes = [f == .jpeg ? .jpeg : .heic]
        p.directoryURL = src.deletingLastPathComponent()
        p.nameFieldStringValue = Engine.defaultOutput(for: src, f).lastPathComponent
        p.canCreateDirectories = true
        guard p.runModal() == .OK, let dest = p.url else { return }
        exporting = true
        let params = self.params
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Engine.shared.export(source: src, to: dest, params: params, format: f) }
            DispatchQueue.main.async {
                self.exporting = false
                switch result {
                case .success: self.flash(.init(text: "Сохранено: \(dest.lastPathComponent)", reveal: dest))
                case .failure(let e): self.flash(.init(text: "Не сохранилось: \(e.localizedDescription)", isError: true))
                }
            }
        }
    }

    func flash(_ t: Toast) {
        toast = t
        let secs = t.isError ? 8.0 : 5.0
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
            if self?.toast == t { self?.toast = nil }
        }
    }
}

// MARK: - HDR-превью (Metal, extended range)

final class HDRView: MTKView, MTKViewDelegate {
    var image: CIImage? { didSet { needsDisplay = true } }
    private let cs = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    init() {
        super.init(frame: .zero, device: Engine.shared.device)
        colorPixelFormat = .rgba16Float
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        if let l = layer as? CAMetalLayer {
            l.wantsExtendedDynamicRangeContent = true
            l.colorspace = cs
            l.isOpaque = true
        }
        delegate = self
    }
    required init(coder: NSCoder) { fatalError() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { needsDisplay = true }

    func draw(in view: MTKView) {
        guard let d = currentDrawable, let cb = Engine.shared.queue.makeCommandBuffer() else { return }
        let size = drawableSize
        let rect = CGRect(origin: .zero, size: size)
        var out = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: rect)
        if let im = image, im.extent.width > 0 {
            let s = min(size.width / im.extent.width, size.height / im.extent.height)
            let scaled = im.transformed(by: .init(scaleX: s, y: s))
            let dx = (size.width - scaled.extent.width) / 2 - scaled.extent.minX
            let dy = (size.height - scaled.extent.height) / 2 - scaled.extent.minY
            out = scaled.transformed(by: .init(translationX: dx, y: dy)).composited(over: out)
        }
        Engine.shared.ctx.render(out, to: d.texture, commandBuffer: cb, bounds: rect, colorSpace: cs)
        cb.present(d)
        cb.commit()
    }
}

struct HDRPreview: NSViewRepresentable {
    let image: CIImage?
    func makeNSView(context: Context) -> HDRView { HDRView() }
    func updateNSView(_ v: HDRView, context: Context) { v.image = image }
}

// MARK: - Интерфейс

let accent = Color(red: 0.72, green: 0.50, blue: 1.0)
let barColor = Color(white: 0.11)
let panelColor = Color(white: 0.09).opacity(0.88)

struct ParamSlider: View {
    let title: String
    let hint: String
    let defaultValue: Double
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .foregroundStyle(.white.opacity(0.75))
                .frame(minWidth: 64, alignment: .leading)
                .fixedSize()
                .onTapGesture(count: 2) { value = defaultValue }
                .help(hint + "\nДвойной клик — сбросить на \(Int(defaultValue))")
            Slider(value: $value, in: 0...100)
                .tint(accent)
                .help(hint)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int(value.rounded())) из 100")
            Text("\(Int(value.rounded()))")
                .monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

/// Плашка-кнопка: подсветка при наведении, курсор-рука, явное «включено».
struct PillLook: ViewModifier {
    var active = false
    var pressed = false
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(accent.opacity(pressed ? 0.55 : active ? 0.34 : hover ? 0.28 : 0.2)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(accent.opacity(active ? 0.7 : 0), lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .pointerStyle(.link)
    }
}

struct Pill: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(PillLook(active: active, pressed: configuration.isPressed))
    }
}

struct ContentView: View {
    @ObservedObject var doc = Doc.shared
    @State private var dropping = false
    @AppStorage("showPanel") private var showPanel = true

    var body: some View {
        VStack(spacing: 0) {
            stage
            if doc.preview != nil { bottomBar }
        }
        .background(Color.black)
        .frame(minWidth: 640, minHeight: 480)
        .navigationTitle(doc.url?.lastPathComponent ?? "Lumen")
        .toolbarBackground(barColor, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            guard (try? u.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true else {
                doc.flash(.init(text: "Это не картинка: \(u.lastPathComponent)", isError: true)); return false
            }
            doc.open(u); return true
        } isTargeted: { dropping = $0 }
        .animation(.easeOut(duration: 0.18), value: doc.toast)
        .animation(.easeOut(duration: 0.18), value: showPanel)
        .animation(.easeOut(duration: 0.1), value: doc.comparing)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { doc.openPanel() } label: { Label("Открыть", systemImage: "photo.badge.plus") }
                    .help("Открыть фото (⌘O)")
                    .disabled(doc.busy)
            }
            ToolbarItem(placement: .primaryAction) {
                if doc.exporting {
                    ProgressView().controlSize(.small).help("Сохраняю…")
                } else {
                    Menu {
                        Button("JPEG с gain map…") { doc.export(.jpeg) }
                        Button("HEIC с gain map…") { doc.export(.heic) }
                    } label: {
                        Label("Экспорт", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!doc.canExport)
                    .help("Сохранить HDR-файл (⌘E — JPEG, ⇧⌘E — HEIC)")
                }
            }
        }
    }

    // Кадр + плавающая панель поверх его низа
    private var stage: some View {
        ZStack(alignment: .bottom) {
            if doc.preview != nil {
                HDRPreview(image: doc.shown)
            } else {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if doc.loading {
                ProgressView("Открываю…").controlSize(.large)
                    .padding(20).background(panelColor, in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if doc.comparing {
                Text("Оригинал")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(panelColor, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 14)
                    .transition(.opacity)
            }
            VStack(spacing: 10) {
                if let t = doc.toast { toastView(t) }
                if doc.preview != nil && showPanel { panel }
            }
            .padding(14)
            if dropping {
                RoundedRectangle(cornerRadius: 14).strokeBorder(accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                    .padding(10).allowsHitTesting(false)
            }
        }
        .clipped()
    }

    private func toastView(_ t: Doc.Toast) -> some View {
        HStack(spacing: 10) {
            if t.isError { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
            Text(t.text).lineLimit(2)
            if let u = t.reveal {
                Button("Показать") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                    .buttonStyle(.link).pointerStyle(.link)
            }
            Button { doc.toast = nil } label: { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.secondary).pointerStyle(.link)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(panelColor, in: Capsule())
        .transition(.opacity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sun.max").font(.system(size: 44, weight: .light)).foregroundStyle(accent)
            Text("Перетащи фото сюда").font(.title3)
            Text("JPEG, HEIC, PNG, TIFF, RAW").font(.caption).foregroundStyle(.secondary)
            Button("Открыть…") { doc.openPanel() }.buttonStyle(Pill()).disabled(doc.busy)
            Text(screenNote).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .padding(40)
        .background(RoundedRectangle(cornerRadius: 20).fill(accent.opacity(dropping ? 0.12 : 0)))
    }

    private var screenNote: String {
        let h = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1
        return h > 1.01
            ? String(format: "Экран показывает HDR до ×%.0f над белым", h)
            : "Этот экран без HDR: превью будет плоским, но файл сохранится правильно"
    }

    private var panel: some View {
        VStack(spacing: 8) {
            ParamSlider(title: "Баланс", hint: "С какой яркости начинается свечение: слева — только самые светлые места, справа — и средние тона",
                        defaultValue: Params().balance, value: $doc.params.balance)
            ParamSlider(title: "Сила", hint: "Насколько светлые места поднимаются выше белого (до ×8)",
                        defaultValue: Params().power, value: $doc.params.power)
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(maxWidth: 520)
        .background(panelColor, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.08)))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            compareButton
            Button { showPanel.toggle() } label: {
                Label("Настройки", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity)
            }
            .buttonStyle(Pill(active: showPanel))
            .keyboardShortcut("i", modifiers: [])
            .help("Показать/скрыть ползунки (I)")
        }
        .frame(maxWidth: 520)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(barColor)
    }

    // «Сравнить» — держать: пока нажато, показывается оригинал
    private var compareButton: some View {
        HStack(spacing: 6) {
            Label("Сравнить", systemImage: "sun.max")
            Text("␣").font(.caption).foregroundStyle(.secondary)
        }
        .modifier(PillLook(pressed: doc.comparing))
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if !doc.comparing { doc.comparing = true } }
            .onEnded { _ in doc.comparing = false })
        .help("Держи кнопку или пробел — виден оригинал")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Сравнить с оригиналом")
        .accessibilityAction { doc.comparing.toggle() }
    }
}

// MARK: - Приложение

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func application(_ app: NSApplication, open urls: [URL]) {
        if let u = urls.first { Doc.shared.open(u) }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // пробел — держать для сравнения; только в главном окне, не в панелях/модалках
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
            guard e.keyCode == 49, Doc.shared.preview != nil,
                  NSApp.modalWindow == nil,
                  let w = NSApp.keyWindow, !(w is NSPanel),
                  !(w.firstResponder is NSText) else { return e }
            if e.type == .keyDown && e.isARepeat { return nil }
            Doc.shared.comparing = (e.type == .keyDown)
            return nil
        }
        // keyUp не придёт, если ушли Cmd-Tab с зажатым пробелом
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            Doc.shared.comparing = false
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

struct LumenCommands: Commands {
    @ObservedObject var doc = Doc.shared
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Открыть…") { doc.openPanel() }.keyboardShortcut("o").disabled(doc.busy)
        }
        CommandGroup(replacing: .saveItem) {
            Button("Экспорт JPEG…") { doc.export(.jpeg) }.keyboardShortcut("e").disabled(!doc.canExport)
            Button("Экспорт HEIC…") { doc.export(.heic) }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!doc.canExport)
        }
    }
}

struct LumenApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("Lumen", id: "main") {
            ContentView().preferredColorScheme(.dark)
        }
        .defaultSize(width: 1100, height: 760)
        .windowToolbarStyle(.unified)
        .commands { LumenCommands() }
    }
}

// MARK: - CLI: lumen convert фото... [-b 50] [-p 70] [--heic] [-o выход]

enum CLI {
    static func run(_ args: [String]) -> Int32 {
        var p = Params(), fmt = Engine.Format.jpeg, out: String?, inputs: [String] = []
        var i = 0
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "-b", "--balance": p.balance = Double(next() ?? "") ?? p.balance
            case "-p", "--power": p.power = Double(next() ?? "") ?? p.power
            case "--heic": fmt = .heic
            case "-o": out = next()
            case "-h", "--help":
                print("lumen convert фото... [-b баланс 0-100] [-p сила 0-100] [--heic] [-o выход]\n  по умолчанию: рядом с исходником, имя.hdr.jpg")
                return 0
            default: inputs.append(args[i])
            }
            i += 1
        }
        if inputs.isEmpty { print("нет входных файлов (lumen convert --help)"); return 2 }
        if out != nil && inputs.count > 1 { print("-o только для одного файла"); return 2 }
        var failed: Int32 = 0
        for path in inputs {
            let src = URL(fileURLWithPath: path)
            var dst = out.map { URL(fileURLWithPath: $0) } ?? Engine.defaultOutput(for: src, fmt)
            if let o = out, o.lowercased().hasSuffix(".heic") { fmt = .heic; dst = URL(fileURLWithPath: o) }
            do {
                try Engine.shared.export(source: src, to: dst, params: p, format: fmt)
                print("✓ \(dst.path)")
            } catch {
                print("✗ \(path): \(error.localizedDescription)"); failed = 1
            }
        }
        return failed
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.count > 1, args[1] == "convert" {
            exit(CLI.run(Array(args.dropFirst(2))))
        }
        LumenApp.main()
    }
}
