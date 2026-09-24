import AVFoundation
import AVKit
import SwiftUI

// MARK: - 점수 게이지

/// 반원 게이지. 숫자 하나("73%")는 거짓 정밀도를 부르므로, `aiLevel` 의 3구간(0.35 / 0.7)을
/// 색 띠로 깔고 그 위에 바늘을 둔다 — 값과 불확실성 폭이 같이 읽힌다. 숫자는 남기되 보조로 내린다.
struct ScoreGaugeView: View {
    let score: Double
    let level: RiskLevel
    let model: String

    /// 띠 경계는 `RiskLevel(score:)` 와 같은 값이어야 한다 — 다르면 바늘은 "보통" 띠에 있는데 글자는 "높음"이 된다.
    private static let lowCut = RiskLevel.lowUpperBound
    private static let midCut = RiskLevel.mediumUpperBound

    var body: some View {
        HStack(spacing: 14) {
            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height - 6)
                let radius = min(size.width / 2, size.height) - 8

                // 각도: 화면 좌표(y 아래 방향)에서 180°=왼쪽, 270°=위, 360°=오른쪽.
                func band(_ from: Double, _ to: Double, _ color: Color) {
                    var path = Path()
                    path.addArc(
                        center: center, radius: radius,
                        startAngle: .degrees(180 + 180 * from),
                        endAngle: .degrees(180 + 180 * to),
                        clockwise: false
                    )
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 9, lineCap: .butt))
                }
                band(0, Self.lowCut, RiskLevel.low.color)
                band(Self.lowCut, Self.midCut, RiskLevel.medium.color)
                band(Self.midCut, 1, RiskLevel.high.color)

                let theta = (180 + 180 * min(max(score, 0), 1)) * .pi / 180
                let tip = CGPoint(x: center.x + (radius - 6) * cos(theta), y: center.y + (radius - 6) * sin(theta))
                var needle = Path()
                needle.move(to: center)
                needle.addLine(to: tip)
                context.stroke(needle, with: .color(.primary), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                context.fill(
                    Path(ellipseIn: CGRect(x: center.x - 3.2, y: center.y - 3.2, width: 6.4, height: 6.4)),
                    with: .color(.primary)
                )
            }
            .frame(width: 104, height: 64)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(score, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(level.color)
                }
                Text("AI 생성 가능성")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(level.label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(level.color)
                    .padding(.top, 4)
                Text("판독 모델 \(model)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .cardStyle()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI 생성 가능성 \(Int((score * 100).rounded()))퍼센트, \(level.label). 판독 모델 \(model)")
    }
}

// MARK: - 재생 컨트롤러

/// 결과 화면의 영상·음성 재생. 업로드용 `Data` 를 임시 파일로 써서 `AVPlayer` 에 물린다.
///
/// 타임라인의 구간을 누르면 그 시점으로 시크한다 — "1.0~2.5초 구간 의심"이라는 **문장**보다
/// 그 구간을 **직접 보고 듣는 것**이 근거로서 훨씬 강하다.
@MainActor
@Observable
final class PlaybackController {
    let player: AVPlayer
    private(set) var duration: Double = 0
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false

    private let fileURL: URL
    private var timeObserver: Any?

    init?(data: Data, fileExtension: String) {
        let url = URL.temporaryDirectory.appending(path: "veritae-play-\(UUID().uuidString).\(fileExtension)")
        do {
            try data.write(to: url)
        } catch {
            return nil
        }
        fileURL = url
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause

        // 0.1초마다 재생 위치를 받아 타임라인 헤드를 움직인다.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
            }
        }

        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            if let loaded = try? await asset.load(.duration) {
                self?.duration = loaded.seconds
            }
        }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            if duration > 0, currentTime >= duration - 0.05 {
                seek(to: 0)
            }
            player.play()
        }
        isPlaying.toggle()
    }

    /// 뷰가 사라질 때 호출한다 — 임시 파일을 지우고 관찰을 끊는다.
    func tearDown() {
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - 파형

/// 음성 파일에서 코스한 RMS 파형을 뽑는다. **실제 샘플에서 계산한 값**이다 — 결과 화면에
/// 장식용 가짜 파형을 그리면 "근거 없는 표시"를 만들지 않는다는 원칙이 깨진다.
///
/// `nonisolated` — 수 분짜리 음성은 샘플이 수백만 개라 메인 스레드에서 돌리면 화면이 멎는다(LL-002).
nonisolated enum WaveformLoader {
    static func load(url: URL, buckets: Int = 72) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard
            let track = try? await asset.loadTracks(withMediaType: .audio).first,
            let duration = try? await asset.load(.duration),
            let reader = try? AVAssetReader(asset: asset)
        else { return nil }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 16_000,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let totalSamples = max(1, Int(duration.seconds * 16_000))
        let perBucket = max(1, totalSamples / buckets)
        var sums = [Float](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)
        var index = 0

        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                  let pointer else { continue }
            let count = length / MemoryLayout<Float>.size
            pointer.withMemoryRebound(to: Float.self, capacity: count) { floats in
                for i in 0..<count {
                    let bucket = min(buckets - 1, index / perBucket)
                    let value = floats[i]
                    sums[bucket] += value * value
                    counts[bucket] += 1
                    index += 1
                }
            }
        }

        var rms = zip(sums, counts).map { sum, n -> Float in n > 0 ? (sum / Float(n)).squareRoot() : 0 }
        let peak = rms.max() ?? 0
        if peak > 0 { rms = rms.map { $0 / peak } }
        return rms
    }
}

// MARK: - 히어로 (원본 + 판독 오버레이)

/// 결과 화면의 주인공. 원본 위에 서버 히트맵을 얹고, 토글과 길게-누르기로 즉시 비교한다.
/// 얼굴 위의 붉은 블롭은 **참조 없이는 읽히지 않는다** — 원본과 나란히 봐야 의미가 생긴다.
///
/// 원본이 없는 서버 기록(`record.input == nil`)은 히트맵만 보여주고 토글을 숨긴다 — "원본"으로
/// 바꾸면 빈 상자가 나오기 때문이다. 원본도 히트맵도 없으면 `ResultView` 가 이 뷰를 아예 넣지 않는다.
struct MediaHeroView: View {
    let record: AnalysisRecord
    let playback: PlaybackController?
    let waveform: [Float]?
    @Binding var showOverlay: Bool
    @State private var isPressing = false
    /// 음성: 파형에서 누른 의심 구간. 캡션에 서버 `Evidence.title` 을 그대로 보여준다.
    @State private var selectedSegment: EvidenceItem?

    private var heatmap: UIImage? {
        record.evidenceImage.flatMap(UIImage.init(data:))
    }

    private var hasOriginal: Bool { record.input != nil }

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomLeading) {
                content
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipShape(.rect(cornerRadius: 20))

                // 영상만 배지. 음성은 캡션 줄 오른쪽에 시각을 넣는다 — 배지가 캡션과 겹쳤다(실측).
                if let playback, record.modality == .video {
                    Text(timestamp(playback.currentTime))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: .capsule)
                        .foregroundStyle(.white)
                        .padding(10)
                }
            }
            .onLongPressGesture(minimumDuration: 0.15, pressing: { isPressing = $0 }, perform: {})
            .accessibilityLabel(accessibilityDescription)

            if heatmap != nil, hasOriginal {
                Picker("표시", selection: $showOverlay) {
                    Text("판독 표시").tag(true)
                    Text("원본").tag(false)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let overlayVisible = !hasOriginal || (showOverlay && !isPressing)
        switch record.modality {
        case .audio:
            VStack(spacing: 0) {
                WaveformView(
                    samples: waveform,
                    segments: record.aiEvidence,
                    duration: playback?.duration ?? 0,
                    currentTime: playback?.currentTime ?? 0
                ) { t in
                    playback?.seek(to: t)
                    selectedSegment = record.aiEvidence.first { $0.timeRange?.contains(t) == true }
                }
                // 선택 구간 캡션 — 별도 타임라인 카드 대신 파형 바로 아래.
                HStack(spacing: 6) {
                    if let seg = selectedSegment, let r = seg.timeRange {
                        Text(String(format: "%.1f~%.1f초", r.lowerBound, r.upperBound))
                            .foregroundStyle(RiskLevel.high.color).fontWeight(.semibold).monospacedDigit()
                        Text("· \(seg.title)").lineLimit(1)
                    } else {
                        let n = record.aiEvidence.filter { $0.timeRange != nil }.count
                        Text(n > 0 ? "의심 구간 \(n)곳 — 붉은 부분을 누르면 이동" : "의심 구간이 검출되지 않았습니다")
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let playback {
                        Text(timestamp(playback.currentTime))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
            }
        case .video:
            ZStack {
                if let playback {
                    VideoPlayer(player: playback.player)
                        .disabled(true)
                } else {
                    Color.black
                }
                // 서버 히트맵은 가장 의심스러운 프레임 위에 합성된 완성 이미지다 — 토글이 켜지면
                // 그 이미지를 위에 얹는다(원본 프레임은 아래 플레이어가 보여준다).
                if let heatmap, overlayVisible {
                    Image(uiImage: heatmap).resizable().scaledToFill()
                        .transition(.opacity)
                }
            }
        case .image:
            ZStack {
                if let image = record.input?.previewImage {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.15)
                }
                if let heatmap, overlayVisible {
                    Image(uiImage: heatmap).resizable().scaledToFill()
                        .transition(.opacity)
                }
            }
        }
    }

    private var accessibilityDescription: String {
        let base: String
        switch record.modality {
        case .audio: base = "음성 파형"
        case .video: base = "영상 프레임"
        case .image: base = "분석한 이미지"
        }
        if heatmap == nil {
            return "\(base). 이 모델은 영역 표시를 제공하지 않습니다."
        }
        if !hasOriginal {
            return "\(base) 판독 표시. 원본은 기록에 보관되지 않습니다."
        }
        return "\(base). 판독 표시 \(showOverlay ? "켜짐" : "꺼짐"). 길게 누르면 원본."
    }

    private func timestamp(_ seconds: Double) -> String {
        String(format: "%.1fs", seconds)
    }
}

/// 실제 RMS 파형 + 의심 구간 강조. **파형 자체가 타임라인이다** — 어디든 누르면 그 시점으로
/// 시크하고, 붉은 구간을 누르면 그 근거가 선택된다. 음성에는 별도 타임라인 카드를 두지 않는다.
struct WaveformView: View {
    let samples: [Float]?
    let segments: [EvidenceItem]
    let duration: Double
    var currentTime: Double = 0
    var onSeek: ((Double) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let bars = samples ?? []
            let width = geo.size.width
            let barWidth = bars.isEmpty ? 0 : width / CGFloat(bars.count)
            ZStack(alignment: .leading) {
                Color(uiColor: .secondarySystemGroupedBackground)
                HStack(alignment: .center, spacing: barWidth * 0.3) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { i, v in
                        let t = duration > 0 ? Double(i) / Double(bars.count) * duration : 0
                        let hot = segments.contains { $0.timeRange?.contains(t) == true }
                        RoundedRectangle(cornerRadius: 1)
                            .fill(hot ? RiskLevel.high.color : Color.secondary.opacity(0.55))
                            .frame(width: barWidth * 0.7, height: max(3, CGFloat(v) * geo.size.height * 0.8))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 재생 헤드 — 시크·재생 위치가 파형 위에 바로 보여야 "여기"를 가리킬 수 있다.
                if duration > 0, onSeek != nil {
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 2)
                        .offset(x: CGFloat(min(max(currentTime, 0), duration) / duration) * width)
                        .animation(.linear(duration: 0.1), value: currentTime)
                }
                if bars.isEmpty {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let onSeek, duration > 0 else { return }
                onSeek(Double(location.x / width) * duration)
            }
        }
    }
}

// MARK: - 타임라인

/// 서버 `startSec/endSec` 를 마커로 그린다. 누르면 그 지점으로 시크하고 구간 문장을 보여준다.
///
/// `canSeek == false`(원본 미디어 없는 서버 기록)면 재생 막대를 숨기고, 누르면 구간 설명만 보여준다.
struct EvidenceTimelineView: View {
    let segments: [EvidenceItem]
    let duration: Double
    let currentTime: Double
    var canSeek = true
    var onSeek: (Double) -> Void

    @State private var selected: EvidenceItem?

    private var effectiveDuration: Double {
        if duration > 0 { return duration }
        return segments.compactMap { $0.timeRange?.upperBound }.max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("의심 구간 \(segments.count)곳")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(clock(effectiveDuration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(uiColor: .tertiarySystemGroupedBackground))

                    ForEach(segments) { seg in
                        if let range = seg.timeRange {
                            let x = CGFloat(range.lowerBound / effectiveDuration) * w
                            let width = max(3, CGFloat((range.upperBound - range.lowerBound) / effectiveDuration) * w)
                            Rectangle()
                                .fill(RiskLevel.high.color.opacity(0.28))
                                .overlay(Rectangle().stroke(RiskLevel.high.color, lineWidth: 1.5))
                                .frame(width: width)
                                .offset(x: x)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selected = seg
                                    onSeek(range.lowerBound)
                                }
                                .accessibilityLabel("의심 구간 \(seg.title), \(format(range.lowerBound))~\(format(range.upperBound))초")
                                .accessibilityAddTraits(.isButton)
                        }
                    }

                    if canSeek {
                        Rectangle()
                            .fill(Color.primary)
                            .frame(width: 2)
                            .offset(x: CGFloat(min(max(currentTime, 0), effectiveDuration) / effectiveDuration) * w)
                            .animation(.linear(duration: 0.1), value: currentTime)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    let t = Double(location.x / w) * effectiveDuration
                    selected = segments.first { $0.timeRange?.contains(t) == true }
                    onSeek(t)
                }
            }
            .frame(height: 36)

            HStack {
                Text("0:00").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                Spacer()
                Text(clock(effectiveDuration)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }

            // 서버가 준 근거 문장을 **그대로** 보여준다. 여기 문장은 서버 `Evidence.title/description` 이다.
            Group {
                if let selected, let range = selected.timeRange {
                    // 서버 `Evidence.title` 을 그대로 쓴다 — 클라가 문장을 만들지 않는다.
                    Text("\(format(range.lowerBound))~\(format(range.upperBound))초 · \(selected.title)")
                        .foregroundStyle(.primary)
                } else {
                    Text(canSeek ? "붉은 구간을 누르면 그 지점으로 이동합니다" : "붉은 구간을 누르면 설명이 표시됩니다")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .frame(minHeight: 17, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func format(_ s: Double) -> String { String(format: "%.1f", s) }
    private func clock(_ s: Double) -> String {
        let total = Int(s.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
