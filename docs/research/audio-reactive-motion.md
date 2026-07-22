# 当前播放音频随动：现状诊断与改进方案

日期：2026-07-21

## 实施状态

Phase 1 基线已于 2026-07-21 落地：现有音频 tap 现在使用 2048/512 的固定窗、Hann + vDSP FFT、四频带独立包络、带自适应阈值的正向谱通量和 source time 诊断快照；现有 Canvas 已按低频、低中频、中高频、高频和 onset 重新分配动态职责。在线 tempo/beat phase、带时间戳的帧环和渲染插值仍保留在 Phase 2。

## 结论

保留现在的「7 条蚀刻波纹 + 微弱游光」视觉样式，重做它下面的音频驱动层。

当前效果不够“跟音乐”，主要不是画法问题，而是信号模型只有一个全频 RMS：低鼓、贝斯、人声、镲片和整体音量变化最终都被压成同一个数；所谓 onset 也只是 RMS 的快慢包络之差；所谓节奏则只是相邻 onset 间隔。最终动画能分辨“更响/更轻”，却难以稳定分辨“哪里发生了打击、哪个频段在运动、下一拍何时到来”。

推荐方案是原生实现一条轻量实时分析链：

1. 固定 hop 的单声道 PCM 环形缓冲；
2. Hann 窗 + vDSP FFT；
3. 4 个感知频段的独立能量与 attack/release 包络；
4. 基于 Mel/对数频带正向谱通量的 onset，配自适应阈值、局部峰值和最小触发间隔；
5. onset 历史上的轻量在线 tempo 候选与置信度；
6. 带时间戳的特征快照，渲染侧插值并在高置信度时锁定 beat phase。

落地优先级应是：**先做好多频带 + onset + 时间对齐，再做 beat tracker**。前者会直接修复大部分“明明听到鼓点，画面却只是在匀速漂”的问题；后者负责让长周期运动更稳，而不应成为每次瞬态反馈的前置条件。

## 范围

本方案只改“音乐如何驱动现有图案”，不建议更换视觉风格、增加频谱柱、换封面动效或引入新的视觉主体。

保留：

- 7 条波纹、斜向细纹、游光、现有明暗层次；
- 播放时运动、暂停时冻结；
- 当前播放行的尺寸和信息层级。

改进：

- 音频特征提取；
- onset、节奏与相位；
- 平滑、归一化和视觉参数映射；
- 音频到画面的时间对齐；
- 可测量的质量基线。

## 当前实现

### 信号路径

当前通过 `MTAudioProcessingTap` 读取 `AVPlayerItem` 的 PCM，这个入口是合理的，无需更换播放器架构。Apple 也将 `MTAudioProcessingTap` 定义为从 `AVPlayer` 获取音频的机制；`MTAudioProcessingTapGetSourceAudio` 还能返回每批样本对应的 asset time range。[Apple Media Toolbox](https://developer.apple.com/documentation/mediatoolbox)、[MTAudioProcessingTapGetSourceAudio](https://developer.apple.com/documentation/mediatoolbox/mtaudioprocessingtapgetsourceaudio%28_%3A_%3A_%3A_%3A_%3A_%3A%29)

仓库中的实际路径是：

```text
AVPlayerItem
  -> PostEffects MTAudioProcessingTap
  -> 遍历 PCM，计算一个全频 RMS
  -> AudioMotionEstimator
       energy = RMS 转 dB 后 attack/release 平滑
       onset  = fast RMS envelope - slow RMS envelope
       pace   = 相邻 onset 间隔折算 BPM
       phase  = pace + pulse 决定的积分速度
  -> TimelineView(30 fps)
  -> 7 条正弦波纹 + 游光
```

对应实现见 [`AudioReactiveLevel.swift`](../../Sources/AnnoyO/AudioReactiveLevel.swift) 和 [`AnimatedPlaybackPattern`](../../Sources/AnnoyO/MenuBarView.swift)。现有测试只验证“快的脉冲序列比慢的 `pace` 大”和“响的 RMS 比轻的 `energy` 大”，还不能覆盖真实音乐的频段差异、误触发、节拍相位或延迟，见 [`verifyAudioMotionEstimator`](../../Tests/AnnoyOChecks/main.swift)。

### 为什么它会显得“不跟”

#### 1. 全频 RMS 丢失了最重要的区别

`AudioSignalAccumulator.consume` 把所有声道和样本的平方求和后只输出一个 RMS。两个片段即使 RMS 相同，一个是低频 kick，另一个是持续人声，当前动画收到的输入也相同。

这不只是“少几个参数”：现有 7 条波纹的振幅、透明度、游光半径最终都共享 `energy` 和 `pulse`，没有任何信号可以让低频推动整体起伏、让中频改变形态、让高频只影响细小纹理。

#### 2. 当前 onset 本质上仍是 RMS 变化

当前 onset 为 `max(0, fastEnvelope - slowEnvelope)`，阈值为 `max(0.0045, slowEnvelope * 0.18)`。它会遇到三类典型问题：

- 整体音量上升可能被当作击打；
- 母带压缩较强、整体 RMS 变化小的音乐，清晰鼓点也可能触发不足；
- 持续人声、吉他扫弦与低鼓无法按频谱变化区分。

Essentia 的 onset 算法文档把 RMS 方法描述为“整体能量通量”，而 spectral flux 描述的是相邻频谱幅度的变化；它还单列了在 Mel 频带上计算半波整流差分的 `melflux`。这正好解释了当前 RMS-only 检测为什么信息不足。[Essentia OnsetDetection](https://essentia.upf.edu/reference/streaming_OnsetDetection.html)

#### 3. `pace` 不是稳定的节拍估计

每次触发后，当前代码直接把“距上次 onset 的时间”当作候选 beat interval；大于 0.85 秒就反复除以 2，再用固定比例写入 `beatInterval`。在反拍、切分、连续 hi-hat、半拍/双拍或漏检时，这个值很容易跳到错误的节奏层级。

更关键的是，`phase` 只是按一个受 `pace` 和 `pulse` 影响的速度持续积分；onset 到来时只会短暂加速，并不会把波纹的视觉峰值对齐到这次击打。因此即使 BPM 数值大致正确，画面峰值也可能一直与听到的拍点错开。

成熟节拍分析会分别输出 tempo、beat positions 和 confidence，而不是只保留一个相邻间隔。Essentia 的 `RhythmExtractor2013` 就把三者作为独立结果；其官方教程同时说明该算法依赖整轨统计，不适合直接用作本项目的实时首播方案。[RhythmExtractor2013](https://essentia.upf.edu/reference/std_RhythmExtractor2013.html)、[Essentia beat detection tutorial](https://essentia.upf.edu/tutorial_rhythm_beatdetection.html)

#### 4. 特征更新时钟与显示时钟没有对齐

当前 `MTAudioProcessingTapGetSourceAudio` 的 `timeRangeOut` 传入 `nil`，特征快照没有媒体时间；Canvas 以 30 fps 读取“此刻锁里最新的值”。这带来两个问题：

- 音频回调按不固定批量更新，`phase` 可能保持后跳变；
- 无法判断这批特征对应的是即将播放、正在听到还是已经播放的 PCM，也无法补偿设备输出链路差异。

Apple 的 API 明确可以返回源音频帧对应的 asset time range；tap flags 也标记连续流的开始与结束。当前两者都没有进入分析状态管理。[MTAudioProcessingTapGetSourceAudio](https://developer.apple.com/documentation/mediatoolbox/mtaudioprocessingtapgetsourceaudio%28_%3A_%3A_%3A_%3A_%3A_%3A%29)、[MTAudioProcessingTapFlags](https://developer.apple.com/documentation/mediatoolbox/mtaudioprocessingtapflags)

#### 5. 平滑只有一套，连续量与事件量混在一起

`energy` 用一组 attack/release，`pulse` 用指数衰减，`phase` 又被 `pulse` 改速。于是一个击打同时改变振幅、速度和游光运动，容易产生“被推了一下”而不是“拍点落下”的感觉。

Web Audio 规范中的分析器先做频域分析，再对每个 FFT bin 做独立的时间平滑，并明确给出 `previous * τ + current * (1 - τ)`；这提供了一个有用的工程参照：**频率分解与时间平滑是两个阶段，平滑不能代替频率信息**。[Web Audio API 1.1, AnalyserNode FFT windowing and smoothing](https://www.w3.org/TR/webaudio-1.1/#fft-windowing-and-smoothing-over-time)

## 候选方案比较

| 方案 | 能改善什么 | 主要限制 | 结论 |
| --- | --- | --- | --- |
| A. 继续调 RMS 阈值和 EMA | 呼吸感、强弱过渡 | 仍无法区分频段；onset 和 tempo 的根因不变 | 只适合临时微调，不建议作为正式解法 |
| B. 原生 vDSP 多频带 + spectral flux + 轻量在线节拍相位 | 能量、音色运动、瞬态、节奏与延迟都可控；可复用当前 tap 和 Canvas | 需要建立 DSP 测试和参数标定 | **推荐** |
| C. 直接嵌入 aubio / Essentia | 现成的多种 onset、tempo、beat 算法 | C/C++ 集成、包体和调试复杂；aubio 为 GPL-3.0，Essentia 为 AGPL-3.0，需单独做许可证评估 | 不建议作为 AnnoyO 第一选择 |
| D. 整轨预分析并缓存 beat grid | 后续播放可得到稳定的整曲 tempo/beat positions | 首次播放需要下载/解码进度；不解决开播前几秒；状态和缓存复杂 | 可作为第三阶段的混合增强，不作为基础方案 |

aubio 官方文档列出了 energy、HFC、complex、phase、spectral difference 和 spectral flux 等 onset 方法，其 peak picker 还把检测阈值、静音阈值和最小 onset 间隔设为独立参数；这证明完整 onset 链路不应只有“一个差值 + 一个阈值”。[aubio spectral features](https://aubio.org/manual/latest/py_spectral.html)、[aubio onset API](https://aubio.org/doc/latest/onset_8h.html) 但 aubio 官方仓库采用 GPL-3.0，Essentia 官方仓库采用 AGPL-3.0；当前原生 Swift 工程没有必要为了本次目标先引入这两套完整依赖。[aubio repository](https://github.com/aubio/aubio)、[Essentia repository](https://github.com/MTG/essentia)

## 推荐技术方案

### 总体架构

```text
MTAudioProcessingTap process callback
  -> PCM 格式归一化、声道下混
  -> 预分配环形缓冲（固定 hop）
  -> FeatureExtractor
       ├─ broadband RMS / loudness proxy
       ├─ Hann + vDSP FFT
       ├─ 4-band log energy
       ├─ per-band attack/release + adaptive normalization
       └─ positive spectral flux -> adaptive peak picker
  -> OnlineRhythmTracker
       ├─ onset history
       ├─ tempo candidates + confidence
       └─ phase-locked beat clock
  -> timestamped AudioMotionFrame ring
  -> TimelineView render clock
       ├─ 根据媒体时间选择/插值 frame
       └─ 映射到现有波纹参数
```

FFT 和窗函数无需第三方库。Apple Accelerate 的 vDSP 提供优化的 FFT 与向量运算；Apple 也明确建议在对非整数周期信号做 Fourier transform 前使用 window 来降低 spectral leakage，并把 Hann 列为通用选择。[Apple Accelerate](https://developer.apple.com/documentation/accelerate)、[vDSP Hann window](https://developer.apple.com/documentation/accelerate/vdsp_hann_window)、[Reducing spectral leakage with windowing](https://developer.apple.com/documentation/accelerate/reducing-spectral-leakage-with-windowing)

### 1. PCM 与分析帧

建议初始参数（这是项目调参起点，不是固定标准）：

- 下混为 mono；
- FFT size：2048；
- hop size：512；
- Hann window；
- 以实际 sample rate 计算频率 bin，不假设恒为 44.1 kHz 或 48 kHz；
- 在 tap 的 `prepare` 阶段预分配 window、FFT workspace、ring buffer 和输出数组，process 回调内不做动态分配。

2048/512 在 48 kHz 下约对应 42.7 ms 的观察窗和 10.7 ms 的更新步长；在 44.1 kHz 下约为 46.4 ms 和 11.6 ms。固定 hop 的意义是让分析更新率不受 AVPlayer 每次回调 frame count 变化影响。

如果实测 CPU 余量很大而瞬态仍显迟，可 A/B 1024/256；如果低频稳定性不足，再比较 2048/512。不要在没有端到端延迟记录的情况下只凭窗口大小猜测。

### 2. 多频带能量

第一版不需要做几十根可视频谱柱，4 个聚合频带足够驱动现有图案：

| 频带（初始值） | 主要用途 | 视觉职责 |
| --- | --- | --- |
| 40–180 Hz `low` | kick、bass 的主体运动 | 波纹整体振幅、游光半径的短促推动 |
| 180–700 Hz `lowMid` | 厚度、低中频律动 | 波纹间层次、较慢的形变 |
| 700–3500 Hz `midHigh` | 人声、军鼓、旋律清晰度 | 第二波形的形变权重、局部线条强弱 |
| 3500–10000 Hz `high` | hi-hat、attack、空气感 | 很小的细纹/透明度变化，不推动整体位移 |

每个频带先聚合 power，再转对数域；随后分别做：

- 快速 attack、较慢 release；
- 慢速 rolling floor / rolling upper level；
- 在自身动态范围内归一化到 0…1；
- 静音门控，避免底噪让图案持续抖动。

这使同一首歌中轻重段落可见，也避免不同母带响度导致“有些歌完全不动，有些歌一直顶满”。建议的初始 envelope 时间常数：低频 attack 20–35 ms / release 140–220 ms，中频 12–25 / 90–160 ms，高频 5–15 / 50–100 ms；最终以 A/B 结果为准。

### 3. onset：从 RMS 差值换成正向谱通量

建议在对数频带或 Mel-like 三角频带上计算：

```text
flux(t) = sum_i max(0, logMag_i(t) - logMag_i(t-1))
```

只累加正向变化，持续稳定的频谱不会反复触发；再依次执行：

1. 频带白化或按本频带滚动能量归一，防止低频长期支配；
2. 最近约 0.8–1.5 秒 novelty 的 median + MAD/偏置作为自适应阈值；
3. 局部峰值选择；
4. 80–120 ms 的最小 inter-onset interval；
5. 输出连续的 `onsetStrength`，不要只输出 Bool；
6. `pulse` 使用快速出现、90–160 ms 衰减的单独 envelope。

Essentia 的 SuperFlux 实现也是先把频谱汇总到三角频带，再用 spectral flux 和最大值滤波形成 novelty，最后做峰值检测；其目的之一是减少谱轨迹变化造成的误触发。[Essentia SuperFluxExtractor](https://essentia.upf.edu/reference/streaming_SuperFluxExtractor.html) 第一版不必完整复刻 SuperFlux，但“频带差分 + 自适应峰值选择”是值得采用的结构。

### 4. tempo 与 beat phase：让长周期运动稳定，不阻塞瞬态反馈

把 onset 和 beat 分成两条职责：

- onset 负责“现在发生了一次清晰攻击”，立即驱动短促的视觉 pulse；
- beat tracker 负责“这些攻击是否形成稳定周期”，只驱动较慢的相位和周期呼吸。

建议在线 tracker：

1. 保留最近 4–8 秒 onset novelty；
2. 每 200–500 ms 更新一次自相关或 tempogram 候选；
3. 在产品常见范围内维护多个 tempo candidate，并显式比较 half/double tempo；
4. 综合候选突出度、近期相位残差和连续性得到 `tempoConfidence`；
5. 用 phase-locked oscillator 预测下一拍；附近 onset 只做小幅相位校正，不每次硬跳；
6. `tempoConfidence` 低时退回中性慢速漂移，绝不让不可靠 BPM 造成忽快忽慢。

完整节拍系统本来就会把 period、phase 和 confidence 分开处理。Essentia 的 `TempoTap` 家族接收能量频带/onset detection functions 并估计 period 与 phase；`TempoTapMaxAgreement` 再以候选间的一致程度输出 confidence。[Essentia algorithms reference](https://essentia.upf.edu/algorithms_reference.html#rhythm) 本项目可借鉴这个数据边界，而不引入其 AGPL 实现。

### 5. 时间戳与延迟对齐

特征正确但时间错，仍会被感知为“不跟”。建议：

- 从 `MTAudioProcessingTapGetSourceAudio` 读取 `timeRangeOut`，每个分析 hop 保留 source media time；
- `AudioMotionFrame` 至少包含 `sourceTime`、band envelopes、onset strength、beat phase/confidence；
- 渲染侧根据当前播放媒体时间选取前后两帧并插值连续量；onset 是事件量，按目标呈现时间调度，不做跨越峰值的普通线性平均；
- stream start、换曲、seek 和不连续后清空 FFT 历史、rolling normalization、onset peak picker 与 tempo candidates，避免上一段音乐污染下一段；
- 保留一个可标定的 `visualSyncOffset`，用本机扬声器/有线输出的 click track 实测后设默认值；外接设备造成的大延迟不应靠固定常数假装解决。

Apple 的 API 已提供 source audio 对应的 `CMTimeRange`，因此这里不需要另造 wall-clock 猜测。[MTAudioProcessingTapGetSourceAudio](https://developer.apple.com/documentation/mediatoolbox/mtaudioprocessingtapgetsourceaudio%28_%3A_%3A_%3A_%3A_%3A_%3A%29) 不同音频输出链路确实可能有 presentation latency；Apple 在音频节点 API 中也将它定义为节点下游到实际呈现的最大延迟。[AVAudioNode outputPresentationLatency](https://developer.apple.com/documentation/avfaudio/avaudionode/outputpresentationlatency) 对 AnnoyO 而言，最终仍应以 AVPlayer 实际播放链路的测量结果为准。

### 6. 渲染侧映射：保留样式，只重分职责

建议把当前“几个信号同时改很多参数”改成下表。映射值均需限制幅度，避免现有低对比蚀刻风格变成频谱表演。

| 现有视觉参数 | 新驱动信号 | 映射原则 |
| --- | --- | --- |
| 7 条波纹整体 amplitude | `0.55 * low + 0.30 * lowMid + 0.15 * broadband` | 低频推动整体，但保留慢 release |
| secondary wave 的幅度/相位偏移 | `midHigh` 的平滑包络 | 人声/军鼓改变形态，不推动整块位移 |
| 强线透明度 | broadband slow envelope | 只表达段落强弱，不对每个 onset 闪烁 |
| 短促形变 | `onsetStrength` / `pulse` | attack 快、release 短，与拍点直接对应 |
| 游光半径 | `low` slow envelope + 很小的 pulse | 保持“呼吸”，避免每拍爆闪 |
| 游光位置、主波流动 | render-time `flowPhase` | 连续匀滑；仅在 beat confidence 高时轻度锁相 |
| 周期性呼吸 | `beatPhase * tempoConfidence` | 低置信度自动淡出，不显示错误节拍 |
| 细纹存在感 | `high` slow envelope | 幅度很小，只提供质感反馈 |

`AudioMotionSnapshot` 也应从目前的 `energy / pace / pulse / phase` 扩展为事实更清楚的数据，而不是继续把所有含义塞进四个数：

```text
sourceTime
broadbandEnergy
low / lowMid / midHigh / high
onsetStrength
tempoBPM / tempoConfidence
beatPhase
```

`flowPhase` 建议在渲染侧按时间连续计算，再受 `beatPhase` 小幅校正；不要继续只在音频 callback 到来时累加。渲染可从 30 fps 提升到 60 fps 并对特征插值，解决短 pulse 的量化和 callback 间的停跳；但单纯提帧率不会修复错误的 onset 或时间戳。

### 7. 交互与视觉原则

1. **因果关系优先于变化数量**：kick 应先被看成一次清楚的整体推动，持续声部则是较慢呼吸；不要让每个信号同时控制位移、速度、亮度和尺度。
2. **事件量与连续量分离**：onset 是短事件，band energy 是连续包络，beat phase 是周期状态，三者各自平滑。
3. **低置信度时宁可平静**：错误锁拍比不锁拍更明显。没有可靠节奏时保持稳定慢流，而不是每次 onset 重算速度。
4. **跨曲目自适应但不追着瞬时峰值跑**：rolling normalization 的时间尺度应明显慢于音乐 pulse。
5. **暂停/seek 是状态边界**：暂停冻结视觉时间；seek/换曲清分析历史；resume 不制造一次假 onset。
6. **保持低对比**：高频只作用于细节，pulse 不使用大面积高亮或闪烁。
7. **尊重 Reduce Motion**：SwiftUI 暴露了 `accessibilityReduceMotion`；开启时应保留轻微能量呼吸，关闭持续横向游走和明显 beat pulse。[SwiftUI accessibilityReduceMotion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)、[Apple HIG Motion](https://developer.apple.com/design/human-interface-guidelines/motion)

## 分阶段落地

### Phase 0：先建立可观测性，不改视觉

- 记录每个 hop 的 source time、RMS、4-band raw/normalized energy、flux、threshold、onset、BPM/confidence、render time；
- 加一个仅 Debug 可用的 CSV 导出或日志开关；
- 准备 6 类固定素材：click/kick train、持续正弦、音量渐变、EDM、流行人声、古典/弱拍音乐；
- 对当前 RMS-only 方案记录误触发、漏触发和声画偏移，形成 baseline。

完成标准：能从一次播放记录中回答“这次画面为什么动、为什么没动、特征对应哪个媒体时间”。

### Phase 1：多频带 + spectral-flux onset，复用现有 Canvas

- 建固定-hop PCM ring、Hann/vDSP FFT、4-band energy；
- 做每带归一和独立 attack/release；
- 做 spectral flux、自适应阈值、最小 onset 间隔；
- 先把结果映射回现有 amplitude、secondary、opacity、glow 和 pulse；
- 暂时保留稳定的中性 `flowPhase`，不急于估 BPM。

完成标准：在不改变图案样式的情况下，kick、持续人声和 hi-hat 呈现不同职责；同 RMS 不同频谱的素材不再产生同样运动；持续音在起音后不反复触发 onset。

### Phase 2：时间对齐 + 在线 tempo/beat phase

- 接入 source media time 和 timestamped frame ring；
- 渲染侧插值，事件按媒体时间呈现；
- 加 tempo candidates、confidence 和 phase-locked beat clock；
- 仅在 confidence 达标后让 beat phase 影响周期性呼吸；
- A/B 30 fps 与 60 fps，确认 CPU、能耗和观感。

完成标准：本机扬声器/有线输出 click track 的声画误差稳定；反拍或 hi-hat 密集时不会频繁 half/double tempo 跳变；低置信度音乐回退为平稳慢流。

### Phase 3：按证据决定是否做整轨/前瞻分析

如果 Phase 2 在真实曲目上仍有“开播前几秒未锁拍”或复杂节奏不稳，再利用已缓存音频做后台 look-ahead/整轨 beat grid，并让在线 onset 负责瞬态修正。没有测试证据前，不建议先增加这层复杂度。

## 验证方案与建议质量门

以下是 AnnoyO 的建议验收目标，不是外部标准：

### 单元与合成信号

- **频带区分**：保持 RMS 相同的 100 Hz、1 kHz、6 kHz 信号，应分别主要进入 low、midHigh、high；
- **onset 单次性**：一次幅度阶跃后只触发一次，随后持续音不重复触发；
- **动态范围**：同一节奏的 -24 dB 与 -6 dB 版本在归一稳定后应有近似 pulse，而 overall strength 仍保留差别；
- **节拍稳定**：120 BPM click/kick 在 4–8 秒窗口后，候选稳定在 120 BPM 附近，不被每拍附加的 hi-hat 拉到 240；
- **状态边界**：换曲、seek、暂停恢复不会携带旧 tempo 或制造假 onset；
- **buffer 无关性**：把同一 PCM 切成不同 callback frame count，输出的固定-hop 特征序列应一致。

### 端到端声画

- 制作带明显 click 的本地测试音频，同步录制系统音频与屏幕；
- 从 onset 的音频峰值和波纹短促形变的画面帧计算偏差；
- 初始质量门建议设为本机/有线输出 `p95 absolute sync error <= 50 ms`，并记录 lead/lag 方向；
- 对 30/60 fps、1024/256 与 2048/512 两组配置做相同测试，不凭主观印象选参数。

### 主观 A/B

固定 10–15 首覆盖不同母带与节奏的片段，隐藏版本信息，逐项评价：

- 鼓点是否“落在画面上”；
- 人声持续段是否自然呼吸而非抖动；
- hi-hat 是否只增加细节、不牵动整块背景；
- 弱拍/古典段是否平稳而不乱猜节拍；
- 连续观看是否会觉得闪、躁或抢文字。

只有 Phase 1 相比当前方案在“拍点对应”和“不过度运动”两项都稳定更好，才进入 Phase 2 的 tempo 调参。

## 最终建议

不要继续围绕 `fastEnvelope / slowEnvelope / onsetThreshold` 做局部调参，也不要先更换视觉样式。

最薄且正确的改造边界是 `AudioReactiveLevel`：保留 `MTAudioProcessingTap`，在这里把 PCM 变成带时间戳的多频带、onset 与节奏置信度；`AnimatedPlaybackPattern` 仍负责当前蚀刻波纹，只接受更有语义、时间已对齐的运动参数。第一版只做 Phase 0–1 就足以验证方向；Phase 2 是否值得做，以声画误差记录和真实曲目 A/B 为准。
