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
