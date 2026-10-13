// Which of this worker's independent loops are ARMED.
//
// OPT-OUT, same polarity as nautilus's SIGNAL_ENABLED/METEORA_MOVERS_ENABLED:
// the safe default is "keep running", and an operator says '0'/'false'/'off'/
// 'no' to stop a loop from starting at all — the boot-time call included, not
// just the interval.
const OFF = new Set(['0', 'false', 'off', 'no']);

// A BLANK var means UNSET, never "disabled" — a cleared Railway field arrives
// as '' and not as undefined, so emptying a field must leave the loop running.
function armed(value: string | undefined): boolean {
  const normalized = value?.trim().toLowerCase();
  if (!normalized) return true;
  return !OFF.has(normalized);
}

export function arcV3Enabled(): boolean {
  return armed(process.env.ARC_V3_ENABLED);
}

export function arcV4Enabled(): boolean {
  return armed(process.env.ARC_V4_ENABLED);
}
