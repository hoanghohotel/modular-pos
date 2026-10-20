const SCALE = 10000n;
export const toScaled = (amount) => BigInt(Math.round(Number(amount ?? 0) * 10000));
export const fromScaled = (scaledBigInt) => Number(scaledBigInt) / 10000;

export function calculateCrc16Ccitt(str) {
  let crc = 0xffff;
  for (let i = 0; i < str.length; i++) {
    crc ^= str.charCodeAt(i) << 8;
    for (let j = 0; j < 8; j++) {
      crc = (crc & 0x8000) !== 0 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
    }
  }
  return crc.toString(16).toUpperCase().padStart(4, '0');
}

export function formatTlv(tag, value) {
  const strVal = String(value ?? '');
  return `${tag}${String(strVal.length).padStart(2, '0')}${strVal}`;
}

export function generateVietQrPayload({ bankBin, accountNo, accountName = '', amount = 0, memo = '' }) {
  const cleanBin = String(bankBin ?? '').trim();
  const cleanAcc = String(accountNo ?? '').trim();
  const cleanAmount = Math.max(0, Math.round(Number(amount ?? 0)));
  const cleanMemo = String(memo ?? '').trim().slice(0, 50);
  const beneficiaryInfo = formatTlv('00', cleanBin) + formatTlv('01', cleanAcc);
  const tag38Value = formatTlv('00', 'A000000727') + formatTlv('01', beneficiaryInfo) + formatTlv('02', 'QRIBFTTA');
  let emv = formatTlv('00', '01') + formatTlv('01', cleanAmount > 0 ? '12' : '11') + formatTlv('38', tag38Value) + formatTlv('53', '704');
  if (cleanAmount > 0) emv += formatTlv('54', String(cleanAmount));
  emv += formatTlv('58', 'VN');
  if (cleanMemo) emv += formatTlv('62', formatTlv('08', cleanMemo));
  emv += '6304';
  const crc = calculateCrc16Ccitt(emv);
  return { qrPayload: emv + crc, amount: cleanAmount, memo: cleanMemo, isDynamic: cleanAmount > 0 };
}
