const el=id=>document.getElementById(id);
const money=value=>`${Number(value).toLocaleString('vi-VN')} ₫`;
let api,store,context={},products=[],variants=[],modifiers=[],orders=[],cart=[],editing=null,pending=null,generation=0,dirty=false,currentShift=null,payments=[];
const status=text=>{el('salesStatus').textContent=text;};
const rpc=(name,args)=>api.request(`/rest/v1/rpc/${name}`,{method:'POST',body:{p_org_id:store.organization_id,p_store_id:store.id,...args}});
const rows=(table,select='*',extra='')=>api.request(`/rest/v1/${table}?select=${select}&store_id=eq.${store.id}${extra}`);
function option(value,label){const o=document.createElement('option');o.value=value;o.textContent=label;return o;}
function reset(){dirty=false;cart=[];editing=null;pending=null;el('customerName').value='';el('customerPhone').value='';el('customerAddress').value='';renderCart();}
async function run(action){
 document.querySelectorAll('#salesPanel button').forEach(b=>{b.disabled=true;});
 el('stores').disabled=true;
 try{await action();}catch(error){
  const code=error.message;
  const messages={OPEN_SHIFT_REQUIRED:'Bạn cần mở ca trước khi thu hoặc hoàn tiền.',INSUFFICIENT_PAYMENT:'Số tiền nhận chưa đủ hoặc vượt giới hạn cho phép.',TRANSFER_CONFIRMATION_REQUIRED:'Cần nhận đúng số tiền và xác nhận đã kiểm tra chuyển khoản.',CASH_INSUFFICIENT:'Tiền mặt dự kiến trong ca không đủ để hoàn đơn này.',SHIFT_CLOSED:'Ca đã đóng. Hãy tải lại dữ liệu.',REASON_REQUIRED:'Nhập lý do từ 3 đến 500 ký tự.',ORDER_FINALIZED:'Đơn đã hoàn tất. Không thể thu tiền hoặc sửa lần nữa.',VERSION_CONFLICT:'Đơn đã được máy khác cập nhật. Mở lại đơn để xem dữ liệu mới.',PERMISSION_DENIED:'Bạn chưa được cấp quyền thực hiện thao tác này.',IDEMPOTENCY_KEY_REUSED:'Yêu cầu đã thay đổi. Hãy tải lại danh sách đơn.', '23505':'Tên bàn bị trùng hoặc bàn đã có đơn đang mở.',VARIANT_UNAVAILABLE:'Một size đã ngừng bán. Hãy kiểm tra thực đơn.',DELIVERY_DETAILS_REQUIRED:'Đơn giao hàng cần số điện thoại và địa chỉ.'};
  status(messages[code]||'Chưa xác nhận được thao tác. Kiểm tra kết nối rồi thử lại cùng yêu cầu.');
 }finally{document.querySelectorAll('#salesPanel button').forEach(b=>{b.disabled=false;});el('saveOrder').disabled=!context.can_sell;el('stores').disabled=el('stores').options.length===0;}
}
function renderSelection(){
 const pid=el('productChoice').value;
 el('variantChoice').replaceChildren(...variants.filter(v=>v.product_id===pid&&v.active).map(v=>option(v.id,`${v.name} · ${money(v.price)}`)));
 el('modifierChoices').replaceChildren(...modifiers.filter(m=>m.product_id===pid&&m.active).map(m=>{
  const label=document.createElement('label');label.className='modifier-choice';const input=document.createElement('input');input.type='checkbox';input.value=m.id;label.append(input,document.createTextNode(`${m.name} +${money(m.price)}`));return label;
 }));
}
function renderCart(){
 el('orderTitle').textContent=editing?`Đang sửa đơn ${editing.id.slice(0,8)} · phiên bản ${editing.revision}`:'Đơn mới';
 el('cartItems').replaceChildren(...cart.map((line,index)=>{
  const row=document.createElement('li');const text=document.createElement('span');text.textContent=`${line.name} × ${line.quantity} · ${money(line.unit*line.quantity)}`;
  const remove=document.createElement('button');remove.type='button';remove.className='secondary';remove.textContent='Bỏ món';remove.addEventListener('click',()=>{cart.splice(index,1);dirty=true;pending=null;renderCart();});row.append(text,remove);return row;
 }));
 el('cartTotal').textContent=`Tạm tính: ${money(cart.reduce((s,l)=>s+l.quantity*l.unit,0))}`;
 el('positionField').hidden=el('channelChoice').value!=='DINE_IN';
 el('deliveryFields').hidden=el('channelChoice').value!=='DELIVERY';
 renderFinance();
}
async function refresh(){
 const current=generation;
 const [ps,vs,ms,tables,open]=await Promise.all([rows('products','*','&active=eq.true&order=name'),rows('product_variants'),rows('product_modifiers'),rows('service_positions','*','&active=eq.true&order=name'),rows('orders','*','&order_status=eq.OPEN&order=updated_at.desc&limit=200')]);
 if(current!==generation)return;
 products=ps;variants=vs;modifiers=ms;orders=open;
 el('productChoice').replaceChildren(...products.map(p=>option(p.id,`${p.category} · ${p.name}`)));
 el('positionChoice').replaceChildren(option('','Chọn bàn'),...tables.map(p=>option(p.id,p.name)));
 el('openOrders').replaceChildren(...orders.map(o=>{
  const row=document.createElement('li');const label=document.createElement('span');label.textContent=`${o.id.slice(0,8)} · ${o.channel==='DINE_IN'?(tables.find(p=>p.id===o.position_id)?.name||'Tại bàn'):o.channel==='DELIVERY'?'Giao hàng':'Mang về'} · ${money(o.total_amount)}`;
  const button=document.createElement('button');button.type='button';button.className='secondary';button.textContent='Mở đơn';button.addEventListener('click',()=>run(()=>openOrder(o)));row.append(label,button);return row;
 }));
 if(!orders.length){const item=document.createElement('li');item.textContent='Chưa có đơn đang mở.';el('openOrders').append(item);}
 renderSelection();renderCart();renderPriceEditor();
 await refreshFinance();
}
async function openOrder(order){
 const current=generation;
 const lines=await rows('order_items','*',`&order_id=eq.${order.id}`);
 if(current!==generation)return;
 dirty=false;editing=order;pending=null;cart=lines.map(l=>({variant_id:l.variant_id,modifier_ids:l.modifier_snapshot.map(m=>m.id),quantity:l.quantity,name:`${l.product_name} / ${l.variant_name}${l.modifier_snapshot.length?' + '+l.modifier_snapshot.map(m=>m.name).join(', '):''}`,unit:Number(l.unit_amount)}));
 el('channelChoice').value=order.channel;el('positionChoice').value=order.position_id||'';
 el('customerName').value=order.customer.name||'';el('customerPhone').value=order.customer.phone||'';el('customerAddress').value=order.customer.address||'';
 renderCart();status('Đã mở dữ liệu đơn từ server. Giá hiện tại sẽ được kiểm tra lại khi lưu.');
}
function priceRow(kind){
 const row=el('priceRowTemplate').content.firstElementChild.cloneNode(true);row.dataset.kind=kind;
 row.querySelector('input[type=text]').placeholder=kind==='variant'?'Tên size (VD: M)':'Tên topping';
 row.querySelector('button').addEventListener('click',()=>row.remove());
 (kind==='variant'?el('variantRows'):el('modifierRows')).append(row);
}
function renderPriceEditor(){
 el('priceVariant').replaceChildren(...variants.map(v=>option(v.id,`${products.find(p=>p.id===v.product_id)?.name||'Món'} / ${v.name}`)));
 selectPrice();
}
function selectPrice(){const v=variants.find(v=>v.id===el('priceVariant').value);el('newPrice').value=v?.price??'';el('variantActive').checked=v?.active??false;}
el('priceVariant').addEventListener('change',selectPrice);
el('editPriceForm').addEventListener('submit',e=>{e.preventDefault();run(async()=>{await rpc('rpc_update_variant',{p_variant_id:el('priceVariant').value,p_price:Number(el('newPrice').value),p_active:el('variantActive').checked});await refresh();status('Đã cập nhật giá/trạng thái size.');});});
el('productChoice').addEventListener('change',renderSelection);
el('channelChoice').addEventListener('change',()=>{dirty=true;renderCart();});
for(const id of ['positionChoice','customerName','customerPhone','customerAddress'])el(id).addEventListener('input',()=>{dirty=true;renderFinance();});
el('addVariant').addEventListener('click',()=>priceRow('variant'));
el('addModifier').addEventListener('click',()=>priceRow('modifier'));
el('addItem').addEventListener('click',()=>{
 if(!context.can_sell)return;
 const v=variants.find(v=>v.id===el('variantChoice').value);if(!v){status('Hãy tạo và chọn size đang bán.');return;}
 const p=products.find(p=>p.id===v.product_id);const selected=[...el('modifierChoices').querySelectorAll('input:checked')].map(i=>modifiers.find(m=>m.id===i.value));
 const quantity=Number(el('itemQuantity').value);if(!Number.isInteger(quantity)||quantity<1||quantity>999){status('Số lượng từ 1 đến 999.');return;}
 dirty=true;cart.push({variant_id:v.id,modifier_ids:selected.map(m=>m.id),quantity,name:`${p.name} / ${v.name}${selected.length?' + '+selected.map(m=>m.name).join(', '):''}`,unit:Number(v.price)+selected.reduce((s,m)=>s+Number(m.price),0)});pending=null;renderCart();
});
el('newOrder').addEventListener('click',()=>{reset();status('Đã mở giỏ hàng mới.');});
el('reloadOrders').addEventListener('click',()=>run(async()=>{await refresh();status('Đã tải dữ liệu mới nhất.');}));
el('orderForm').addEventListener('submit',e=>{
 e.preventDefault();if(!context.can_sell)return;
 run(async()=>{
  const current=generation;
  if(!cart.length){status('Thêm ít nhất một món trước khi lưu.');return;}
  const payload={p_channel:el('channelChoice').value,p_position_id:el('channelChoice').value==='DINE_IN'?(el('positionChoice').value||null):null,p_items:cart.map(({variant_id,modifier_ids,quantity})=>({variant_id,modifier_ids,quantity})),p_customer:{name:el('customerName').value.trim(),phone:el('customerPhone').value.trim(),address:el('customerAddress').value.trim()},p_order_id:editing?.id||null,p_expected_revision:editing?.revision||null};
  const fingerprint=JSON.stringify(payload);
  if(!pending||pending.fingerprint!==fingerprint)pending={id:crypto.randomUUID(),fingerprint};
  const result=await rpc('rpc_save_order',{...payload,p_operation_id:pending.id});
  if(current!==generation)return;
  pending=null;reset();await refresh();const order=orders.find(o=>o.id===result.order_id);if(order)await openOrder(order);
  status(`Đã lưu đơn ${result.order_id.slice(0,8)} · Tổng tiền server: ${money(result.total_amount)}. Có thể thu tiền sau khi mở ca.`);
 });
});
el('productForm').addEventListener('submit',e=>{
 e.preventDefault();run(async()=>{
  const prices=target=>[...el(target).children].map(row=>({name:row.querySelector('input[type=text]').value.trim(),price:Number(row.querySelector('input[type=number]').value)}));
  await rpc('rpc_create_product',{p_product:{name:el('productName').value.trim(),category:el('productCategory').value.trim(),variants:prices('variantRows'),modifiers:prices('modifierRows')}});
  el('productForm').reset();el('variantRows').replaceChildren();el('modifierRows').replaceChildren();priceRow('variant');await refresh();status('Đã lưu món, size và topping.');
 });
});
el('positionForm').addEventListener('submit',e=>{e.preventDefault();run(async()=>{await rpc('rpc_create_position',{p_name:el('positionName').value.trim()});el('positionForm').reset();await refresh();status('Đã thêm bàn.');});});
priceRow('variant');
window.addEventListener('workspace:ready',async e=>{
 const current=++generation;const detail=e.detail;
 el('salesPanel').hidden=true;context={};currentShift=null;payments=[];financePending.clear();reset();
 if(!detail?.store)return;
 api=detail.client;store=detail.store;
 await run(async()=>{
  const result=await rpc('rpc_store_context',{});if(current!==generation)return;
  context=result;el('catalogAdmin').hidden=!context.can_manage_catalog;el('sellingArea').hidden=!context.can_sell;
  await refresh();if(current!==generation)return;
  el('salesPanel').hidden=false;status('Đã tải dữ liệu cửa hàng. Chưa hỗ trợ bán offline.');
 });
});

const financePending=new Map();
async function financial(name,args){
 const key=JSON.stringify({name,store:store.id,args});
 if(!financePending.has(key))financePending.set(key,crypto.randomUUID());
 const result=await rpc(name,{...args,p_operation_id:financePending.get(key)});
 financePending.delete(key);return result;
}
function renderFinance(){
 el('financeArea').hidden=!(context.can_manage_shift||context.can_collect||context.can_void);
 el('openShiftForm').hidden=!context.can_manage_shift||!!currentShift;
 el('closeShiftForm').hidden=!context.can_manage_shift||!currentShift;
 el('shiftSummary').textContent=currentShift?`Ca ${currentShift.id.slice(0,8)} · Tiền đầu ca: ${money(currentShift.opening_amount)}`:'Bạn chưa có ca đang mở.';
 el('paymentForm').hidden=!context.can_collect||!currentShift||!editing||dirty;
 el('voidForm').hidden=!context.can_void||!editing||dirty;
 el('paymentOrderSummary').textContent=editing?`Đơn ${editing.id.slice(0,8)} · Cần thu ${money(editing.total_amount)}`:'Mở một đơn đã lưu để thu tiền.';
 el('refundArea').hidden=!context.can_refund||!currentShift;
 el('reportArea').hidden=!context.can_report;
}
async function refreshFinance(){
 const current=generation;
 const [shifts,paid,refunds]=await Promise.all([rows('cash_shifts','*','&order=opened_at.desc&limit=100'),rows('payments','*','&order=created_at.desc&limit=100'),rows('refunds','payment_id')]);
 if(current!==generation)return;
 currentShift=shifts.find(s=>s.opened_by===api.userId&&!s.closed_at)||null;
 payments=paid.filter(p=>!refunds.some(r=>r.payment_id===p.id));
 el('refundPayment').replaceChildren(option('','Chọn thanh toán'),...payments.map(p=>option(p.id,`${p.order_id.slice(0,8)} · ${p.method==='CASH'?'Tiền mặt':'Chuyển khoản'} · ${money(p.amount)}`)));
 el('shiftHistory').replaceChildren(...shifts.slice(0,20).map(s=>{const li=document.createElement('li');li.textContent=s.closed_at?`Ca ${s.id.slice(0,8)} · Dự kiến ${money(s.expected_cash)} · Thực đếm ${money(s.counted_cash)} · Lệch ${money(s.difference)}`:`Ca ${s.id.slice(0,8)} · Đang mở`;return li;}));
 if(!el('reportDate').value)el('reportDate').value=new Date().toLocaleDateString('sv-SE',{timeZone:store.timezone||'Asia/Ho_Chi_Minh'});
 renderFinance();
}
el('paymentMethod').addEventListener('change',()=>{el('transferConfirmField').hidden=el('paymentMethod').value!=='TRANSFER';el('transferConfirmed').checked=false;});
el('openShiftForm').addEventListener('submit',e=>{e.preventDefault();run(async()=>{
 const current=generation;await financial('rpc_open_shift',{p_opening_amount:Number(el('openingCash').value)});if(current!==generation)return;
 await refreshFinance();status('Đã mở ca.');
});});
el('closeShiftForm').addEventListener('submit',e=>{e.preventDefault();if(!currentShift)return;run(async()=>{
 const current=generation;const closed=await financial('rpc_close_shift',{p_shift_id:currentShift.id,p_counted_cash:Number(el('countedCash').value)});if(current!==generation)return;
 await refreshFinance();el('closeShiftForm').reset();status(`Đã chốt ca · Dự kiến ${money(closed.expected_cash)} · Thực đếm ${money(closed.counted_cash)} · Chênh lệch ${money(closed.difference)}.`);
});});
el('paymentForm').addEventListener('submit',e=>{e.preventDefault();if(!editing||dirty||!currentShift)return;run(async()=>{
 const current=generation;const payment=await financial('rpc_collect_payment',{p_order_id:editing.id,p_shift_id:currentShift.id,p_expected_revision:editing.revision,p_method:el('paymentMethod').value,p_received_amount:Number(el('receivedAmount').value),p_transfer_confirmed:el('transferConfirmed').checked});if(current!==generation)return;
 reset();el('paymentForm').reset();el('transferConfirmField').hidden=true;await refresh();status(`Đã thu ${money(payment.amount)} · Tiền thừa ${money(payment.change_amount)} · Đơn đã hoàn tất.`);
});});
el('voidForm').addEventListener('submit',e=>{e.preventDefault();if(!editing||dirty)return;run(async()=>{
 const current=generation;await financial('rpc_void_order',{p_order_id:editing.id,p_expected_revision:editing.revision,p_reason:el('voidReason').value.trim()});if(current!==generation)return;
 reset();el('voidForm').reset();await refresh();status('Đã hủy đơn và ghi nhận lý do.');
});});
el('refundForm').addEventListener('submit',e=>{e.preventDefault();if(!currentShift||!el('refundConfirmed').checked)return;run(async()=>{
 const current=generation;await financial('rpc_refund_payment',{p_payment_id:el('refundPayment').value,p_shift_id:currentShift.id,p_reason:el('refundReason').value.trim()});if(current!==generation)return;
 el('refundForm').reset();await refresh();status('Đã ghi nhận hoàn toàn bộ, giữ nguyên lịch sử thu tiền.');
});});
el('reportForm').addEventListener('submit',e=>{e.preventDefault();run(async()=>{
 const current=generation;const report=await rpc('rpc_daily_report',{p_date:el('reportDate').value});if(current!==generation)return;
 el('reportSummary').textContent=`${report.date} · ${report.timezone} · ${report.paid_orders} thanh toán · Đã thu ${money(report.gross)} · Hoàn ${money(report.refunds)} · Thu ròng ${money(Number(report.gross)-Number(report.refunds))}`;
});});
