# Talking Head on Apple Watch — 구현 설계

## 개요

THA3 ML 모델을 Watch에서 직접 돌리는 게 아니라,
**키프레임을 Mac에서 미리 렌더링 → Watch에서 델타 블렌딩**으로 실시간 애니메이션.

---

## 아키텍처

```
[Mac/iPhone]                          [Apple Watch]
  THA3 렌더 → 키프레임 PNG들            키프레임 로드
  phoneme 분석 → timeline.json    →     Metal 블렌딩
  Fish Audio → audio.m4a                오디오 재생 + 타임라인 동기화
```

---

## 1단계: Mac에서 키프레임 생성

### 렌더할 파라미터 조합

| 이름 | eye_wink | mouth_aaa | 용도 |
|------|----------|-----------|------|
| base | 0.0 | 0.0 | 기준 프레임 |
| eye_half | 0.5 | 0.0 | 눈 반쯤 |
| eye_closed | 1.0 | 0.0 | 눈 완전 감음 |
| mouth_half | 0.0 | 0.5 | 입 반열림 |
| mouth_open | 0.0 | 1.0 | 입 완전 열림 |

### 델타 계산

```python
# Mac에서 THA3로 키프레임 렌더 후
delta_eye   = eye_closed_img  - base_img   # float32 [-1, 1]
delta_mouth = mouth_open_img  - base_img

# PNG로 저장 (0.5 offset 적용해서 uint8로)
save_delta(delta_eye,   "delta_eye.png")
save_delta(delta_mouth, "delta_mouth.png")
save_as_png(base_img,   "base.png")
```

### phoneme 타임라인 JSON

```json
{
  "duration": 7.62,
  "events": [
    { "t": 0.00, "mouth": 0.8 },
    { "t": 0.14, "mouth": 0.0 },
    { "t": 0.28, "mouth": 1.0 },
    ...
  ]
}
```

Whisper + pyopenjtalk로 생성 (기존 파이프라인 재사용).

---

## 2단계: Watch 앱 구조

```
WatchApp/
├── Assets/
│   ├── base.png          512×512 기준 프레임
│   ├── delta_eye.png     눈 감김 델타
│   └── delta_mouth.png   입 열림 델타
├── Resources/
│   ├── audio.m4a         TTS 오디오
│   └── timeline.json     phoneme 타임라인
└── Sources/
    ├── TalkingHeadView.swift   Metal 렌더러
    ├── AnimationController.swift  타임라인 재생
    └── ContentView.swift
```

---

## 3단계: Metal 블렌딩 셰이더

```metal
// TalkingHeadShader.metal
fragment float4 blendFragment(
    float2 uv            [[ stage_in ]],
    texture2d<float> base        [[ texture(0) ]],
    texture2d<float> deltaEye    [[ texture(1) ]],
    texture2d<float> deltaMouth  [[ texture(2) ]],
    constant float& eyeWeight    [[ buffer(0) ]],
    constant float& mouthWeight  [[ buffer(1) ]]
) {
    float4 b  = base.sample(s, uv);
    float4 de = deltaEye.sample(s, uv)   * 2.0 - 1.0;  // [-1,1] 복원
    float4 dm = deltaMouth.sample(s, uv) * 2.0 - 1.0;

    float4 out = b + eyeWeight * de + mouthWeight * dm;
    return clamp(out, 0.0, 1.0);
}
```

---

## 4단계: 애니메이션 컨트롤러

```swift
// AnimationController.swift
class AnimationController: ObservableObject {
    @Published var eyeWeight: Float   = 0.0
    @Published var mouthWeight: Float = 0.0

    private var timeline: [PhonemeEvent] = []
    private var player: AVAudioPlayer?
    private var displayLink: Timer?

    func play(audio: URL, timeline: URL) {
        self.timeline = loadTimeline(timeline)
        player = try? AVAudioPlayer(contentsOf: audio)
        player?.play()
        displayLink = Timer.scheduledTimer(withTimeInterval: 1/60, repeats: true) { _ in
            self.update()
        }
    }

    private func update() {
        let t = player?.currentTime ?? 0

        // 입: timeline에서 현재 시간의 mouth 값 보간
        mouthWeight = interpolate(timeline: timeline, at: t)

        // 눈: sin 곡선으로 주기적 깜박임
        eyeWeight = blinkCurve(t: t)
    }

    private func blinkCurve(t: Double) -> Float {
        // 3~5초마다 0.15초 동안 깜박임
        let period = 4.0
        let phase = t.truncatingRemainder(dividingBy: period)
        if phase < 0.15 {
            return Float(sin(.pi * phase / 0.15))
        }
        return 0.0
    }
}
```

---

## 5단계: SwiftUI View

```swift
// TalkingHeadView.swift
struct TalkingHeadView: View {
    @StateObject var controller = AnimationController()

    var body: some View {
        MetalView(
            base:        UIImage(named: "base")!,
            deltaEye:    UIImage(named: "delta_eye")!,
            deltaMouth:  UIImage(named: "delta_mouth")!,
            eyeWeight:   controller.eyeWeight,
            mouthWeight: controller.mouthWeight
        )
        .onTapGesture {
            controller.play(
                audio:    Bundle.main.url(forResource: "audio", withExtension: "m4a")!,
                timeline: Bundle.main.url(forResource: "timeline", withExtension: "json")!
            )
        }
    }
}
```

---

## 6단계: iPhone 연동 (실시간 생성)

Watch 단독으로 고정 문구만 재생하는 게 아니라  
임의 텍스트를 말하게 하려면:

```
사용자 입력 (Watch 또는 iPhone)
    ↓
iPhone: Fish Audio API → audio.m4a
iPhone: Whisper + pyopenjtalk → timeline.json
    ↓
WatchConnectivity로 Watch에 전송
    ↓
Watch: 재생
```

```swift
// iPhone side
session.transferFile(audioURL, metadata: ["type": "audio"])
session.transferFile(timelineURL, metadata: ["type": "timeline"])

// Watch side
func session(_ session: WCSession, didReceive file: WCSessionFile) {
    if file.metadata?["type"] as? String == "audio" {
        // 저장 후 재생
    }
}
```

---

## 필요 파일 요약

| 파일 | 생성 방법 | 크기 |
|------|-----------|------|
| `base.png` | THA3 (pose 전부 0) | ~200KB |
| `delta_eye.png` | THA3 eye_wink=1.0 − base | ~200KB |
| `delta_mouth.png` | THA3 mouth_aaa=1.0 − base | ~200KB |
| `audio.m4a` | Fish Audio TTS | ~500KB/10초 |
| `timeline.json` | Whisper + pyopenjtalk | ~5KB |

---

## 구현 순서

1. **키프레임 생성 스크립트** — THA3로 base/delta PNG 3장 뽑기
2. **timeline JSON 생성** — 기존 파이프라인 수정
3. **Xcode watchOS 프로젝트** — MetalView + AnimationController
4. **(선택) iPhone 앱** — WatchConnectivity 연동, 실시간 생성
