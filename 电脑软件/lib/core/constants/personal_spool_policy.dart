/// Every physical spool has the same capacity in the personal inventory.
/// Multiple spools belong in separate records or an explicitly aggregate row.
const double personalSpoolCapacityGrams = 1000.0;

/// A retained spool can be loaded again only above this remaining weight.
/// Reaching this threshold never clears its inventory balance automatically.
const double minimumReusableSpoolGrams = 30.0;

bool canReusePersonalSpool(double remainingGrams) =>
    remainingGrams.isFinite &&
    remainingGrams > minimumReusableSpoolGrams &&
    remainingGrams <= personalSpoolCapacityGrams;

/// A row represents one physical spool when it carries a tag identity or came
/// from an explicit per-roll receipt. Nothing else may be rewritten by the
/// legacy capacity repair below.
bool isIndividualPersonalSpoolRow({
  required String? rfidTagUid,
  required String? stockReceiptUid,
}) {
  return rfidTagUid?.trim().isNotEmpty == true ||
      stockReceiptUid?.trim().isNotEmpty == true;
}

/// Older releases stored the measured remainder as the spool nominal
/// capacity, so a real 1 kg roll could be recorded as `totalGrams = 350` or
/// `750`. The physical roll never changed.
///
/// This recognizes exactly those rows: an individual spool whose recorded
/// capacity is below one roll and whose balance already fits one roll. The
/// repair only rewrites the nominal capacity to 1000. The measured remainder,
/// inventory UID, receipt, cycle, tag history and events stay untouched, and
/// aggregate rows or balances above one roll are never truncated.
bool isRepairableLegacyPersonalSpoolCapacity({
  required String? rfidTagUid,
  required String? stockReceiptUid,
  required double totalGrams,
  required double remainingGrams,
}) {
  if (!isIndividualPersonalSpoolRow(
    rfidTagUid: rfidTagUid,
    stockReceiptUid: stockReceiptUid,
  )) {
    return false;
  }
  if (!totalGrams.isFinite || !remainingGrams.isFinite) return false;
  if (totalGrams <= 0 || totalGrams >= personalSpoolCapacityGrams) return false;
  return remainingGrams >= 0 && remainingGrams <= personalSpoolCapacityGrams;
}

/// Nominal capacity a personal spool row should carry. Anything that is not
/// a repairable legacy spool keeps its recorded capacity untouched.
double canonicalPersonalSpoolCapacityGrams({
  required String? rfidTagUid,
  required String? stockReceiptUid,
  required double totalGrams,
  required double remainingGrams,
}) =>
    isRepairableLegacyPersonalSpoolCapacity(
      rfidTagUid: rfidTagUid,
      stockReceiptUid: stockReceiptUid,
      totalGrams: totalGrams,
      remainingGrams: remainingGrams,
    )
    ? personalSpoolCapacityGrams
    : totalGrams;
