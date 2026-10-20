export function configureDeliveryOrderPayment({ order, paymentMethod, isPrepaid = false, shippingFee = 0 }) {
  const totalAmount = Number(order.total_amount ?? 0);
  const isCod = !paymentMethod || paymentMethod.code === 'COD' || paymentMethod.method_category === 'COD';
  const prepaid = !isCod && Boolean(isPrepaid);
  return {
    orderId: order.id,
    paymentMethodId: paymentMethod?.id ?? null,
    paymentMethodCode: paymentMethod?.code ?? (isCod ? 'COD' : 'UNKNOWN'),
    isPrepaid: prepaid,
    shippingFee: Number(shippingFee),
    codAmount: prepaid ? 0 : totalAmount,
    status: 'ASSIGNED',
  };
}
