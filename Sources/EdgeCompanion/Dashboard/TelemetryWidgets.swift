import SwiftUI

/// Picks the widget for a telemetry kind. Each widget retains its metric while on screen,
/// so readers only run for what is actually visible.
struct TelemetryWidget: View {
  let kind: WidgetKind
  /// Identifies the tile, for widgets with their own pages.
  let slotID: UUID
  private var hub: TelemetryHub { TelemetryHub.shared }

  var body: some View {
    switch kind {
    case .cpu: CPUWidget(cpu: hub.cpu).retaining(.cpu)
    case .gpu: GPUWidget(gpu: hub.gpu).retaining(.gpu)
    case .memory: MemoryWidget(memory: hub.memory).retaining(.memory)
    case .network: NetworkDiskWidget(id: slotID, net: hub.network, disk: hub.disk).retaining(.network).retaining(.disk)
    case .sensors: SensorsWidget(sensors: hub.sensors).retaining(.sensors)
    case .battery: BatteryWidget(battery: hub.battery, bluetooth: hub.bluetooth, sensors: hub.sensors).retaining(.battery).retaining(.bluetooth).retaining(.sensors)
    case .system: SystemWidget(id: slotID, system: hub.system, cpu: hub.cpu).retaining(.system).retaining(.cpu)
    case .clock, .launcher, .aiUsage, .timer, .volume, .spacer: EmptyView()
    }
  }
}

private struct RetainMetric: ViewModifier {
  let kind: MetricKind
  func body(content: Content) -> some View {
    content
      .onAppear { TelemetryHub.shared.retain(kind) }
      .onDisappear { TelemetryHub.shared.release(kind) }
  }
}

extension View {
  func retaining(_ kind: MetricKind) -> some View { modifier(RetainMetric(kind: kind)) }
}

/// Big value with a small caption, used across widgets.
private struct Stat: View {
  let label: String
  let value: String
  var tint: Color = Theme.textPrimary
  var size: CGFloat = 20

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(Theme.number(size)).foregroundStyle(tint).lineLimit(1)
      Text(label).font(Theme.text(12.5, weight: .medium)).foregroundStyle(Theme.textTertiary).lineLimit(1)
    }
  }
}

// MARK: - CPU

private struct CPUWidget: View {
  let cpu: CPUModel

  var body: some View {
    WidgetCard {
      VStack(alignment: .leading, spacing: 14) {
        Spacer(minLength: 0)
        HStack(alignment: .center, spacing: 20) {
          ZStack {
            RingGauge(value: cpu.usage, tint: Theme.cpu, lineWidth: 11, gradient: [Theme.cpu.opacity(0.55), Theme.cpu, Color(red: 0.55, green: 0.95, blue: 0.85)])
            VStack(spacing: 0) {
              Text(Format.percent(cpu.usage)).font(Theme.number(27, weight: .bold)).foregroundStyle(Theme.textPrimary)
              Text("CPU").font(Theme.text(12.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            }
          }
          .frame(width: 108, height: 108)
          VStack(alignment: .leading, spacing: 12) {
            ForEach(cpu.clusters) { cluster in
              ClusterCores(title: clusterLabel(cluster), usage: cluster.usage,
                           values: cluster.cores.compactMap { cpu.perCore.indices.contains($0) ? cpu.perCore[$0] : nil },
                           tint: cluster.kind == .efficiency ? Theme.cpuEfficiency : Theme.cpu)
            }
          }
        }
        HStack(spacing: 6) {
          Text(tr("부하", "Load")).foregroundStyle(Theme.textTertiary)
          Text(String(format: "%.1f · %.1f · %.1f", cpu.loadAverage.one, cpu.loadAverage.five, cpu.loadAverage.fifteen)).foregroundStyle(Theme.textSecondary)
        }
        .font(Theme.number(12.5, weight: .medium))
        Sparkline(values: GraphScale.smoothed(cpu.history), tint: Theme.cpu, maxValue: 1, guides: [1, 0.5])
          .frame(height: GraphScale.trendHeight)
          .padding(.top, 10)
        Spacer(minLength: 0)
      }
    }
  }

  private func clusterLabel(_ c: CPUCluster) -> String {
    switch c.kind {
    case .efficiency: return tr("효율 코어", "Efficiency")
    case .performance: return tr("성능 코어", "Performance")
    case .superCore: return tr("슈퍼 코어", "Super")
    case .unknown: return c.name
    }
  }
}

/// One core cluster: a label with its average, then a rounded bar per core that fills and
/// brightens with load.
private struct ClusterCores: View {
  let title: String
  let usage: Double
  let values: [Double]
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Text(title).font(Theme.text(12.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
        Text("\(values.count)").font(Theme.number(12, weight: .medium)).foregroundStyle(Theme.textTertiary)
        Spacer()
        Text(Format.percent(usage)).font(Theme.number(13, weight: .semibold)).foregroundStyle(tint)
      }
      CoreBars(values: values, tint: tint).frame(height: 34)
    }
  }
}

private struct CoreBars: View {
  let values: [Double]
  let tint: Color

  var body: some View {
    Canvas { ctx, size in
      guard !values.isEmpty else { return }
      let gap: CGFloat = 4
      let w = (size.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count)
      let radius = min(w / 2, 5)
      for (i, raw) in values.enumerated() {
        let v = CGFloat(min(max(raw, 0), 1))
        let x = CGFloat(i) * (w + gap)
        ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: w, height: size.height), cornerRadius: radius), with: .color(Theme.track))
        guard v > 0.01 else { continue }
        let h = max(size.height * v, radius * 2)
        let rect = CGRect(x: x, y: size.height - h, width: w, height: h)
        ctx.fill(Path(roundedRect: rect, cornerRadius: radius),
                 with: .linearGradient(Gradient(colors: [tint.opacity(0.45 + 0.55 * v), tint.opacity(0.35)]),
                                       startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
      }
    }
  }
}

// MARK: - GPU

private struct GPUWidget: View {
  let gpu: GPUModel

  var body: some View {
    WidgetCard {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(gpu.utilization.map(Format.percent) ?? "—")
            .font(Theme.number(48, weight: .bold)).foregroundStyle(Theme.textPrimary)
          Text("GPU").font(Theme.text(18, weight: .semibold)).foregroundStyle(Theme.textTertiary)
          Spacer()
        }
        HStack(spacing: 20) {
          Stat(label: tr("렌더러", "Renderer"), value: gpu.rendererUtilization.map(Format.percent) ?? "—", size: 16)
          Stat(label: tr("타일러", "Tiler"), value: gpu.tilerUtilization.map(Format.percent) ?? "—", size: 16)
        }
        Sparkline(values: gpu.history, tint: Theme.gpu, maxValue: 1).frame(maxHeight: .infinity)
      }
    }
  }
}

// MARK: - Memory

private struct MemoryWidget: View {
  let memory: MemoryModel

  var body: some View {
    WidgetCard {
      VStack(alignment: .leading, spacing: 12) {
        Spacer(minLength: 0)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(Format.bytes(Double(memory.used))).font(Theme.number(36, weight: .bold)).foregroundStyle(Theme.textPrimary)
          Text("/ \(Format.bytes(Double(memory.total)))").font(Theme.number(16)).foregroundStyle(Theme.textTertiary)
        }
        SegmentedMemoryBar(memory: memory).frame(height: 10)
        HStack(spacing: 14) {
          legend(tr("앱", "App"), memory.app, Theme.memory)
          legend(tr("고정", "Wired"), memory.wired, Theme.heat)
          legend(tr("압축", "Compressed"), memory.compressed, Theme.gpu)
        }
        if memory.swapUsed > 0 {
          Text(tr("스왑", "Swap") + " \(Format.bytes(Double(memory.swapUsed))) / \(Format.bytes(Double(memory.swapTotal)))")
            .font(Theme.number(12, weight: .medium)).foregroundStyle(Theme.textSecondary)
        }
        Sparkline(values: memory.history, tint: Theme.memory, maxValue: 1, guides: [1, 0.5])
          .frame(height: GraphScale.trendHeight)
          .padding(.top, 10)
        Spacer(minLength: 0)
      }
    }
  }

  private func legend(_ label: String, _ bytes: UInt64, _ color: Color) -> some View {
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 7, height: 7)
      Text("\(label) \(Format.bytes(Double(bytes)))").font(Theme.number(12.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
    }
  }
}

private struct SegmentedMemoryBar: View {
  let memory: MemoryModel

  var body: some View {
    GeometryReader { geo in
      let total = max(Double(memory.total), 1)
      HStack(spacing: 2) {
        segment(memory.app, total, geo.size.width, Theme.memory)
        segment(memory.wired, total, geo.size.width, Theme.heat)
        segment(memory.compressed, total, geo.size.width, Theme.gpu)
        Spacer(minLength: 0)
      }
      .background(Capsule().fill(Theme.track))
      .clipShape(Capsule())
    }
  }

  private func segment(_ v: UInt64, _ total: Double, _ width: CGFloat, _ color: Color) -> some View {
    Rectangle().fill(color).frame(width: max(0, width * CGFloat(Double(v) / total) - 2))
  }
}

// MARK: - Network & disk

/// Page 1: network throughput. Page 2: disk throughput and free space.
private struct NetworkDiskWidget: View {
  let id: UUID
  let net: NetworkModel
  let disk: DiskModel

  var body: some View {
    PagedCard(id: id, count: 2) { page in
      if page == 0 { network } else { diskPage }
    }
  }

  private var network: some View {
    VStack(alignment: .leading, spacing: 10) {
      Spacer(minLength: 0)
      HStack(spacing: 22) {
        Stat(label: tr("↓ 받기", "↓ In"), value: Format.bytes(net.bytesInPerSecond, perSecond: true), tint: Theme.netIn, size: 24)
        Stat(label: tr("↑ 보내기", "↑ Out"), value: Format.bytes(net.bytesOutPerSecond, perSecond: true), tint: Theme.netOut, size: 24)
      }
      Text(interfaceLine)
        .font(Theme.text(12.5, weight: .medium)).foregroundStyle(Theme.textTertiary).lineLimit(1)
      let inSmooth = GraphScale.smoothed(net.historyIn), outSmooth = GraphScale.smoothed(net.historyOut)
      let top = GraphScale.robustTop(inSmooth + outSmooth, floor: 50_000)
      ZStack {
        Sparkline(values: inSmooth, tint: Theme.netIn, maxValue: top, guides: [1, 0.5], topLabel: Format.bytes(top, perSecond: true))
        Sparkline(values: outSmooth, tint: Theme.netOut, maxValue: top)
      }
      .frame(height: GraphScale.calmHeight)
      .padding(.top, 22)
      Spacer(minLength: 0)
    }
  }

  private var diskPage: some View {
    VStack(alignment: .leading, spacing: 10) {
      Spacer(minLength: 0)
      HStack(spacing: 22) {
        Stat(label: tr("디스크 읽기", "Disk read"), value: Format.bytes(disk.readBytesPerSecond, perSecond: true), tint: Theme.disk, size: 24)
        Stat(label: tr("디스크 쓰기", "Disk write"), value: Format.bytes(disk.writeBytesPerSecond, perSecond: true), tint: Theme.memory, size: 24)
      }
      if let free = disk.freeBytes, let total = disk.totalBytes, total > 0 {
        VStack(alignment: .leading, spacing: 4) {
          UsageBar(value: 1 - Double(free) / Double(total), tint: Theme.disk, height: 8)
          Text("\(disk.volumeName ?? tr("디스크", "Disk")) · \(Format.bytes(Double(free))) " + tr("남음", "free") + " / \(Format.bytes(Double(total)))")
            .font(Theme.number(12.5, weight: .medium)).foregroundStyle(Theme.textTertiary)
        }
      }
      let readSmooth = GraphScale.smoothed(disk.historyRead), writeSmooth = GraphScale.smoothed(disk.historyWrite)
      let top = GraphScale.robustTop(readSmooth + writeSmooth, floor: 1_000_000)
      ZStack {
        Sparkline(values: readSmooth, tint: Theme.disk, maxValue: top, guides: [1, 0.5], topLabel: Format.bytes(top, perSecond: true))
        Sparkline(values: writeSmooth, tint: Theme.memory, maxValue: top)
      }
      .frame(height: GraphScale.calmHeight)
      .padding(.top, 22)
      Spacer(minLength: 0)
    }
  }

  private var interfaceLine: String {
    guard net.isConnected, let name = net.interfaceName else { return tr("오프라인", "Offline") }
    let type = net.interfaceType.map { $0 == .wifi ? "Wi-Fi" : $0 == .wired ? tr("유선", "Wired") : $0.rawValue } ?? ""
    return [type, name, net.localIPv4].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
  }
}

// MARK: - Thermals

private struct SensorsWidget: View {
  let sensors: SensorsModel

  var body: some View {
    WidgetCard {
      GeometryReader { geo in
        let dial = min(geo.size.height - 44, (geo.size.width - 24) / 2, 190)
        VStack(spacing: 14) {
          Spacer(minLength: 0)
          HStack(spacing: 24) {
            TemperatureDial(label: "CPU", value: sensors.cpuTemperature, diameter: dial)
            TemperatureDial(label: "GPU", value: sensors.gpuTemperature, diameter: dial)
          }
          if !sensors.fanRPMs.isEmpty {
            Text(tr("팬", "Fan") + " " + sensors.fanRPMs.map(String.init).joined(separator: " / ") + " rpm")
              .font(Theme.number(14, weight: .medium))
              .foregroundStyle(Theme.textSecondary)
          }
          Spacer(minLength: 0)
        }
        .frame(width: geo.size.width, height: geo.size.height)
      }
    }
  }
}

private struct TemperatureDial: View {
  let label: String
  let value: Double?
  var diameter: CGFloat = 104

  var body: some View {
    let v = value ?? 0
    ZStack {
      // 0–110 °C around the ring: cool teal into amber and red as it heats up.
      RingGauge(value: min(v / 110, 1), tint: Theme.cpu, lineWidth: max(12, diameter * 0.095),
                gradient: [Theme.cpu, Theme.cpu, Theme.warning, Theme.heat, Theme.critical])
      VStack(spacing: 2) {
        HStack(alignment: .top, spacing: 1) {
          Text(value.map { String(format: "%.0f", $0) } ?? "—").font(Theme.number(diameter * 0.28, weight: .bold))
          Text("°").font(Theme.number(diameter * 0.16, weight: .semibold)).padding(.top, diameter * 0.03)
        }
        .foregroundStyle(Theme.textPrimary)
        Text(label).font(Theme.text(max(12.5, diameter * 0.095), weight: .semibold)).foregroundStyle(Theme.textTertiary)
      }
    }
    .frame(width: diameter, height: diameter)
  }
}

// MARK: - Battery & Bluetooth

private struct BatteryWidget: View {
  let battery: BatteryModel
  let bluetooth: BluetoothModel
  let sensors: SensorsModel

  var body: some View {
    WidgetCard {
      VStack(alignment: .leading, spacing: 12) {
        Spacer(minLength: 0)
        if battery.hasBattery, let pct = battery.percent {
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(pct)%").font(Theme.number(44, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Text(stateText).font(Theme.text(14, weight: .medium)).foregroundStyle(Theme.textSecondary)
          }
          UsageBar(value: Double(pct) / 100, tint: pct <= 15 ? Theme.critical : Theme.battery, height: 10)
        }
        HStack(spacing: 18) {
          Stat(label: tr("시스템 전력", "System power"), value: sensors.systemPowerWatts.map { String(format: "%.1f W", $0) } ?? "—", tint: Theme.warning, size: 18)
          if let h = battery.healthPercent { Stat(label: tr("성능 상태", "Health"), value: "\(h)%", size: 18) }
          if let c = battery.cycleCount { Stat(label: tr("사이클", "Cycles"), value: "\(c)", size: 18) }
          if let w = battery.adapterWatts, battery.isPluggedIn { Stat(label: tr("어댑터", "Adapter"), value: "\(w) W", size: 18) }
        }
        if !bluetooth.devices.isEmpty {
          Divider().overlay(Theme.cardBorder).padding(.top, 10)
          BluetoothList(devices: bluetooth.devices, limit: 3)
            .padding(.top, 4)
        }
        Spacer(minLength: 0)
      }
    }
  }

  private var stateText: String {
    if battery.isCharging { return battery.timeRemaining.map { tr("충전 중", "Charging") + " · \($0 / 60)h \($0 % 60)m" } ?? tr("충전 중", "Charging") }
    if battery.isPluggedIn { return battery.isCharged ? tr("완충됨", "Charged") : tr("전원 연결됨", "Plugged in") }
    return battery.timeRemaining.map { "\($0 / 60)h \($0 % 60)m" } ?? tr("배터리 사용 중", "On battery")
  }
}

private struct BluetoothList: View {
  let devices: [BluetoothPeripheral]
  let limit: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(devices.prefix(limit)) { d in
        HStack(spacing: 10) {
          Text(d.name).font(Theme.text(13.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
          if let detail = d.detail {
            Text(detail).font(Theme.number(12.5, weight: .medium)).foregroundStyle(Theme.textTertiary).lineLimit(1)
          }
          Spacer()
          UsageBar(value: Double(d.batteryPercent) / 100, tint: d.batteryPercent <= 20 ? Theme.critical : Theme.battery, height: 6)
            .frame(width: 60)
          Text("\(d.batteryPercent)%").font(Theme.number(12)).foregroundStyle(Theme.textSecondary).frame(width: 38, alignment: .trailing)
        }
      }
    }
  }
}

// MARK: - Processes & System

private struct ProcessList: View {
  let processes: [ProcessUsage]
  let limit: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if processes.isEmpty {
        Text(tr("측정 중…", "Measuring…")).font(Theme.text(13)).foregroundStyle(Theme.textTertiary)
      }
      ForEach(processes.prefix(limit)) { p in
        HStack(spacing: 10) {
          Text(p.name).font(Theme.text(13.5, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
          Spacer()
          Text(String(format: "%.0f%%", p.cpu * 100)).font(Theme.number(13.5)).foregroundStyle(p.cpu > 0.8 ? Theme.heat : Theme.textSecondary)
        }
      }
    }
  }
}

/// Page 1: chip, OS and uptime. Page 2: apps using the most CPU (kept off the first page).
private struct SystemWidget: View {
  let id: UUID
  let system: SystemModel
  let cpu: CPUModel

  var body: some View {
    PagedCard(id: id, count: 2) { page in
      if page == 0 { info } else { processes }
    }
  }

  private var info: some View {
    VStack(alignment: .leading, spacing: 16) {
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 6) {
        Text(cpu.chipName).font(Theme.text(34, weight: .bold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
        Text(system.osVersion).font(Theme.text(15, weight: .medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        Text(system.modelIdentifier).font(Theme.text(13, weight: .medium)).foregroundStyle(Theme.textTertiary).lineLimit(1)
      }
      HStack(spacing: 28) {
        Stat(label: tr("가동 시간", "Uptime"), value: Format.duration(system.uptime), size: 26)
        Stat(label: tr("열 상태", "Thermal state"), value: thermalText, tint: thermalColor, size: 26)
      }
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }

  private var processes: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(tr("CPU를 많이 쓰는 앱", "Top apps by CPU")).font(Theme.text(14, weight: .semibold)).foregroundStyle(Theme.textSecondary)
      ProcessList(processes: system.topProcesses, limit: 7)
    }
  }

  private var thermalText: String {
    switch system.thermalState {
    case .nominal: return tr("정상", "Normal")
    case .fair: return tr("약간 높음", "Fair")
    case .serious: return tr("높음", "Serious")
    case .critical: return tr("위험", "Critical")
    @unknown default: return "?"
    }
  }

  private var thermalColor: Color {
    switch system.thermalState {
    case .nominal: return Theme.battery
    case .fair: return Theme.warning
    case .serious: return Theme.heat
    default: return Theme.critical
    }
  }
}

enum GraphScale {
  /// Throughput graphs use a fixed, modest height so short bursts don't dominate the card.
  static let calmHeight: CGFloat = 110
  /// CPU and memory trend graphs: shorter, with guide lines so a quiet period still reads as a chart.
  static let trendHeight: CGFloat = 108

  /// Moving average over `window` samples to take the edge off one-second spikes.
  static func smoothed(_ values: [Double], window: Int = 3) -> [Double] {
    guard values.count > window else { return values }
    var out: [Double] = []
    out.reserveCapacity(values.count)
    var sum = 0.0
    for (i, v) in values.enumerated() {
      sum += v
      if i >= window { sum -= values[i - window] }
      out.append(sum / Double(min(i + 1, window)))
    }
    return out
  }

  /// Upper bound for a throughput graph: the 95th percentile of recent samples (with headroom),
  /// so one burst doesn't flatten the rest of the history into the baseline. Bursts are clipped.
  static func robustTop(_ values: [Double], floor: Double) -> Double {
    let positive = values.filter { $0 > 0 }.sorted()
    guard !positive.isEmpty else { return floor }
    let index = min(positive.count - 1, Int(Double(positive.count - 1) * 0.95))
    return max(positive[index] * 1.2, floor)
  }
}
