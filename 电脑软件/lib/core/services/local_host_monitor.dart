import 'dart:ffi';
import 'dart:io';

/// Local operating-system counters. This never connects to a model or device.
class HostSystemCounters {
  const HostSystemCounters({
    this.idleTicks,
    this.kernelTicks,
    this.userTicks,
    this.memoryTotalBytes,
    this.memoryAvailableBytes,
  });

  final int? idleTicks, kernelTicks, userTicks;
  final int? memoryTotalBytes, memoryAvailableBytes;
}

class LocalHostSnapshot {
  const LocalHostSnapshot({
    required this.observedAt,
    this.cpuPercent,
    this.memoryUsedBytes,
    this.memoryTotalBytes,
    this.cpuSampling = false,
    this.unavailableReason,
  });

  final DateTime observedAt;
  final double? cpuPercent;
  final int? memoryUsedBytes, memoryTotalBytes;
  final bool cpuSampling;
  final String? unavailableReason;

  bool get hasMemory => memoryUsedBytes != null && memoryTotalBytes != null;
  bool get hasMetrics => cpuPercent != null || hasMemory;
}

/// One quick synchronous sample every few seconds is sufficient for the header.
/// CPU usage requires two successful samples; unknown values remain null.
class LocalHostMonitor {
  LocalHostMonitor({
    HostSystemCounters Function()? readCounters,
    DateTime Function()? now,
    bool? windows,
  }) : _readCounters = readCounters,
       _now = now ?? DateTime.now,
       _supported = readCounters != null || (windows ?? Platform.isWindows);

  HostSystemCounters Function()? _readCounters;
  final DateTime Function() _now;
  final bool _supported;
  HostSystemCounters? _previous;

  LocalHostSnapshot sample() {
    final observedAt = _now();
    if (!_supported) {
      return LocalHostSnapshot(
        observedAt: observedAt,
        unavailableReason: '本机资源监测仅支持 Windows',
      );
    }
    try {
      _readCounters ??= _WindowsHostReader().read;
      final current = _readCounters!();
      final cpu = _cpuUsage(_previous, current);
      final cpuSampling = _previous == null && _validCpu(current);
      _previous = current;
      final total = current.memoryTotalBytes;
      final available = current.memoryAvailableBytes;
      final validMemory =
          total != null &&
          total > 0 &&
          available != null &&
          available >= 0 &&
          available <= total;
      return LocalHostSnapshot(
        observedAt: observedAt,
        cpuPercent: cpu,
        memoryUsedBytes: validMemory ? total - available : null,
        memoryTotalBytes: validMemory ? total : null,
        cpuSampling: cpuSampling,
        unavailableReason: !_validCpu(current) && !validMemory
            ? '本机资源暂不可用'
            : null,
      );
    } catch (_) {
      _previous = null;
      return LocalHostSnapshot(
        observedAt: observedAt,
        unavailableReason: '本机资源暂不可用',
      );
    }
  }

  static bool _validCpu(HostSystemCounters value) =>
      value.idleTicks != null &&
      value.kernelTicks != null &&
      value.userTicks != null &&
      value.idleTicks! >= 0 &&
      value.kernelTicks! >= value.idleTicks! &&
      value.userTicks! >= 0;

  static double? _cpuUsage(
    HostSystemCounters? previous,
    HostSystemCounters current,
  ) {
    if (previous == null || !_validCpu(previous) || !_validCpu(current)) {
      return null;
    }
    final idle = current.idleTicks! - previous.idleTicks!;
    final kernel = current.kernelTicks! - previous.kernelTicks!;
    final user = current.userTicks! - previous.userTicks!;
    final total = kernel + user;
    if (idle < 0 || kernel < 0 || user < 0 || total <= 0 || idle > total) {
      return null;
    }
    return 100 * (total - idle) / total;
  }
}

final class _FileTime extends Struct {
  @Uint32()
  external int low;
  @Uint32()
  external int high;

  int get ticks => (high << 32) | low;
}

final class _MemoryStatus extends Struct {
  @Uint32()
  external int length;
  @Uint32()
  external int memoryLoad;
  @Uint64()
  external int totalPhysical;
  @Uint64()
  external int availablePhysical;
  @Uint64()
  external int totalPageFile;
  @Uint64()
  external int availablePageFile;
  @Uint64()
  external int totalVirtual;
  @Uint64()
  external int availableVirtual;
  @Uint64()
  external int availableExtendedVirtual;
}

class _WindowsHostReader {
  _WindowsHostReader() : _library = DynamicLibrary.open('kernel32.dll');

  final DynamicLibrary _library;
  late final _getHeap = _library
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetProcessHeap',
      );
  late final _allocate = _library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
        Pointer<Void> Function(Pointer<Void>, int, int)
      >('HeapAlloc');
  late final _free = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)
      >('HeapFree');
  late final _systemTimes = _library
      .lookupFunction<
        Int32 Function(
          Pointer<_FileTime>,
          Pointer<_FileTime>,
          Pointer<_FileTime>,
        ),
        int Function(Pointer<_FileTime>, Pointer<_FileTime>, Pointer<_FileTime>)
      >('GetSystemTimes');
  late final _memoryStatus = _library
      .lookupFunction<
        Int32 Function(Pointer<_MemoryStatus>),
        int Function(Pointer<_MemoryStatus>)
      >('GlobalMemoryStatusEx');

  HostSystemCounters read() {
    final heap = _getHeap();
    if (heap == nullptr) throw StateError('Process heap unavailable');
    // One allocation holds three FILETIMEs followed by an aligned MEMORYSTATUSEX.
    final memoryOffset = sizeOf<_FileTime>() * 3;
    final allocation = _allocate(
      heap,
      0x00000008, // HEAP_ZERO_MEMORY
      memoryOffset + sizeOf<_MemoryStatus>(),
    );
    if (allocation == nullptr) throw StateError('Counter allocation failed');
    try {
      final times = allocation.cast<_FileTime>();
      final memory = (allocation.cast<Uint8>() + memoryOffset)
          .cast<_MemoryStatus>();
      memory.ref.length = sizeOf<_MemoryStatus>();
      final hasCpu = _systemTimes(times, times + 1, times + 2) != 0;
      final hasMemory = _memoryStatus(memory) != 0;
      return HostSystemCounters(
        idleTicks: hasCpu ? times.ref.ticks : null,
        kernelTicks: hasCpu ? (times + 1).ref.ticks : null,
        userTicks: hasCpu ? (times + 2).ref.ticks : null,
        memoryTotalBytes: hasMemory ? memory.ref.totalPhysical : null,
        memoryAvailableBytes: hasMemory ? memory.ref.availablePhysical : null,
      );
    } finally {
      _free(heap, 0, allocation);
    }
  }
}
