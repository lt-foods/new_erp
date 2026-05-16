// 帶 seed 的 RNG (mulberry32) — 可重跑
function mulberry32(seed) {
  let s = seed >>> 0;
  return function () {
    s |= 0; s = (s + 0x6D2B79F5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function hashSeed(str) {
  let h = 2166136261 >>> 0;
  for (let i = 0; i < str.length; i++) {
    h = Math.imul(h ^ str.charCodeAt(i), 16777619);
  }
  return h >>> 0;
}

function makeRng(seed = 'week-260514') {
  const r = mulberry32(typeof seed === 'number' ? seed : hashSeed(String(seed)));
  return {
    next: r,
    int: (min, max) => Math.floor(r() * (max - min + 1)) + min,
    pick: arr => arr[Math.floor(r() * arr.length)],
    pickN: (arr, n) => {
      const copy = arr.slice();
      for (let i = copy.length - 1; i > 0; i--) {
        const j = Math.floor(r() * (i + 1));
        [copy[i], copy[j]] = [copy[j], copy[i]];
      }
      return copy.slice(0, n);
    },
    chance: p => r() < p,
    weighted: weights => {
      // weights: [[value, p], ...], sum p == 1
      const x = r();
      let cum = 0;
      for (const [v, p] of weights) {
        cum += p;
        if (x < cum) return v;
      }
      return weights[weights.length - 1][0];
    },
  };
}

module.exports = { makeRng };
