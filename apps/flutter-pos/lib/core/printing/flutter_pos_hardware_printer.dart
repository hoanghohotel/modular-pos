// Giai đoạn 8: Hardware Bridge điều khiển máy in nhiệt ESC/POS (LAN 9100 / Bluetooth / USB)
class EscPosReceiptBuilder {
  static const List<int> initPrinter = [0x1B, 0x40];
  static const List<int> cutPaper = [0x1D, 0x56, 0x00];
  static const List<int> openCashDrawer = [0x1B, 0x70, 0x00, 0x19, 0xFA];
}
