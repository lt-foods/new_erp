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

function makeSupabase(rpcCalls) {
  const responses = {
    v_hq_return_batches_list: [
      {
        id: 101,
        tenant_id: '11111111-1111-1111-1111-111111111111',
        location_id: 10,
        sku_id: 101,
        source_movement_id: 8001,
        source_transfer_item_id: null,
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
        created_by: '22222222-2222-2222-2222-222222222222',
        created_at: '2026-09-07T00:00:00Z',
        updated_at: '2026-09-07T00:00:00Z',
      },
    ],
    hq_return_events: [],
    locations: [],
  };

  function query(table) {
    const q = {
      select() { return q; },
      order() { return q; },
      limit() { return q; },
      in() { return q; },
      eq() { return q; },
      then(resolve, reject) {
        return Promise.resolve({ data: responses[table] || [], error: null }).then(resolve, reject);
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

function loadPage(rpcCalls) {
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
      if (id === '@/lib/fetchAllRows') return { fetchAllRows: async () => [] };
      if (id === '@/lib/rpcError') return { translateRpcError: (err) => err?.message || String(err) };
      if (id === '@/lib/role') {
        return {
          useRole: () => 'owner',
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
  const goodInput = document.querySelector('input[type="number"]');
  if (!goodInput) throw new Error('找不到完好數量 input');
  await input(goodInput, value);
  const checks = [...document.querySelectorAll('input[type="checkbox"]')];
  const goodsConfirmed = checks[1];
  if (!goodsConfirmed) throw new Error('找不到實物已到 checkbox');
  if (!goodsConfirmed.checked) await click(goodsConfirmed);
  await click(byText('button', '送出處理'));
}

async function trySubmitGoodQty(value) {
  const goodInput = document.querySelector('input[type="number"]');
  const submitButton = [...document.querySelectorAll('button')]
    .find((button) => textOf(button).includes('送出處理'));
  if (!goodInput || goodInput.disabled || !submitButton || submitButton.disabled) return false;
  await input(goodInput, value);
  const checks = [...document.querySelectorAll('input[type="checkbox"]')];
  const goodsConfirmed = checks[1];
  if (!goodsConfirmed || goodsConfirmed.disabled) return false;
  if (!goodsConfirmed.checked) await click(goodsConfirmed);
  await click(submitButton);
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

(async () => {
  global.IS_REACT_ACT_ENVIRONMENT = true;
  const dom = new JSDOM('<!doctype html><html><body></body></html>', { url: 'http://localhost/wms/return-disposition' });
  let root = null;
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

    const rpcCalls = [];
    const Page = loadPage(rpcCalls);
    root = await renderPage(Page);
    await click(byText('tr', '#101'));
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
    const enabledNumberInputsAfterUnknown = [...document.querySelectorAll('input[type="number"]')]
      .filter((el) => !el.disabled).length;

    observe(
      '未知錯誤後數量欄位啟用數',
      `${enabledNumberInputsAfterUnknown} enabled number input(s)`,
    );
    expect(
      '未知送出結果後不可提供可按的換 request id 按鈕',
      !(regenerateButton && !regenerateButton.disabled),
      regenerateButton ? `button enabled=${!regenerateButton.disabled} (L${lineOf('重新產生 Request ID')})` : 'button absent',
      'button absent or disabled until request is confirmed/rejected',
    );

    const beforeSecond = rpcCalls.length;
    if (regenerateButton && !regenerateButton.disabled) await click(regenerateButton);
    await trySubmitGoodQty('2');
    const second = rpcCalls[beforeSecond];
    const secondDidNotWrite = rpcCalls.length === beforeSecond;

    expect(
      '未知結果後若再次送出，payload 要維持原包',
      secondDidNotWrite || (second && payloadSnapshot(second) === payloadSnapshot(first)),
      secondDidNotWrite ? 'no second rpc' : `second ${payloadSnapshot(second)}; first ${payloadSnapshot(first)}`,
      'no new write, or same full payload as first unknown request',
    );
    expect(
      '未知結果後若再次送出，不得換新 request id',
      secondDidNotWrite || (second && second.p_request_id === first.p_request_id),
      secondDidNotWrite ? 'no second rpc' : `second request=${second.p_request_id}; first request=${first.p_request_id}`,
      'no new write, or same request id as first unknown request',
    );

    await act(async () => root.unmount());
    root = null;
    root = await renderPage(Page);
    await click(byText('tr', '#101'));
    const beforeReopened = rpcCalls.length;
    await trySubmitGoodQty('1');
    const reopened = rpcCalls[beforeReopened];
    const reopenedDidNotWrite = rpcCalls.length === beforeReopened;

    expect(
      '關頁重開後不得用新 request id 重送待確認包',
      reopenedDidNotWrite || (reopened && reopened.p_request_id === first.p_request_id),
      reopenedDidNotWrite ? 'no reopened rpc' : `reopened request=${reopened.p_request_id}; first request=${first.p_request_id}`,
      'no new write until confirmation, or same pending request id restored after remount/reload',
    );
    expect(
      '關頁重開後若允許重送，payload 要維持原包',
      reopenedDidNotWrite || (reopened && payloadSnapshot(reopened) === payloadSnapshot(first)),
      reopenedDidNotWrite ? 'no reopened rpc' : `reopened ${payloadSnapshot(reopened)}; first ${payloadSnapshot(first)}`,
      'no new write until confirmation, or same full payload restored after remount/reload',
    );

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
    console.log(`rpc calls: ${rpcCalls.map((p) => `${p.p_request_id}:${p.p_qty_good}`).join(', ') || '(none)'}`);
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
    if (root) await act(async () => root.unmount());
    dom.window.close();
  }
})().catch((err) => {
  console.error(err.stack || err);
  process.exit(1);
});
