import { isUnresolved } from './offline-store.mjs';
const el=id=>document.getElementById(id);
const money=value=>Number(value).toLocaleString('vi-VN')+' ₫';
const rpc=(client,store,name,args)=>client.request('/rest/v1/rpc/'+name,{method:'POST',body:{p_org_id:store.organization_id,p_store_id:store.id,...args}});

export async function submitOfflineReview(client,store,queue,record,note){
 const response=await rpc(client,store,'rpc_submit_offline_review',{p_operation_id:record.operationId,p_request:record.payload,p_note:note});
 if(response.operation_id!==record.operationId)throw new Error('INVALID_SERVER_ACK');
 if(response.status==='OPEN'&&response.review_id){
  await queue.update(record,{reviewId:response.review_id});
 }else if(['SYNCED','CANCELLED'].includes(response.status)){
  await queue.acceptResult(record,response.result);
 }else throw new Error('INVALID_SERVER_ACK');
 return response;
}
export async function receiveOfflineReviews(client,store,queue){
 const records=(await queue.list()).filter(isUnresolved);
 for(let start=0;start<records.length;start+=100){
  const batch=records.slice(start,start+100);
  const ids=batch.map(r=>encodeURIComponent(r.operationId)).join(',');
  const reviews=await client.request('/rest/v1/offline_sale_reviews?select=operation_id,status,result&store_id=eq.'+store.id+
   '&actor_id=eq.'+client.userId+'&operation_id=in.('+ids+')');
  for(const review of reviews){
   if(!['SYNCED','CANCELLED'].includes(review.status))continue;
   const record=batch.find(r=>r.operationId===review.operation_id);
   if(record)await queue.acceptResult(record,review.result);
  }
 }
}
export class OfflineReviewPanel {
 constructor({client,store,canReview,run,isCurrent,onResolved}){
  Object.assign(this,{client,store,canReview,run,isCurrent,onResolved,offset:0,pending:new Map()});
  el('offlineReviewArea').hidden=!canReview;
  el('reloadOfflineReviews').onclick=()=>run(()=>this.refresh());
  el('previousOfflineReviews').onclick=()=>run(()=>this.refresh(Math.max(0,this.offset-100)));
  el('nextOfflineReviews').onclick=()=>run(()=>this.refresh(this.offset+100));
 }
 async refresh(offset=this.offset){
  if(!this.canReview||!this.isCurrent())return;
  const rows=await this.client.request('/rest/v1/offline_sale_reviews?select=*&store_id=eq.'+this.store.id+
   '&status=eq.OPEN&order=created_at.asc,id.asc&limit=101&offset='+offset);
  if(!this.isCurrent())return;
  this.offset=offset;
  el('previousOfflineReviews').hidden=offset===0;
  el('nextOfflineReviews').hidden=rows.length<=100;
  const visible=rows.slice(0,100);
  el('offlineReviewCount').textContent=visible.length?'Đề nghị '+(offset+1)+'–'+(offset+visible.length)+(rows.length>100?' · Còn đề nghị ở trang tiếp theo.':''):'Không có đề nghị tại trang này.';
  el('offlineReviewList').replaceChildren(...visible.map(review=>this.row(review)));
 }
 row(review){
  const li=document.createElement('li'),details=document.createElement('details'),summary=document.createElement('summary');
  const request=review.request_payload;
  summary.textContent=review.sender_name+' · '+money(request.p_expected_total)+' · '+review.operation_id.slice(0,8);
  const text=document.createElement('p');text.textContent=review.note+' · Gửi lúc '+new Date(review.created_at).toLocaleString('vi-VN');
  details.append(summary,text);
  const facts=document.createElement('p');
  facts.textContent=(request.p_channel==='DINE_IN'?'Tại bàn':request.p_channel==='DELIVERY'?'Giao hàng':'Mang về')+
   (request.p_customer?.name?' · '+request.p_customer.name:'')+(request.p_customer?.phone?' · '+request.p_customer.phone:'')+
   (request.p_customer?.address?' · '+request.p_customer.address:'');
  details.append(facts);
  for(const [index,line] of request.p_items.entries()){
   const item=document.createElement('p');item.textContent=(review.item_labels?.[index]?.name||'Món '+line.variant_id)+' × '+line.quantity+
    (line.modifier_ids?.length?' · Topping: '+line.modifier_ids.join(', '):'');details.append(item);
  }
  const cash=request.p_received_amount!==null;
  const financial=document.createElement('p');financial.textContent=cash?
   'Khách đưa '+money(request.p_received_amount)+' · Tiền thừa '+money(request.p_received_amount-request.p_expected_total)+
    '. Ca gốc: '+request.p_shift_id+'. Cần trả lại '+money(request.p_expected_total)+' từ khoản tiền chưa lên sổ của đơn này. Thao tác này không điều chỉnh tiền mặt của ca khác.':
   'Bản ghi chưa thu tiền. Chỉ hủy nếu không tiếp tục phục vụ đơn này.';
  details.append(financial);
  const form=document.createElement('form'),label=document.createElement('label'),reason=document.createElement('input');
  label.textContent='Lý do duyệt hủy';reason.required=true;reason.minLength=3;reason.maxLength=500;reason.name='reason';label.append(reason);form.append(label);
  const confirmLabel=document.createElement('label'),confirm=document.createElement('input');
  confirm.type='checkbox';confirm.required=true;confirmLabel.className='modifier-choice';
  confirmLabel.append(confirm,document.createTextNode(cash?'Đã trả lại đúng '+money(request.p_expected_total)+' từ khoản tiền chưa lên sổ của đơn này':'Đã kiểm tra và xác nhận hủy bản ghi này'));
  form.append(confirmLabel);
  const button=document.createElement('button');button.type='submit';button.className='secondary';button.textContent='Duyệt hủy sau đối soát';form.append(button);
  form.addEventListener('submit',event=>{event.preventDefault();this.run(async()=>{
   if(!this.isCurrent()||!form.reportValidity())return;
   const args={p_review_id:review.id,p_reason:reason.value.trim(),p_cash_refunded:cash&&confirm.checked};
   const key=JSON.stringify(args);if(!this.pending.has(key))this.pending.set(key,crypto.randomUUID());
   const receipt=await rpc(this.client,this.store,'rpc_cancel_offline_review',{...args,p_operation_id:this.pending.get(key)});
   if(receipt.status!=='CANCELLED'||receipt.operation_id!==review.operation_id||receipt.review_id!==review.id||Number(receipt.cash_refund_amount)!==(cash?request.p_expected_total:0))throw new Error('INVALID_SERVER_ACK');
   this.pending.delete(key);
   if(!this.isCurrent())return;
   await this.onResolved(receipt);await this.refresh(0);
  });});
  details.append(form);li.append(details);return li;
 }
}
