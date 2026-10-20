export function generateEscPosReceiptBytes({ receipt, store, isCash = true, openDrawer = true }) {
  const bytes = [0x1B, 0x40, 0x1B, 0x61, 0x01];
  const title = store?.name ?? 'MODULAR POS';
  for (let i = 0; i < title.length; i++) bytes.push(title.charCodeAt(i));
  bytes.push(0x0A);
  if (isCash && openDrawer) bytes.push(0x1B, 0x70, 0x00, 0x19, 0xFA);
  bytes.push(0x0A, 0x0A, 0x1D, 0x56, 0x00);
  return new Uint8Array(bytes);
}
