#!/usr/bin/env node
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const repoRoot = path.resolve(__dirname, '../..');
const pageRel = 'apps/admin/src/app/(protected)/wms/return-disposition/page.tsx';
const pageFile = path.join(repoRoot, pageRel);
const source = fs.readFileSync(pageFile, 'utf8');
const sourceFile = ts.createSourceFile(pageRel, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);

function findFunction(name) {
  let found = null;
  function visit(node) {
    if (ts.isFunctionDeclaration(node) && node.name && node.name.text === name) {
      found = node;
      return;
    }
    ts.forEachChild(node, visit);
  }
  visit(sourceFile);
  if (!found) {
    throw new Error(`找不到 ${name}，測試不能跳過`);
  }
  const pos = sourceFile.getLineAndCharacterOfPosition(found.getStart(sourceFile));
  return {
    name,
    line: pos.line + 1,
    text: source.slice(found.getStart(sourceFile), found.end),
  };
}

function loadHelpers(runtimeGlobals = {}) {
  const helpers = [findFunction('newRequestId'), findFunction('clampDecimal')];
  const js = ts.transpileModule(
    helpers.map((h) => h.text).join('\n\n') + '\n\nmodule.exports = { newRequestId, clampDecimal };',
    {
      compilerOptions: {
        module: ts.ModuleKind.CommonJS,
        target: ts.ScriptTarget.ES2020,
      },
      fileName: pageRel,
    },
  ).outputText;

  const sandbox = {
    module: { exports: {} },
    exports: {},
    ...runtimeGlobals,
  };
  vm.createContext(sandbox);
  vm.runInContext(js, sandbox, { filename: 'return-disposition-page-helpers.js' });
  return { helpers: sandbox.module.exports, locations: helpers };
}

function inspect(value) {
  return JSON.stringify(value);
}

const failures = [];

function equal(name, actual, expected) {
  if (!Object.is(actual, expected)) {
    failures.push({ name, actual: inspect(actual), expected: inspect(expected) });
  }
}

function ok(name, pass, actual, expected) {
  if (!pass) {
    failures.push({ name, actual, expected });
  }
}

const { helpers, locations } = loadHelpers();

const clampCases = [
  {
    name: 'clampDecimal 編輯中小數點要保留',
    input: '1.',
    max: 10,
    expected: '1.',
  },
  {
    name: 'clampDecimal 非法格式不可吃前綴改數',
    input: '1e3',
    max: 10000,
    expected: '1e3',
  },
  {
    name: 'clampDecimal 超過上限不可靜默改成別的數',
    input: '1',
    max: 0.75,
    expected: '1',
  },
  {
    name: 'clampDecimal 超過三位小數不可靜默截斷',
    input: '0.0009',
    max: 10,
    expected: '0.0009',
  },
];

for (const c of clampCases) {
  equal(c.name, helpers.clampDecimal(c.input, c.max), c.expected);
}

let getRandomValuesCalls = 0;
let mathRandomCalls = 0;
const fallbackCrypto = {
  getRandomValues(view) {
    getRandomValuesCalls += 1;
    for (let i = 0; i < view.length; i += 1) view[i] = (i * 17 + 23) & 0xff;
    return view;
  },
};
const fakeMath = Object.create(Math);
fakeMath.random = () => {
  mathRandomCalls += 1;
  return 0.123456789;
};

const { helpers: fallbackHelpers } = loadHelpers({
  crypto: fallbackCrypto,
  Date: { now: () => 1700000000000 },
  Math: fakeMath,
});
const fallbackId = fallbackHelpers.newRequestId();
const uuidV4Re = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

ok(
  'newRequestId fallback 要產生 RFC4122 v4 UUID',
  uuidV4Re.test(fallbackId),
  inspect(fallbackId),
  'RFC4122 v4 UUID（xxxxxxxx-xxxx-4xxx-[89ab]xxx-xxxxxxxxxxxx）',
);
ok(
  'newRequestId fallback 要使用 crypto.getRandomValues',
  getRandomValuesCalls > 0,
  String(getRandomValuesCalls),
  '> 0',
);
equal('newRequestId fallback 不可使用 Math.random', mathRandomCalls, 0);

console.log(`extracted ${locations.map((h) => `${h.name}:L${h.line}`).join(', ')} from ${pageRel}`);

if (failures.length === 0) {
  console.log('ok - return-disposition UI input runtime checks');
} else {
  for (const f of failures) {
    console.error(`FAIL - ${f.name}`);
    console.error(`  actual:   ${f.actual}`);
    console.error(`  expected: ${f.expected}`);
  }
  console.error(`${failures.length} failed`);
  process.exitCode = 1;
}
