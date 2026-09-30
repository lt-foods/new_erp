-- 只准在本機/隔離測試庫執行。全部業務列都是本檔建立的 ZZTEST fixture，絕不挑現有客單。
-- 整檔單一 transaction，最後 ROLLBACK；若中途任一斷言失敗，也不留測資。
BEGIN;

SET LOCAL request.jwt.claim  = '{"tenant_id":"face0000-0000-4000-8000-000000000030","app_metadata":{"role":"owner"},"sub":"face0000-0000-4000-8000-0000000000ff"}';
SET LOCAL request.jwt.claims = '{"tenant_id":"face0000-0000-4000-8000-000000000030","app_metadata":{"role":"owner"},"sub":"face0000-0000-4000-8000-0000000000ff"}';

CREATE TEMP TABLE _t_env ON COMMIT DROP AS
SELECT 'face0000-0000-4000-8000-000000000030'::UUID tenant,
       'face0000-0000-4000-8000-000000000031'::UUID other_tenant,
       'face0000-0000-4000-8000-0000000000ff'::UUID operator;
CREATE TEMP TABLE _t_ctx(k TEXT PRIMARY KEY, v BIGINT) ON COMMIT DROP;
CREATE TEMP TABLE _t_result(seq INT, item TEXT, pass BOOLEAN, detail TEXT) ON COMMIT DROP;

DO $$
DECLARE
  t UUID := (SELECT tenant FROM _t_env);
  ot UUID := (SELECT other_tenant FROM _t_env);
  op UUID := (SELECT operator FROM _t_env);
  loc BIGINT; st BIGINT; ch BIGINT; sup BIGINT; prod BIGINT; a BIGINT; b BIGINT;
  camp_qty BIGINT; camp_new BIGINT; camp_submit BIGINT; camp_split BIGINT;
  camp_merge BIGINT; camp_partial BIGINT; camp_dirty BIGINT; camp_dedupe BIGINT;
  ci BIGINT; ord BIGINT; ord2 BIGINT; pr BIGINT; item BIGINT; item2 BIGINT;
  oloc BIGINT; osup BIGINT; oprod BIGINT; osku BIGINT; opr BIGINT; oitem BIGINT;
BEGIN
  INSERT INTO locations(tenant_id,code,name,type)
  VALUES(t,'ZZTEST-QTY-LOC','【測試】請購同步總倉','central_warehouse') RETURNING id INTO loc;
  INSERT INTO stores(tenant_id,code,name,location_id)
  VALUES(t,'ZZTEST-QTY-ST','【測試】請購同步門市',loc) RETURNING id INTO st;
  INSERT INTO line_channels(tenant_id,code,name,home_store_id)
  VALUES(t,'ZZTEST-QTY-CH','【測試】請購同步頻道',st) RETURNING id INTO ch;
  INSERT INTO suppliers(tenant_id,code,name)
  VALUES(t,'ZZTEST-QTY-SUP','【測試】請購同步供應商') RETURNING id INTO sup;
  INSERT INTO products(tenant_id,product_code,name,status)
  VALUES(t,'ZZTEST-QTY-P','【測試】請購同步商品','active') RETURNING id INTO prod;
  INSERT INTO skus(tenant_id,product_id,sku_code,variant_name,status,product_name)
  VALUES(t,prod,'ZZTEST-QTY-A','A','active','【測試】請購同步商品') RETURNING id INTO a;
  INSERT INTO skus(tenant_id,product_id,sku_code,variant_name,status,product_name)
  VALUES(t,prod,'ZZTEST-QTY-B','B','active','【測試】請購同步商品') RETURNING id INTO b;
  INSERT INTO supplier_skus(tenant_id,supplier_id,sku_id,supplier_sku_code,is_preferred,default_unit_cost)
  VALUES(t,sup,a,'ZZTEST-QTY-SA',TRUE,10),(t,sup,b,'ZZTEST-QTY-SB',TRUE,20);

  -- 10 -> 9 -> 11 -> 0 實際重算 fixture。
  INSERT INTO group_buy_campaigns(tenant_id,campaign_no,name,status,end_at)
  VALUES(t,'ZZTEST-QTY-C1','【測試】數量變更團','locked',NOW()) RETURNING id INTO camp_qty;
  INSERT INTO campaign_items(tenant_id,campaign_id,sku_id,unit_price)
  VALUES(t,camp_qty,a,30) RETURNING id INTO ci;
  INSERT INTO customer_orders(tenant_id,order_no,campaign_id,channel_id,pickup_store_id,status)
  VALUES(t,'ZZTEST-QTY-O1',camp_qty,ch,st,'confirmed') RETURNING id INTO ord;
  INSERT INTO customer_order_items(tenant_id,order_id,campaign_item_id,sku_id,qty,unit_price,status)
  VALUES(t,ord,ci,a,10,30,'pending');
  INSERT INTO purchase_requests(tenant_id,pr_no,source_type,source_close_date,source_location_id,status,total_amount,created_by,updated_by)
  VALUES(t,'ZZTEST-QTY-PR1','close_date',CURRENT_DATE,loc,'draft',100,op,op) RETURNING id INTO pr;
  INSERT INTO purchase_request_campaigns(pr_id,campaign_id,tenant_id) VALUES(pr,camp_qty,t);
  INSERT INTO purchase_request_items(pr_id,sku_id,qty_requested,suggested_supplier_id,unit_cost,source_campaign_id,created_by,updated_by)
  VALUES(pr,a,10,sup,10,camp_qty,op,op) RETURNING id INTO item;
  INSERT INTO purchase_request_item_campaigns(tenant_id,pr_item_id,campaign_id,qty_requested)
  VALUES(t,item,camp_qty,10);
  INSERT INTO purchase_request_store_additions(tenant_id,pr_id,pr_item_id,campaign_id,store_id,sku_id,qty_added,request_key,created_by)
  VALUES(t,pr,item,camp_qty,st,a,1,'face0000-0000-4000-8000-000000000101',op);
  INSERT INTO _t_ctx VALUES ('loc',loc),('store',st),('channel',ch),('supplier',sup),('sku_a',a),('sku_b',b),
    ('qty_campaign',camp_qty),('qty_order',ord),('qty_pr',pr),('qty_item',item);

  -- 新 SKU 原 PR 無 item/attribution。
  INSERT INTO group_buy_campaigns(tenant_id,campaign_no,name,status,end_at)
  VALUES(t,'ZZTEST-QTY-C2','【測試】新 SKU 團','locked',NOW()) RETURNING id INTO camp_new;
  INSERT INTO campaign_items(tenant_id,campaign_id,sku_id,unit_price) VALUES(t,camp_new,a,30) RETURNING id INTO ci;
  INSERT INTO customer_orders(tenant_id,order_no,campaign_id,channel_id,pickup_store_id,status)
  VALUES(t,'ZZTEST-QTY-O2',camp_new,ch,st,'confirmed') RETURNING id INTO ord;
  INSERT INTO customer_order_items(tenant_id,order_id,campaign_item_id,sku_id,qty,unit_price,status)
  VALUES(t,ord,ci,a,5,30,'pending');
  INSERT INTO purchase_requests(tenant_id,pr_no,source_type,source_close_date,source_location_id,status,total_amount,created_by,updated_by)
  VALUES(t,'ZZTEST-QTY-PR-NEW','close_date',CURRENT_DATE,loc,'draft',50,op,op) RETURNING id INTO pr;
  INSERT INTO purchase_request_campaigns(pr_id,campaign_id,tenant_id) VALUES(pr,camp_new,t);
  INSERT INTO purchase_request_items(pr_id,sku_id,qty_requested,suggested_supplier_id,unit_cost,source_campaign_id,created_by,updated_by)
  VALUES(pr,a,5,sup,10,camp_new,op,op) RETURNING id INTO item;
  INSERT INTO purchase_request_item_campaigns(tenant_id,pr_item_id,campaign_id,qty_requested) VALUES(t,item,camp_new,5);
  INSERT INTO campaign_items(tenant_id,campaign_id,sku_id,unit_price) VALUES(t,camp_new,b,40) RETURNING id INTO ci;
  INSERT INTO customer_order_items(tenant_id,order_id,campaign_item_id,sku_id,qty,unit_price,status)
  VALUES(t,ord,ci,b,2,40,'pending');
  INSERT INTO _t_ctx VALUES ('new_campaign',camp_new),('new_pr',pr),('new_item_a',item);

  -- submit/split/merge 的各自正常 fixture。
  INSERT INTO group_buy_campaigns(tenant_id,campaign_no,name,status,end_at)
  VALUES(t,'ZZTEST-QTY-CSUB','【測試】submit','locked',NOW()) RETURNING id INTO camp_submit;
  INSERT INTO campaign_items(tenant_id,campaign_id,sku_id,unit_price) VALUES(t,camp_submit,a,30) RETURNING id INTO ci;
  INSERT INTO customer_orders(tenant_id,order_no,campaign_id,channel_id,pickup_store_id,status)
  VALUES(t,'ZZTEST-QTY-OSUB',camp_submit,ch,st,'confirmed') RETURNING id INTO ord;
  INSERT INTO customer_order_items(tenant_id,order_id,campaign_item_id,sku_id,qty,unit_price,status) VALUES(t,ord,ci,a,3,30,'pending');
  INSERT INTO purchase_requests(tenant_id,pr_no,source_type,source_close_date,source_location_id,status,total_amount,created_by,updated_by)
  VALUES(t,'ZZTEST-QTY-PRSUB','close_date',CURRENT_DATE,loc,'draft',30,op,op) RETURNING id INTO pr;
  INSERT INTO purchase_request_campaigns VALUES(pr,camp_submit,t,NOW());
  INSERT INTO purchase_request_items(pr_id,sku_id,qty_requested,suggested_supplier_id,unit_cost,source_campaign_id,created_by,updated_by)
  VALUES(pr,a,3,sup,10,camp_submit,op,op) RETURNING id INTO item;
  INSERT INTO purchase_request_item_campaigns(tenant_id,pr_item_id,campaign_id,qty_requested) VALUES(t,item,camp_submit,3);
  INSERT INTO _t_ctx VALUES ('submit_pr',pr),('submit_item',item);

  INSERT INTO group_buy_campaigns(tenant_id,campaign_no,name,status,end_at)
  VALUES(t,'ZZTEST-QTY-CSPLIT','【測試】split','locked',NOW()) RETURNING id INTO camp_split;
  INSERT INTO campaign_items(tenant_id,campaign_id,sku_id,unit_price) VALUES(t,camp_split,a,30) RETURNING id INTO ci;
  INSERT INTO customer_orders(tenant_id,order_no,campaign_id,channel_id,pickup_store_id,status)
  VALUES(t,'ZZTEST-QTY-OSPLIT',camp_split,ch,st,'confirmed') RETURNING id INTO ord;
  INSERT INTO customer_order_items(tenant_id,order_id,campaign_item_id,sku_id,qty,unit_price,status) VALUES(t,ord,ci,a,4,30,'pending');
  INSERT INTO purchase_requests(tenant_id,pr_no,source_type,source_close_date,source_location_id,status,review_status,total_amount,created_by,updated_by)
  VALUES(t,'ZZTEST-QTY-PRSPLIT','close_date',CURRENT_DATE,loc,'submitted','approved',40,op,op) RETURNING id INTO pr;
  INSERT INTO purchase_request_campaigns VALUES(pr,camp_split,t,NOW());
  INSERT INTO purchase_request_items(pr_id,sku_id,qty_requested,suggested_supplier_id,unit_cost,source_campaign_id,created_by,updated_by)
  VALUES(pr,a,4,sup,10,camp_split,op,op) RETURNING id INTO item;
  INSERT INTO purchase_request_item_campaigns(tenant_id,pr_item_id,campaign_id,qty_requested) VALUES(t,item,camp_split,4);
  INSERT INTO _t_ctx VALUES ('split_pr',pr);

  INSERT INTO group_buy_campaigns(tenant_id,campaign_no,name,status,end_at)
  VALUES(t,'ZZTEST-QTY-CMERGE','【測試】merge','locked',NOW()) RETURNING id INTO camp_merge;
  INSERT INTO campaign_items(tenant_id,campaign_id,sku_id,unit_price) VALUES(t,camp_merge,a,30) RETURNING id INTO ci;
  INSERT INTO customer_orders(tenant_id,order_no,campaign_id,channel_id,pickup_store_id,status)
  VALUES(t,'ZZTEST-QTY-OMERGE',camp_merge,ch,st,'confirmed') RETURNING id INTO ord;
  INSERT INTO customer_order_items(tenant_id,order_id,campaign_item_id,sku_id,qty,unit_price,status) VALUES(t,ord,ci,a,6,30,'pending');
  INSERT INTO purchase_requests(tenant_id,pr_no,source_type,source_close_date,source_location_id,status,review_status,total_amount,created_by,updated_by)
  VALUES(t,'ZZTEST-QTY-PRMERGE','close_date',CURRENT_DATE,loc,'submitted','approved',60,op,op) RETURNING id INTO pr;
  INSERT INTO purchase_request_campaigns VALUES(pr,camp_merge,t,NOW());
  INSERT INTO purchase_request_items(pr_id,sku_id,qty_requested,suggested_supplier_id,unit_cost,source_campaign_id,created_by,updated_by)
  VALUES(pr,a,6,sup,10,camp_merge,op,op) RETURNING id INTO item;
  INSERT INTO purchase_request_item_campaigns(tenant_id,pr_item_id,campaign_id,qty_requested) VALUES(t,item,camp_merge,6);
  INSERT INTO _t_ctx VALUES ('merge_pr',pr),('merge_item',item);

  -- partial 有兩列，addition 指向會搬走的 A。
  INSERT INTO group_buy_campaigns(tenant_id,campaign_no,name,status,end_at)
  VALUES(t,'ZZTEST-QTY-CPART','【測試】partial','locked',NOW()) RETURNING id INTO camp_partial;
  INSERT INTO campaign_items(tenant_id,campaign_id,sku_id,unit_price) VALUES(t,camp_partial,a,30) RETURNING id INTO ci;
  INSERT INTO customer_orders(tenant_id,order_no,campaign_id,channel_id,pickup_store_id,status)
  VALUES(t,'ZZTEST-QTY-OPART',camp_partial,ch,st,'confirmed') RETURNING id INTO ord;
  INSERT INTO customer_order_items(tenant_id,order_id,campaign_item_id,sku_id,qty,unit_price,status) VALUES(t,ord,ci,a,1,30,'pending');
  INSERT INTO campaign_items(tenant_id,campaign_id,sku_id,unit_price) VALUES(t,camp_partial,b,40) RETURNING id INTO ci;
  INSERT INTO customer_order_items(tenant_id,order_id,campaign_item_id,sku_id,qty,unit_price,status) VALUES(t,ord,ci,b,1,40,'pending');
  INSERT INTO purchase_requests(tenant_id,pr_no,source_type,source_close_date,source_location_id,status,total_amount,created_by,updated_by)
  VALUES(t,'ZZTEST-QTY-PRPART','close_date',CURRENT_DATE,loc,'draft',30,op,op) RETURNING id INTO pr;
  INSERT INTO purchase_request_campaigns VALUES(pr,camp_partial,t,NOW());
  INSERT INTO purchase_request_items(pr_id,sku_id,qty_requested,suggested_supplier_id,unit_cost,source_campaign_id,created_by,updated_by)
  VALUES(pr,a,1,sup,10,camp_partial,op,op) RETURNING id INTO item;
  INSERT INTO purchase_request_item_campaigns(tenant_id,pr_item_id,campaign_id,qty_requested) VALUES(t,item,camp_partial,1);
  INSERT INTO purchase_request_items(pr_id,sku_id,qty_requested,suggested_supplier_id,unit_cost,source_campaign_id,created_by,updated_by)
  VALUES(pr,b,1,sup,20,camp_partial,op,op) RETURNING id INTO item2;
  INSERT INTO purchase_request_item_campaigns(tenant_id,pr_item_id,campaign_id,qty_requested) VALUES(t,item2,camp_partial,1);
  INSERT INTO purchase_request_store_additions(tenant_id,pr_id,pr_item_id,campaign_id,store_id,sku_id,qty_added,request_key,created_by)
  VALUES(t,pr,item,camp_partial,st,a,1,'face0000-0000-4000-8000-000000000102',op);
  INSERT INTO _t_ctx VALUES ('partial_pr',pr),('partial_item',item);

  -- dirty failure 及 statement-level 去重使用的自有客單。
  INSERT INTO group_buy_campaigns(tenant_id,campaign_no,name,status,end_at)
  VALUES(t,'ZZTEST-QTY-CDIRTY','【測試】dirty','locked',NOW()) RETURNING id INTO camp_dirty;
  INSERT INTO campaign_items(tenant_id,campaign_id,sku_id,unit_price) VALUES(t,camp_dirty,a,30) RETURNING id INTO ci;
  INSERT INTO customer_orders(tenant_id,order_no,campaign_id,channel_id,pickup_store_id,status)
  VALUES(t,'ZZTEST-QTY-ODIRTY',camp_dirty,ch,st,'confirmed') RETURNING id INTO ord;
  INSERT INTO customer_order_items(tenant_id,order_id,campaign_item_id,sku_id,qty,unit_price,status) VALUES(t,ord,ci,a,1,30,'pending');
  INSERT INTO _t_ctx VALUES ('dirty_order',ord);

  INSERT INTO group_buy_campaigns(tenant_id,campaign_no,name,status,end_at)
  VALUES(t,'ZZTEST-QTY-CDEDUP','【測試】dedupe','locked',NOW()) RETURNING id INTO camp_dedupe;
  INSERT INTO campaign_items(tenant_id,campaign_id,sku_id,unit_price) VALUES(t,camp_dedupe,a,30) RETURNING id INTO ci;
  INSERT INTO customer_orders(tenant_id,order_no,campaign_id,channel_id,pickup_store_id,status)
  VALUES(t,'ZZTEST-QTY-ODEDUP1',camp_dedupe,ch,st,'confirmed') RETURNING id INTO ord;
  INSERT INTO customer_order_items(tenant_id,order_id,campaign_item_id,sku_id,qty,unit_price,status) VALUES(t,ord,ci,a,1,30,'pending');
  INSERT INTO customer_orders(tenant_id,order_no,campaign_id,channel_id,pickup_store_id,status)
  VALUES(t,'ZZTEST-QTY-ODEDUP2',camp_dedupe,ch,st,'confirmed') RETURNING id INTO ord2;
  INSERT INTO customer_order_items(tenant_id,order_id,campaign_item_id,sku_id,qty,unit_price,status) VALUES(t,ord2,ci,a,1,30,'pending');
  INSERT INTO _t_ctx VALUES ('dedupe_campaign',camp_dedupe),('dedupe_order1',ord),('dedupe_order2',ord2);

  -- 外租戶 item，只用來帶入 merge 輸入陣列，不會改它。
  INSERT INTO locations(tenant_id,code,name,type) VALUES(ot,'ZZTEST-QTY-OLOC','【測試】外租戶倉','central_warehouse') RETURNING id INTO oloc;
  INSERT INTO suppliers(tenant_id,code,name) VALUES(ot,'ZZTEST-QTY-OSUP','【測試】外租戶供應商') RETURNING id INTO osup;
  INSERT INTO products(tenant_id,product_code,name,status) VALUES(ot,'ZZTEST-QTY-OP','【測試】外租戶品','active') RETURNING id INTO oprod;
  INSERT INTO skus(tenant_id,product_id,sku_code,variant_name,status,product_name)
  VALUES(ot,oprod,'ZZTEST-QTY-OSKU','X','active','【測試】外租戶品') RETURNING id INTO osku;
  INSERT INTO purchase_requests(tenant_id,pr_no,source_type,source_location_id,status,review_status,total_amount,created_by,updated_by)
  VALUES(ot,'ZZTEST-QTY-OPR','manual',oloc,'submitted','approved',1,op,op) RETURNING id INTO opr;
  INSERT INTO purchase_request_items(pr_id,sku_id,qty_requested,suggested_supplier_id,unit_cost,created_by,updated_by)
  VALUES(opr,osku,1,osup,1,op,op) RETURNING id INTO oitem;
  INSERT INTO _t_ctx VALUES ('other_item',oitem);
END $$;

-- statement-level transition table 同一句兩列同 key，只得一列 revision=1。
DELETE FROM purchase_request_qty_dirty
 WHERE tenant_id=(SELECT tenant FROM _t_env) AND campaign_id=(SELECT v FROM _t_ctx WHERE k='dedupe_campaign');
UPDATE customer_order_items SET qty=qty+1
 WHERE order_id IN ((SELECT v FROM _t_ctx WHERE k='dedupe_order1'),(SELECT v FROM _t_ctx WHERE k='dedupe_order2'));
INSERT INTO _t_result
SELECT 10,'statement-level 去重',COUNT(*)=1 AND MIN(revision)=1,'rows='||COUNT(*)||', rev='||MIN(revision)
  FROM purchase_request_qty_dirty
 WHERE tenant_id=(SELECT tenant FROM _t_env) AND campaign_id=(SELECT v FROM _t_ctx WHERE k='dedupe_campaign');

-- 實際 preview/apply：10-1=9、10-1+2=11，最後歸零不刪追溯。
UPDATE customer_order_items SET qty=9 WHERE order_id=(SELECT v FROM _t_ctx WHERE k='qty_order');
INSERT INTO _t_result
SELECT 20,'preview 10-1=9',COUNT(*)=1 AND BOOL_AND(target_qty=9 AND delta_qty=-1),
       COALESCE(STRING_AGG(action_code||':'||target_qty,','),'no row')
  FROM rpc_preview_pr_qty_sync((SELECT v FROM _t_ctx WHERE k='qty_pr'))
 WHERE sku_id=(SELECT v FROM _t_ctx WHERE k='sku_a');
SELECT rpc_sync_pr_qty((SELECT v FROM _t_ctx WHERE k='qty_pr'),(SELECT operator FROM _t_env));
INSERT INTO _t_result SELECT 21,'apply 10-1=9',qty_requested=9,'qty='||qty_requested
  FROM purchase_request_items WHERE id=(SELECT v FROM _t_ctx WHERE k='qty_item');
UPDATE customer_order_items SET qty=11 WHERE order_id=(SELECT v FROM _t_ctx WHERE k='qty_order');
SELECT rpc_sync_pr_qty((SELECT v FROM _t_ctx WHERE k='qty_pr'),(SELECT operator FROM _t_env));
INSERT INTO _t_result SELECT 22,'apply 10-1+2=11',qty_requested=11,'qty='||qty_requested
  FROM purchase_request_items WHERE id=(SELECT v FROM _t_ctx WHERE k='qty_item');
UPDATE customer_orders SET status='cancelled' WHERE id=(SELECT v FROM _t_ctx WHERE k='qty_order');
SELECT rpc_sync_pr_qty((SELECT v FROM _t_ctx WHERE k='qty_pr'),(SELECT operator FROM _t_env));
INSERT INTO _t_result
SELECT 23,'qty0 保留 item/attribution/addition 且有 audit',
  (SELECT qty_requested=0 FROM purchase_request_items WHERE id=(SELECT v FROM _t_ctx WHERE k='qty_item'))
  AND (SELECT qty_requested=0 FROM purchase_request_item_campaigns WHERE pr_item_id=(SELECT v FROM _t_ctx WHERE k='qty_item'))
  AND EXISTS(SELECT 1 FROM purchase_request_store_additions WHERE pr_item_id=(SELECT v FROM _t_ctx WHERE k='qty_item'))
  AND (SELECT COUNT(*)=3 FROM purchase_request_qty_sync_log WHERE pr_item_id=(SELECT v FROM _t_ctx WHERE k='qty_item')),
  'trace rows kept';

-- 新 SKU 必須在 preview 看到，submit/split/merge 皆擋。
INSERT INTO _t_result SELECT 30,'preview 顯示 missing SKU',COUNT(*)=1 AND BOOL_AND(action_code='missing_item' AND pr_item_id IS NULL),
  STRING_AGG(action_code,',') FROM rpc_preview_pr_qty_sync((SELECT v FROM _t_ctx WHERE k='new_pr'))
 WHERE sku_id=(SELECT v FROM _t_ctx WHERE k='sku_b');
DO $$
DECLARE blocked BOOLEAN:=FALSE; msg TEXT;
BEGIN
  BEGIN PERFORM rpc_submit_pr((SELECT v FROM _t_ctx WHERE k='new_pr'),(SELECT operator FROM _t_env));
  EXCEPTION WHEN OTHERS THEN blocked:=TRUE; msg:=SQLERRM; END;
  INSERT INTO _t_result VALUES(31,'submit 擋新 SKU',blocked,COALESCE(msg,'not blocked'));
  UPDATE purchase_requests SET status='submitted',review_status='approved' WHERE id=(SELECT v FROM _t_ctx WHERE k='new_pr');
  blocked:=FALSE; msg:=NULL;
  BEGIN PERFORM rpc_split_pr_to_pos((SELECT v FROM _t_ctx WHERE k='new_pr'),(SELECT v FROM _t_ctx WHERE k='loc'),(SELECT operator FROM _t_env));
  EXCEPTION WHEN OTHERS THEN blocked:=TRUE; msg:=SQLERRM; END;
  INSERT INTO _t_result VALUES(32,'split 擋新 SKU',blocked,COALESCE(msg,'not blocked'));
  blocked:=FALSE; msg:=NULL;
  BEGIN PERFORM rpc_merge_prs_to_po((SELECT tenant FROM _t_env),ARRAY[(SELECT v FROM _t_ctx WHERE k='new_item_a')],
    (SELECT v FROM _t_ctx WHERE k='supplier'),(SELECT v FROM _t_ctx WHERE k='loc'),'ZZTEST-QTY-PO-NEW',(SELECT operator FROM _t_env));
  EXCEPTION WHEN OTHERS THEN blocked:=TRUE; msg:=SQLERRM; END;
  INSERT INTO _t_result VALUES(33,'merge 擋新 SKU',blocked,COALESCE(msg,'not blocked'));
END $$;

-- 混入外租戶 id 要在花錢前整筆拒絕，合法 item 也不得被回寫。
DO $$
DECLARE blocked BOOLEAN:=FALSE; msg TEXT; before_po BIGINT; after_po BIGINT; before_count INTEGER; after_count INTEGER;
BEGIN
  SELECT po_item_id INTO before_po FROM purchase_request_items WHERE id=(SELECT v FROM _t_ctx WHERE k='merge_item');
  SELECT COUNT(*) INTO before_count FROM purchase_orders WHERE po_no='ZZTEST-QTY-PO-XTENANT';
  BEGIN PERFORM rpc_merge_prs_to_po((SELECT tenant FROM _t_env),
    ARRAY[(SELECT v FROM _t_ctx WHERE k='merge_item'),(SELECT v FROM _t_ctx WHERE k='other_item')],
    (SELECT v FROM _t_ctx WHERE k='supplier'),(SELECT v FROM _t_ctx WHERE k='loc'),'ZZTEST-QTY-PO-XTENANT',(SELECT operator FROM _t_env));
  EXCEPTION WHEN OTHERS THEN blocked:=TRUE; msg:=SQLERRM; END;
  SELECT po_item_id INTO after_po FROM purchase_request_items WHERE id=(SELECT v FROM _t_ctx WHERE k='merge_item');
  SELECT COUNT(*) INTO after_count FROM purchase_orders WHERE po_no='ZZTEST-QTY-PO-XTENANT';
  INSERT INTO _t_result VALUES(40,'merge 外租戶整筆拒絕',
    blocked AND before_po IS NOT DISTINCT FROM after_po AND before_count=after_count,COALESCE(msg,'not blocked'));
END $$;

DO $$
DECLARE blocked BOOLEAN; msg TEXT;
BEGIN
  blocked:=FALSE;
  BEGIN PERFORM rpc_merge_prs_to_po((SELECT tenant FROM _t_env),ARRAY[(SELECT v FROM _t_ctx WHERE k='submit_item')],
    (SELECT v FROM _t_ctx WHERE k='supplier'),(SELECT v FROM _t_ctx WHERE k='loc'),'ZZTEST-QTY-PO-DRAFT',(SELECT operator FROM _t_env));
  EXCEPTION WHEN OTHERS THEN blocked:=TRUE; msg:=SQLERRM; END;
  INSERT INTO _t_result VALUES(41,'merge 草稿未核准拒絕',blocked,COALESCE(msg,'not blocked'));
  blocked:=FALSE; msg:=NULL;
  BEGIN PERFORM rpc_merge_prs_to_po((SELECT tenant FROM _t_env),ARRAY[(SELECT v FROM _t_ctx WHERE k='merge_item'),9223372036854770000::BIGINT],
    (SELECT v FROM _t_ctx WHERE k='supplier'),(SELECT v FROM _t_ctx WHERE k='loc'),'ZZTEST-QTY-PO-MISSING',(SELECT operator FROM _t_env));
  EXCEPTION WHEN OTHERS THEN blocked:=TRUE; msg:=SQLERRM; END;
  INSERT INTO _t_result VALUES(42,'merge 不存在 id 整筆拒絕',blocked,COALESCE(msg,'not blocked'));
END $$;

-- 三條正常路徑也要真正呼叫，避免只測「會擋」。
SELECT rpc_submit_pr((SELECT v FROM _t_ctx WHERE k='submit_pr'),(SELECT operator FROM _t_env));
INSERT INTO _t_result SELECT 50,'submit 正常',status='submitted','status='||status FROM purchase_requests WHERE id=(SELECT v FROM _t_ctx WHERE k='submit_pr');
SELECT rpc_split_pr_to_pos((SELECT v FROM _t_ctx WHERE k='split_pr'),(SELECT v FROM _t_ctx WHERE k='loc'),(SELECT operator FROM _t_env));
INSERT INTO _t_result SELECT 51,'split 正常',status='fully_ordered','status='||status FROM purchase_requests WHERE id=(SELECT v FROM _t_ctx WHERE k='split_pr');
SELECT rpc_merge_prs_to_po((SELECT tenant FROM _t_env),ARRAY[(SELECT v FROM _t_ctx WHERE k='merge_item'),(SELECT v FROM _t_ctx WHERE k='merge_item')],
  (SELECT v FROM _t_ctx WHERE k='supplier'),(SELECT v FROM _t_ctx WHERE k='loc'),'ZZTEST-QTY-PO-MERGE',(SELECT operator FROM _t_env));
INSERT INTO _t_result SELECT 52,'merge 重複 id 先去重後正常',po_item_id IS NOT NULL,'po_item='||COALESCE(po_item_id::TEXT,'null')
  FROM purchase_request_items WHERE id=(SELECT v FROM _t_ctx WHERE k='merge_item');

-- partial 只搬 draft：item id 保留，addition.pr_id 跟著新單。
CREATE TEMP TABLE _t_partial_result ON COMMIT DROP AS
SELECT rpc_create_partial_pr_from_items((SELECT v FROM _t_ctx WHERE k='partial_pr'),ARRAY[(SELECT v FROM _t_ctx WHERE k='partial_item')],(SELECT operator FROM _t_env)) AS j;
INSERT INTO _t_result
SELECT 60,'partial additions pr_id/pr_item_id 一致',
  psa.pr_id=(r.j->>'new_pr_id')::BIGINT AND psa.pr_item_id=(SELECT v FROM _t_ctx WHERE k='partial_item')
    AND pri.pr_id=psa.pr_id,
  'addition_pr='||psa.pr_id||', item_pr='||pri.pr_id
  FROM _t_partial_result r
  JOIN purchase_request_store_additions psa ON psa.pr_item_id=(SELECT v FROM _t_ctx WHERE k='partial_item')
  JOIN purchase_request_items pri ON pri.id=psa.pr_item_id;

-- 故意讓 dirty upsert 失敗；只取消本檔自己建的 ZZTEST 客單。
CREATE OR REPLACE FUNCTION pg_temp.fail_pr_dirty_write() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'intentional dirty queue failure'; END $$;
CREATE TRIGGER test_fail_pr_dirty_write BEFORE INSERT OR UPDATE ON purchase_request_qty_dirty
FOR EACH ROW EXECUTE FUNCTION pg_temp.fail_pr_dirty_write();
UPDATE customer_orders SET status='cancelled' WHERE id=(SELECT v FROM _t_ctx WHERE k='dirty_order');
INSERT INTO _t_result SELECT 70,'dirty 失敗不擋取消',status='cancelled','status='||status
  FROM customer_orders WHERE id=(SELECT v FROM _t_ctx WHERE k='dirty_order');
DROP TRIGGER test_fail_pr_dirty_write ON purchase_request_qty_dirty;

-- FK 生命週期與鎖順序的結構驗證。
INSERT INTO _t_result
SELECT 80,'dirty FK ON DELETE CASCADE',COUNT(*)=2 AND BOOL_AND(confdeltype='c'),STRING_AGG(conname||':'||confdeltype,',')
  FROM pg_constraint WHERE conrelid='public.purchase_request_qty_dirty'::regclass AND contype='f';
INSERT INTO _t_result
SELECT 81,'#982/#995/sync 同 advisory key 且 sync 先鎖',
  pg_get_functiondef('public._pr_apply_qty_sync(bigint,uuid)'::regprocedure) LIKE '%hashtext(r.campaign_id::TEXT)%hashtext(r.sku_id::TEXT)%'
  AND STRPOS(pg_get_functiondef('public._pr_apply_qty_sync(bigint,uuid)'::regprocedure),'pg_advisory_xact_lock')
      < STRPOS(pg_get_functiondef('public._pr_apply_qty_sync(bigint,uuid)'::regprocedure),'FOR UPDATE')
  AND pg_get_functiondef('public.rpc_add_pr_store_demands(bigint,bigint,bigint,jsonb,uuid,uuid)'::regprocedure)
      LIKE '%hashtext(p_campaign_id::TEXT)%hashtext(v_sku_id::TEXT)%',
  'lock definitions checked';

DO $$
DECLARE bad TEXT;
BEGIN
  SELECT STRING_AGG(seq||' '||item||' ['||COALESCE(detail,'')||']',E'\n' ORDER BY seq) INTO bad FROM _t_result WHERE NOT pass;
  IF bad IS NOT NULL THEN RAISE EXCEPTION E'❌ PR qty resync fixture failed:\n%',bad; END IF;
END $$;

SELECT seq,item,'✅' AS result,detail FROM _t_result ORDER BY seq;
ROLLBACK;
