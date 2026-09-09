#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const { JSDOM } = require('jsdom');
const React = require('react');
const { act } = React;
let createRoot;

const repoRoot = path.resolve(__dirname, '../..');
const pageRel = 'apps/admin/src/app/(protected)/wms/return-disposition/page.tsx';
const pageFile = path.join(repoRoot, pageRel);
const source = fs.readFileSync(pageFile, 'utf8');
const sourceFile = ts.createSourceFile(pageRel, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);

function lineOf(needle) {
  const idx = source.indexOf(needle);
  if (idx === -1) return '?';
  return sourceFile.getLineAndCharacterOfPosition(idx).line + 1;
}

function fail(name, actual, expected) {
  failures.push({ name, actual, expected });
}

function expect(name, pass, actual, expected) {
  if (!pass) fail(name, actual, expected);
}

const observations = [];
function observe(name, actual) {
  observations.push({ name, actual });
}

function textOf(node) {
  return (node.textContent || '').replace(/\s+/g, ' ').trim();
}

function byText(selector, text) {
  const found = [...document.querySelectorAll(selector)].find((el) => textOf(el).includes(text));
  if (!found) throw new Error(`找不到 ${selector} containing ${text}`);
  return found;
}

async function tick() {
  await act(async () => {
    await Promise.resolve();
    await new Promise((resolve) => setImmediate(resolve));
  });
}

async function click(el) {
  await act(async () => {
    el.dispatchEvent(new window.MouseEvent('click', { bubbles: true, cancelable: true }));
  });
  await tick();
}

async function input(el, value) {
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  await act(async () => {
    setter.call(el, value);
    el.dispatchEvent(new window.InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' }));
    el.dispatchEvent(new window.Event('change', { bubbles: true }));
  });
  await tick();
}

function makeUuidFactory() {
  let n = 0;
  return () => {
    n += 1;
    return `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
  };
}

const TENANT_A = '11111111-1111-1111-1111-111111111111';
const TENANT_B = '33333333-3333-3333-3333-333333333333';
const USER_A = '22222222-2222-2222-2222-222222222222';
const USER_B = '44444444-4444-4444-4444-444444444444';

function makeSupabase(rpcCalls) {
  const responses = {
    v_hq_return_batches_list: [
      {
        id: 101,
        tenant_id: TENANT_A,
        location_id: 10,
        sku_id: 101,
        source_movement_id: 8001,
        source_transfer_item_id: 501,
        source_kind: 'store_return',
        source_reason: 'fixture',
        total_qty: 10,
        unit_cost: 100,
        qty_good: 0,
        qty_damaged: 0,
        qty_lost: 0,
        qty_revoked: 0,
        qty_pending: 10,
        status: 'pending',
        auto_flag: 'manual',
        created_by: USER_A,
        created_at: '2026-09-07T00:00:00Z',
        updated_at: '2026-09-07T00:00:00Z',
      },
      {
        id: 102,
        tenant_id: TENANT_A,
        location_id: 10,
        sku_id: 101,
        source_movement_id: 8002,
        source_transfer_item_id: 502,
        source_kind: 'shortage',
        source_reason: 'shortage: fixture',
        total_qty: 5,
        unit_cost: 100,
        qty_good: 0,
        qty_damaged: 0,
        qty_lost: 0,
        qty_revoked: 0,
        qty_pending: 5,
        status: 'pending',
        auto_flag: 'manual',
        created_by: USER_A,
        created_at: '2026-09-07T00:01:00Z',
        updated_at: '2026-09-07T00:01:00Z',
      },
    ],
    hq_return_events: [],
    skus: [{ id: 101, sku_code: 'SKU-101', product_name: '測試商品', variant_name: null }],
    transfer_items: [
      { id: 501, transfer_id: 601 },
      { id: 502, transfer_id: 602 },
    ],
    transfers: [
      { id: 601, transfer_no: 'TR-STORE-RETURN', source_location: 21, dest_location: 10 },
      { id: 602, transfer_no: 'TR-SHORTAGE', source_location: 10, dest_location: 22 },
    ],
    locations: [
      { id: 10, name: '總倉' },
      { id: 21, name: '退貨門市' },
      { id: 22, name: '短少門市' },
    ],
  };

  function query(table) {
    const filters = [];
    let rangeFrom = null;
    let rangeTo = null;
    const q = {
      select() { return q; },
      order() { return q; },
      limit() { return q; },
      range(from, to) { rangeFrom = from; rangeTo = to; return q; },
      in(column, values) { filters.push((row) => values.includes(row[column])); return q; },
      eq(column, value) { filters.push((row) => row[column] === value); return q; },
      then(resolve, reject) {
        let data = (responses[table] || []).filter((row) => filters.every((fn) => fn(row)));
        if (rangeFrom !== null && rangeTo !== null) data = data.slice(rangeFrom, rangeTo + 1);
        return Promise.resolve({ data, error: null }).then(resolve, reject);
      },
    };
    return q;
  }

  return {
    from: query,
    rpc(name, payload) {
      if (name === 'rpc_get_staff_names') return Promise.resolve({ data: [], error: null });
      if (name === 'rpc_dispose_hq_return') {
        rpcCalls.push(payload);
        return Promise.resolve({
          data: null,
          error: new Error('timeout after commit is unknown'),
        });
      }
      return Promise.resolve({ data: null, error: new Error(`unexpected rpc ${name}`) });
    },
  };
}

function makeAuth(userId = USER_A, tenantId = TENANT_A, role = 'owner') {
  return {
    user: {
      id: userId,
      app_metadata: { role, tenant_id: tenantId },
    },
    tenant: { id: tenantId },
    loading: false,
  };
}

function loadPage(rpcCalls, auth = makeAuth()) {
  const js = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2020,
      jsx: ts.JsxEmit.ReactJSX,
      esModuleInterop: true,
    },
    fileName: pageRel,
  }).outputText;

  const uuid = makeUuidFactory();
  const sandbox = {
    console,
    crypto: { randomUUID: uuid },
    window: global.window,
    document: global.document,
    navigator: global.navigator,
    localStorage: global.localStorage,
    sessionStorage: global.sessionStorage,
    module: { exports: {} },
    exports: {},
    require(id) {
      if (id === 'react') return React;
      if (id === 'react/jsx-runtime') return require('react/jsx-runtime');
      if (id === 'next/link') {
        return { __esModule: true, default: ({ href, children, ...props }) => React.createElement('a', { href, ...props }, children) };
      }
      if (id === '@/lib/supabase') return { getSupabase: () => makeSupabase(rpcCalls) };
      if (id === '@/components/AuthProvider') return { useAuth: () => auth };
      if (id === '@/lib/fetchAllRows') return {
        fetchAllRows: async (builder) => {
          const { data, error } = await builder();
          if (error) throw error;
          return data || [];
        },
      };
      if (id === '@/lib/rpcError') return { translateRpcError: (err) => err?.message || String(err) };
      if (id === '@/lib/role') {
        return {
          useRole: () => auth.user?.app_metadata?.role ?? null,
          isHqRole: () => true,
          canSeeCost: () => false,
        };
      }
      if (id === '@/components/Spinner') return { LoadingBlock: () => React.createElement('div', null, 'loading') };
      if (id === '@/components/SpinButton') return { __esModule: true, default: ({ children, loading, ...props }) => React.createElement('button', props, children) };
      throw new Error(`unexpected require: ${id}`);
    },
  };
  vm.createContext(sandbox);
  vm.runInContext(js, sandbox, { filename: pageRel });
  return sandbox.module.exports.default || sandbox.exports.default;
}

async function renderPage(Page) {
  document.body.innerHTML = '<div id="root"></div>';
  const root = createRoot(document.getElementById('root'));
  await act(async () => {
    root.render(React.createElement(Page));
  });
  await tick();
  await tick();
  return root;
}

async function submitGoodQty(value) {
  const goodInput = document.querySelector('#return-good-qty');
  if (!goodInput) throw new Error('找不到完好數量 input');
  await input(goodInput, value);
  const goodsConfirmed = document.querySelector('#return-goods-confirmed');
  if (!goodsConfirmed) throw new Error('找不到實物已到 checkbox');
  if (!goodsConfirmed.checked) await click(goodsConfirmed);
  await click(byText('button', '送出處理'));
}

async function trySubmitGoodQty(value) {
  const goodInput = document.querySelector('#return-good-qty');
  const submitButton = [...document.querySelectorAll('button')]
    .find((button) => textOf(button).includes('送出處理'));
  if (!goodInput || goodInput.disabled || !submitButton || submitButton.disabled) return false;
  await input(goodInput, value);
  const goodsConfirmed = document.querySelector('#return-goods-confirmed');
  if (!goodsConfirmed || goodsConfirmed.disabled) return false;
  if (!goodsConfirmed.checked) await click(goodsConfirmed);
  await click(submitButton);
  return true;
}

async function clickBatch(id) {
  await click(byText('button', `#${id}`));
}

async function clickIfEnabled(text) {
  const button = [...document.querySelectorAll('button')]
    .find((el) => textOf(el).includes(text));
  if (!button || button.disabled) return false;
  await click(button);
  return true;
}

const SUBMIT_PAYLOAD_KEYS = [
  'p_batch_id',
  'p_request_id',
  'p_qty_good',
  'p_qty_damaged',
  'p_qty_lost',
  'p_damage_reason',
  'p_loss_reason',
  'p_goods_confirmed',
  'p_notes',
];

function payloadSnapshot(payload) {
  if (!payload) return '(missing)';
  return SUBMIT_PAYLOAD_KEYS.map((key) => `${key}=${JSON.stringify(payload[key])}`).join(', ');
}

const failures = [];

async function runUnknownDeliveryScenario() {
  const rpcCalls = [];
  const Page = loadPage(rpcCalls);
  let root = await renderPage(Page);
  await clickBatch(101);
  await submitGoodQty('1');

  const first = rpcCalls[0];
  expect(
    '第一次送出要打到 rpc_dispose_hq_return',
    Boolean(first),
    first ? payloadSnapshot(first) : 'missing first rpc',
    'one rpc payload for initial submit',
  );

  const regenerateButton = [...document.querySelectorAll('button')]
    .find((button) => textOf(button).includes('重新產生 Request ID'));
  const enabledQtyInputsAfterUnknown = [...document.querySelectorAll('input[inputmode="decimal"]')]
    .filter((el) => !el.disabled).length;

  observe(
    '未知錯誤後數量欄位啟用數',
    `${enabledQtyInputsAfterUnknown} enabled decimal input(s)`,
  );
  expect(
    '未知送出結果後不可提供可按的換 request id 按鈕',
    !(regenerateButton && !regenerateButton.disabled),
    regenerateButton ? `button enabled=${!regenerateButton.disabled} (L${lineOf('重新產生 Request ID')})` : 'button absent',
    'button absent or disabled until request is confirmed/rejected',
  );
  expect(
    '未知送出結果後數量欄位要鎖住',
    enabledQtyInputsAfterUnknown === 0,
    `${enabledQtyInputsAfterUnknown} enabled decimal input(s)`,
    '0 enabled decimal input',
  );

  await clickBatch(102);
  expect(
    '未知送出結果後不可切到另一批',
    document.querySelector('#return-good-qty')?.disabled === true && textOf(document.body).includes('批次 #101'),
    textOf(document.body),
    'still locked on batch #101',
  );

  const beforeResend = rpcCalls.length;
  await clickIfEnabled('重新傳送原資料');
  const resent = rpcCalls[beforeResend];
  expect(
    '未知結果後若重送，payload 要維持原包',
    Boolean(resent) && payloadSnapshot(resent) === payloadSnapshot(first),
    resent ? `resent ${payloadSnapshot(resent)}; first ${payloadSnapshot(first)}` : 'missing resend rpc',
    'same full payload as first unknown request',
  );
  expect(
    '未知結果後若重送，不得換新 request id',
    Boolean(resent) && resent.p_request_id === first.p_request_id,
    resent ? `resent request=${resent.p_request_id}; first request=${first.p_request_id}` : 'missing resend rpc',
    'same request id as first unknown request',
  );

  await act(async () => root.unmount());
  root = null;
  root = await renderPage(Page);
  expect(
    '關頁重開後要恢復待確認批次',
    textOf(document.body).includes('批次 #101') && textOf(document.body).includes('上一筆送出結果還沒查明'),
    textOf(document.body),
    'batch #101 restored and locked',
  );
  const beforeReopened = rpcCalls.length;
  await clickIfEnabled('重新傳送原資料');
  const reopened = rpcCalls[beforeReopened];
  expect(
    '關頁重開後若允許重送，payload 要維持原包',
    Boolean(reopened) && payloadSnapshot(reopened) === payloadSnapshot(first),
    reopened ? `reopened ${payloadSnapshot(reopened)}; first ${payloadSnapshot(first)}` : 'missing reopened rpc',
    'same full payload restored after remount/reload',
  );

  await act(async () => root.unmount());
}

async function runInputGuardScenario() {
  const rpcCalls = [];
  const Page = loadPage(rpcCalls);
  const root = await renderPage(Page);
  await clickBatch(101);
  const goodInput = document.querySelector('#return-good-qty');
  if (!goodInput) throw new Error('找不到完好數量 input');
  const cases = ['1e3', '-1', '1.0001', '11'];
  for (const value of cases) {
    await input(goodInput, value);
    expect(
      `非法/超量輸入 ${value} 編輯中不可被改值`,
      goodInput.value === value,
      goodInput.value,
      value,
    );
    const before = rpcCalls.length;
    await click(byText('button', '送出處理'));
    expect(
      `非法/超量輸入 ${value} 不可送 RPC`,
      rpcCalls.length === before,
      `${rpcCalls.length - before} new rpc call(s)`,
      '0 new rpc call',
    );
  }
  await input(goodInput, '0.125');
  const goodsConfirmed = document.querySelector('#return-goods-confirmed');
  if (goodsConfirmed && !goodsConfirmed.checked) await click(goodsConfirmed);
  const before = rpcCalls.length;
  await click(byText('button', '送出處理'));
  expect(
    '合法三位小數可送出',
    rpcCalls.length === before + 1 && rpcCalls[before].p_qty_good === 0.125,
    rpcCalls[before] ? payloadSnapshot(rpcCalls[before]) : 'no rpc',
    'one rpc with p_qty_good=0.125',
  );
  await act(async () => root.unmount());
}

async function runStorageFailureScenario() {
  const rpcCalls = [];
  const originalSetItem = window.Storage.prototype.setItem;
  window.Storage.prototype.setItem = function setItemFailure() {
    throw new Error('storage disabled');
  };
  try {
    const Page = loadPage(rpcCalls);
    const root = await renderPage(Page);
    await clickBatch(101);
    await submitGoodQty('1');
    expect(
      '本機無法保存待確認包時不可送 RPC',
      rpcCalls.length === 0,
      `${rpcCalls.length} rpc call(s)`,
      '0 rpc call',
    );
    await act(async () => root.unmount());
  } finally {
    window.Storage.prototype.setItem = originalSetItem;
  }
}

async function runCrossTenantUserStorageScenario() {
  const request = {
    schemaVersion: 1,
    tenantId: TENANT_A,
    operatorId: USER_A,
    batchId: 101,
    requestId: '00000000-0000-4000-8000-000000000099',
    createdAt: new Date().toISOString(),
    payload: {
      p_batch_id: 101,
      p_request_id: '00000000-0000-4000-8000-000000000099',
      p_qty_good: 1,
      p_qty_damaged: 0,
      p_qty_lost: 0,
      p_damage_reason: null,
      p_loss_reason: null,
      p_goods_confirmed: true,
      p_notes: null,
    },
  };
  window.localStorage.setItem(`new-erp:hq-return-disposition:pending:v1:${TENANT_A}:${USER_A}`, JSON.stringify(request));

  const rpcCalls = [];
  const Page = loadPage(rpcCalls, makeAuth(USER_B, TENANT_B, 'owner'));
  const root = await renderPage(Page);
  expect(
    '不同租戶/使用者不應恢復別人的待確認包',
    !textOf(document.body).includes('上一筆送出結果還沒查明'),
    textOf(document.body),
    'no pending request restored',
  );
  await clickBatch(101);
  await submitGoodQty('1');
  expect(
    '不同租戶/使用者送出前會因批次 tenant 不符被前端擋下',
    rpcCalls.length === 0 && textOf(document.body).includes('不屬於目前登入的公司'),
    `${rpcCalls.length} rpc call(s); body=${textOf(document.body)}`,
    '0 rpc call and tenant mismatch error',
  );
  await act(async () => root.unmount());
}

(async () => {
  global.IS_REACT_ACT_ENVIRONMENT = true;
  const dom = new JSDOM('<!doctype html><html><body></body></html>', { url: 'http://localhost/wms/return-disposition' });
  try {
    global.window = dom.window;
    global.document = dom.window.document;
    Object.defineProperty(global, 'navigator', {
      value: dom.window.navigator,
      configurable: true,
    });
    global.HTMLElement = dom.window.HTMLElement;
    global.HTMLInputElement = dom.window.HTMLInputElement;
    global.Event = dom.window.Event;
    global.InputEvent = dom.window.InputEvent;
    global.MouseEvent = dom.window.MouseEvent;
    global.localStorage = dom.window.localStorage;
    global.sessionStorage = dom.window.sessionStorage;
    ({ createRoot } = require('react-dom/client'));

    await runUnknownDeliveryScenario();
    window.localStorage.clear();
    await runInputGuardScenario();
    window.localStorage.clear();
    await runStorageFailureScenario();
    window.localStorage.clear();
    await runCrossTenantUserStorageScenario();

    const hasDurableStorage = /\b(localStorage|sessionStorage|indexedDB)\b/.test(source);
    const looksUpEventByRequestId =
      /\.from\("hq_return_events"\)[\s\S]*?\.eq\("request_id"/.test(source);
    const usesMemoryRef = source.includes('const requestIdRef = useRef(newRequestId())');
    const handleSelectClearsPending =
      /const handleSelect = useCallback\([\s\S]*?resetForm\(\);[\s\S]*?\[resetForm\]/.test(source);
    const resetRegeneratesRequest =
      /const resetForm = useCallback\([\s\S]*?requestIdRef\.current = newRequestId\(\);[\s\S]*?\[\]/.test(source);
    observe(
      '原碼觀察：待確認包恢復機制',
      `durableStorage=${hasDurableStorage}; eventLookupByRequestId=${looksUpEventByRequestId}; memoryRequestRef=${usesMemoryRef} (request ref L${lineOf('const requestIdRef = useRef(newRequestId())')})`,
    );
    observe(
      '原碼觀察：切批是否會重設 request',
      `handleSelectCallsReset=${handleSelectClearsPending} (L${lineOf('const handleSelect = useCallback')}); resetRegeneratesRequest=${resetRegeneratesRequest} (L${lineOf('const resetForm = useCallback')})`,
    );

    console.log(`rendered ${pageRel}`);
    for (const o of observations) {
      console.log(`OBSERVE - ${o.name}`);
      console.log(`  actual:   ${o.actual}`);
    }

    if (failures.length === 0) {
      console.log('ok - return-disposition submit retry runtime checks');
    } else {
      for (const f of failures) {
        console.log(`FAIL - ${f.name}`);
        console.log(`  actual:   ${f.actual}`);
        console.log(`  expected: ${f.expected}`);
      }
      console.log(`${failures.length} failed`);
      process.exitCode = 1;
    }
  } finally {
    dom.window.close();
  }
})().catch((err) => {
  console.error(err.stack || err);
  process.exit(1);
});
