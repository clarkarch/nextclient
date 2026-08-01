import 'dart:convert' show jsonDecode;

import 'package:http/http.dart' as http;

import '../models/printed_waste.dart';

// Port of services/printedWaste.ts

const printedWasteTimeoutMs = 7000;
const printedWasteQueueUrl = 'https://api.printedwaste.com/gfn/queue/';
const printedWasteServerMappingUrl =
    'https://remote.printedwaste.com/config/GFN_SERVERID_TO_REGION_MAPPING';

class PrintedWasteService {
  final http.Client client;
  final String appVersion;

  PrintedWasteService({required this.client, required this.appVersion});

  Future<PrintedWasteQueueData> fetchPrintedWasteQueue() async {
    final response = await client
        .get(
          Uri.parse(printedWasteQueueUrl),
          headers: {
            'User-Agent': 'nextclient/$appVersion',
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(milliseconds: printedWasteTimeoutMs));

    if (response.statusCode != 200) {
      throw StateError('PrintedWaste API returned HTTP ${response.statusCode}');
    }

    final body = _decodeObject(response.body);
    if (body['status'] is! bool) {
      throw StateError('PrintedWaste API response missing boolean status');
    }
    if (body['status'] != true) {
      throw StateError('PrintedWaste API returned status:false');
    }

    final data = body['data'];
    if (data is! Map) {
      throw StateError('PrintedWaste API response missing data object');
    }

    final normalized = <String, PrintedWasteZoneData>{};
    for (final entry in data.entries) {
      final zone = entry.value;
      if (zone is! Map) continue;
      final queuePosition = zone['QueuePosition'];
      final lastUpdated = zone['Last Updated'];
      final region = zone['Region'];
      final eta = zone['eta'];

      if (queuePosition is! num || !queuePosition.isFinite) continue;
      if (lastUpdated is! num || !lastUpdated.isFinite) continue;
      if (region is! String || region.isEmpty) continue;
      if (eta != null && (eta is! num || !eta.isFinite)) continue;

      normalized[entry.key] = PrintedWasteZoneData(
        queuePosition: queuePosition.toInt(),
        lastUpdated: lastUpdated.toInt(),
        region: region,
        etaMs: eta is num ? eta.toInt() : null,
      );
    }

    if (normalized.isEmpty) {
      throw StateError('PrintedWaste API returned no valid zones');
    }
    return PrintedWasteQueueData(zones: normalized);
  }

  Future<PrintedWasteServerMapping> fetchPrintedWasteServerMapping() async {
    final response = await client
        .get(
          Uri.parse(printedWasteServerMappingUrl),
          headers: {
            'User-Agent': 'nextclient/$appVersion',
            'Accept': 'application/json',
          },
        )
        .timeout(const Duration(milliseconds: printedWasteTimeoutMs));

    if (response.statusCode != 200) {
      throw StateError(
        'PrintedWaste server mapping returned HTTP ${response.statusCode}',
      );
    }

    final body = _decodeObject(response.body);
    if (body['status'] is! bool) {
      throw StateError('PrintedWaste server mapping missing boolean status');
    }
    if (body['status'] != true) {
      throw StateError('PrintedWaste server mapping returned status:false');
    }

    final data = body['data'];
    if (data is! Map) {
      throw StateError('PrintedWaste server mapping missing data object');
    }

    final normalized = <String, PrintedWasteServerEntry>{};
    for (final entry in data.entries) {
      final server = entry.value;
      if (server is! Map) continue;
      normalized[entry.key] = PrintedWasteServerEntry.fromJson(
        _toStrKeyMap(server),
      );
    }

    return PrintedWasteServerMapping(servers: normalized);
  }

  Map<String, dynamic> _decodeObject(String text) {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    throw FormatException('PrintedWaste response was not a JSON object');
  }
}

Map<String, dynamic> _toStrKeyMap(Map<dynamic, dynamic> input) {
  final out = <String, dynamic>{};
  for (final entry in input.entries) {
    out['${entry.key}'] = entry.value;
  }
  return out;
}
