export function evaluateModuleStatusValue({ moduleKey, isCore, defaultStatus = 'ENABLED', orgStatus, storeStatus, allowDraining = false }) {
  if (!moduleKey) return false;
  if (isCore === true) return true;
  const effectiveOrgStatus = orgStatus ?? defaultStatus;
  if (effectiveOrgStatus === 'DISABLED') return false;
  const effectiveStatus = storeStatus ?? effectiveOrgStatus;
  if (effectiveStatus === 'ENABLED') return true;
  if (effectiveStatus === 'DRAINING' && allowDraining === true) return true;
  return false;
}

export function resolveEffectiveModuleConfig({ moduleDefaultConfig = {}, orgModuleConfig = {}, storeModuleConfig = {}, deviceModuleConfig = {} }) {
  return { ...moduleDefaultConfig, ...orgModuleConfig, ...storeModuleConfig, ...deviceModuleConfig };
}
