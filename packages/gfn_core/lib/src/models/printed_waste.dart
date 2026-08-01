class PrintedWasteQueueData {
  final Map<String, PrintedWasteZoneData> zones;

  const PrintedWasteQueueData({required this.zones});
}

class PrintedWasteZoneData {
  final int? queuePosition;
  final int? lastUpdated;
  final String? region;
  final int? etaMs;

  const PrintedWasteZoneData({
    this.queuePosition,
    this.lastUpdated,
    this.region,
    this.etaMs,
  });

  factory PrintedWasteZoneData.fromJson(Map<String, dynamic> json) {
    return PrintedWasteZoneData(
      queuePosition: (json['QueuePosition'] as num?)?.toInt(),
      lastUpdated: (json['Last Updated'] as num?)?.toInt(),
      region: json['Region'] as String?,
      etaMs: (json['eta'] as num?)?.toInt(),
    );
  }
}

class PrintedWasteServerMapping {
  final Map<String, PrintedWasteServerEntry> servers;

  const PrintedWasteServerMapping({required this.servers});
}

class PrintedWasteServerEntry {
  final String? key;
  final String? value;
  final String? displayName;
  final bool? is4080Server;
  final bool? is5080Server;
  final bool? nuked;

  const PrintedWasteServerEntry({
    this.key,
    this.value,
    this.displayName,
    this.is4080Server,
    this.is5080Server,
    this.nuked,
  });

  factory PrintedWasteServerEntry.fromJson(Map<String, dynamic> json) {
    return PrintedWasteServerEntry(
      key: json['key'] as String?,
      value: json['value'] as String?,
      displayName: json['displayName'] as String?,
      is4080Server: json['is4080Server'] as bool?,
      is5080Server: json['is5080Server'] as bool?,
      nuked: json['nuked'] as bool?,
    );
  }
}