export function calculateMovingAverageCost({ currentOnHandQty = 0, currentUnitCost = 0, incomingQty = 0, incomingUnitCost = 0 }) {
  const oldQty = Number(currentOnHandQty);
  const oldCost = Number(currentUnitCost);
  const inQty = Number(incomingQty);
  const inCost = Number(incomingUnitCost);
  const newQty = oldQty + inQty;
  if (oldQty <= 0) return { newOnHandQty: newQty, newUnitCost: inCost, totalValue: Math.round(newQty * inCost * 10000) / 10000 };
  const newCost = Math.round(((oldQty * oldCost + inQty * inCost) / newQty) * 10000) / 10000;
  return { newOnHandQty: newQty, newUnitCost: newCost, totalValue: Math.round(newQty * newCost * 10000) / 10000 };
}
