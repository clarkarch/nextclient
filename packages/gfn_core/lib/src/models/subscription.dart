class SubscriptionInfo {
  final String membershipTier;
  final String? subscriptionType;
  final String? subscriptionSubType;
  final double allottedHours;
  final double purchasedHours;
  final double rolledOverHours;
  final double usedHours;
  final double remainingHours;
  final double totalHours;
  final String? firstEntitlementStartDateTime;
  final String? serverRegionId;
  final String? currentSpanStartDateTime;
  final String? currentSpanEndDateTime;
  final bool isUnlimited;
  final StorageAddon? storageAddon;
  final List<EntitledResolution> entitledResolutions;
  final bool? isGamePlayAllowed;

  const SubscriptionInfo({
    required this.membershipTier,
    this.subscriptionType,
    this.subscriptionSubType,
    required this.allottedHours,
    required this.purchasedHours,
    required this.rolledOverHours,
    required this.usedHours,
    required this.remainingHours,
    required this.totalHours,
    this.firstEntitlementStartDateTime,
    this.serverRegionId,
    this.currentSpanStartDateTime,
    this.currentSpanEndDateTime,
    required this.isUnlimited,
    this.storageAddon,
    this.entitledResolutions = const [],
    this.isGamePlayAllowed,
  });
}

class StorageAddon {
  final String type;
  final double? sizeGb;
  final double? usedGb;
  final String? regionName;
  final String? regionCode;

  const StorageAddon({
    required this.type,
    this.sizeGb,
    this.usedGb,
    this.regionName,
    this.regionCode,
  });
}

class EntitledResolution {
  final int width;
  final int height;
  final int fps;

  const EntitledResolution({
    required this.width,
    required this.height,
    required this.fps,
  });
}