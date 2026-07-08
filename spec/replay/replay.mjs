#!/usr/bin/env node
// Reference replayer + fixture validator for the Cleave client parity contract.
//
// This is the run-here self-consistency check (see spec/README.md). For each captured module it:
//   1. Validates every fixture file parses and has the expected envelope/shape.
//   2. Recomputes each case with an independent implementation and asserts it equals `expected`.
//
// It is NOT the oracle. The oracle is the iOS ParityConformanceTests run on the Mac, which replays
// these same fixtures against the shipping Swift Logic layer. This script catches authoring/rounding
// mistakes cheaply, before that handoff.
//
// Usage:  node spec/replay/replay.mjs        (from anywhere)

import { readFileSync, readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "..", "fixtures");

function loadModule(name) {
  const dir = join(FIXTURES, name);
  const files = readdirSync(dir).filter((f) => f.endsWith(".json")).sort();
  if (!files.length) throw new Error(`no fixtures under ${dir}`);
  const cases = [];
  for (const f of files) {
    const data = JSON.parse(readFileSync(join(dir, f), "utf8"));
    if (data.module !== name) throw new Error(`${f}: bad module tag ${data.module}`);
    for (const c of data.cases) cases.push({ ...c, file: f });
  }
  return { files, cases };
}
const eqArr = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const eqSet = (a, b) => eqArr([...a].sort(), [...b].sort());

// =====================================================================================
// split-math
// =====================================================================================
function scaled(s, scale) {
  s = String(s).trim();
  const neg = s.startsWith("-");
  if (neg) s = s.slice(1);
  let [intPart, fracPart = ""] = s.split(".");
  if (fracPart.length > scale) throw new Error(`"${s}" exceeds scale ${scale}`);
  fracPart = (fracPart + "0".repeat(scale)).slice(0, scale);
  const v = BigInt((intPart || "0") + fracPart);
  return neg ? -v : v;
}
const cents = (s) => scaled(s, 2);
const mils = (s) => scaled(s, 3);
const roundHalfUpDiv = (num, den) => (2n * num + den) / (2n * den); // positive inputs

function equalSplit(amountC, payer, participants) {
  const people = participants.length ? participants : [payer];
  const n = BigInt(people.length);
  const base = amountC / n;
  const remainder = amountC - base * n;
  return people.map((id, i) => ({ id, paid: id === payer ? amountC : 0n, owed: base + (BigInt(i) < remainder ? 1n : 0n) }));
}
function weightedSplit(amountC, payer, participants, weights) {
  const people = participants.length ? participants : [payer];
  const ws = people.map((p) => { const w = weights[p] !== undefined ? scaled(weights[p], 6) : 0n; return w > 0n ? w : 0n; });
  const totalW = ws.reduce((a, b) => a + b, 0n);
  if (totalW <= 0n) return equalSplit(amountC, payer, people);
  const owed = ws.map((w) => roundHalfUpDiv(amountC * w, totalW));
  let drift = amountC - owed.reduce((a, b) => a + b, 0n);
  let i = 0;
  while (drift !== 0n && owed.length) { owed[i % owed.length] += drift > 0n ? 1n : -1n; drift += drift > 0n ? -1n : 1n; i++; }
  return people.map((id, idx) => ({ id, paid: id === payer ? amountC : 0n, owed: owed[idx] }));
}
function adjustmentSplit(amountC, payer, participants, adjustments) {
  const people = participants.length ? participants : [payer];
  const adj = Object.fromEntries(Object.entries(adjustments).map(([k, v]) => [k, cents(v)]));
  const totalAdj = people.reduce((a, p) => a + (adj[p] || 0n), 0n);
  const base = Object.fromEntries(equalSplit(amountC - totalAdj, payer, people).map((s) => [s.id, s.owed]));
  return people.map((id) => ({ id, paid: id === payer ? amountC : 0n, owed: (base[id] || 0n) + (adj[id] || 0n) }));
}
function itemizedSplit(amountC, payer, participants, assigned) {
  const people = participants.length ? participants : [payer];
  const asg = Object.fromEntries(Object.entries(assigned).map(([k, v]) => [k, cents(v)]));
  const total = people.reduce((a, p) => a + (asg[p] || 0n), 0n);
  const rem = Object.fromEntries(equalSplit(amountC - total, payer, people).map((s) => [s.id, s.owed]));
  return people.map((id) => ({ id, paid: id === payer ? amountC : 0n, owed: (asg[id] || 0n) + (rem[id] || 0n) }));
}
function reimbursementSplit(amountC, payer, participants) {
  return equalSplit(amountC, payer, participants).map((s) => ({ id: s.id, paid: s.owed, owed: s.paid }));
}
function isBalanced(amountM, splitsM) {
  const tol = 10n, abs = (x) => (x < 0n ? -x : x);
  const paidSum = splitsM.reduce((a, s) => a + s.paid, 0n);
  const owedSum = splitsM.reduce((a, s) => a + s.owed, 0n);
  return abs(paidSum - amountM) <= tol && abs(owedSum - amountM) <= tol;
}
function collapseOlder(expenses) {
  const idx = expenses.findIndex((e) => e.category === "Settle-up");
  if (idx < 0) return { visible: expenses.map((e) => e.details), collapsed: 0 };
  const visible = expenses.slice(0, idx + 1);
  return { visible: visible.map((e) => e.details), collapsed: expenses.length - visible.length };
}
function checkSplits(produced, expected, name, errs) {
  if (produced.length !== expected.length) { errs.push(`${name}: split count ${produced.length} != ${expected.length}`); return; }
  produced.forEach((p, i) => {
    const e = expected[i];
    if (p.id !== e.userIdentifier || p.paid !== cents(e.paidShare) || p.owed !== cents(e.owedShare))
      errs.push(`${name}: {${p.id},${p.paid},${p.owed}} != {${e.userIdentifier},${cents(e.paidShare)},${cents(e.owedShare)}}`);
  });
}
function runSplitMath(errs) {
  const { files, cases } = loadModule("split-math");
  for (const c of cases) {
    const name = `${c.file}:${c.name}`, i = c.input, exp = c.expected;
    switch (c.fn) {
      case "equalSplit": checkSplits(equalSplit(cents(i.amount), i.payer, i.participants), exp.splits, name, errs); break;
      case "weightedSplit": checkSplits(weightedSplit(cents(i.amount), i.payer, i.participants, i.weights), exp.splits, name, errs); break;
      case "adjustmentSplit": checkSplits(adjustmentSplit(cents(i.amount), i.payer, i.participants, i.adjustments), exp.splits, name, errs); break;
      case "itemizedSplit": checkSplits(itemizedSplit(cents(i.amount), i.payer, i.participants, i.assigned), exp.splits, name, errs); break;
      case "reimbursementSplit": checkSplits(reimbursementSplit(cents(i.amount), i.payer, i.participants), exp.splits, name, errs); break;
      case "isBalanced": {
        const got = isBalanced(mils(i.amount), i.splits.map((s) => ({ paid: mils(s.paidShare), owed: mils(s.owedShare) })));
        if (got !== exp.balanced) errs.push(`${name}: balanced ${got} != ${exp.balanced}`); break;
      }
      case "collapseOlder": {
        const r = collapseOlder(i.expenses);
        if (!eqArr(r.visible, exp.visible) || r.collapsed !== exp.collapsed)
          errs.push(`${name}: (${JSON.stringify(r.visible)},${r.collapsed}) != (${JSON.stringify(exp.visible)},${exp.collapsed})`);
        break;
      }
      default: errs.push(`${name}: unknown fn ${c.fn}`);
    }
  }
  return { count: cases.length, files: files.length };
}

// =====================================================================================
// category
// =====================================================================================
const PRIMARY_MAP = {
  INCOME: "Income", TRANSFER_IN: "Transfer", TRANSFER_OUT: "Transfer", LOAN_PAYMENTS: "Transfer",
  BANK_FEES: "Fees", ENTERTAINMENT: "Entertainment", FOOD_AND_DRINK: "Dining",
  GENERAL_MERCHANDISE: "Shopping", HOME_IMPROVEMENT: "Household", MEDICAL: "Health",
  PERSONAL_CARE: "Personal Care", GENERAL_SERVICES: "Other", GOVERNMENT_AND_NON_PROFIT: "Other",
  TRANSPORTATION: "Transport", TRAVEL: "Travel", RENT_AND_UTILITIES: "Utilities",
};
const DETAILED_OVERRIDES = {
  FOOD_AND_DRINK_GROCERIES: "Groceries", FOOD_AND_DRINK_BEER_WINE_AND_LIQUOR: "Alcohol",
  TRANSPORTATION_GAS: "Fuel", RENT_AND_UTILITIES_RENT: "Rent", LOAN_PAYMENTS_MORTGAGE_PAYMENT: "Mortgage",
  GENERAL_SERVICES_INSURANCE: "Insurance", GENERAL_SERVICES_EDUCATION: "Education",
  GENERAL_MERCHANDISE_PET_SUPPLIES: "Pets", MEDICAL_VETERINARY_SERVICES: "Pets",
  GOVERNMENT_AND_NON_PROFIT_DONATIONS: "Gifts",
};
const SPLITWISE_MAP = {
  "Food and drink": "Dining", "Dining out": "Dining", Groceries: "Groceries", Liquor: "Alcohol",
  Entertainment: "Entertainment", Games: "Entertainment", Movies: "Entertainment", Music: "Entertainment", Sports: "Entertainment",
  Home: "Household", Rent: "Rent", Mortgage: "Mortgage", Furniture: "Household", "Household supplies": "Household",
  Maintenance: "Household", Services: "Services", Electronics: "Shopping", Pets: "Pets",
  Life: "Other", Clothing: "Shopping", "Medical expenses": "Health", Insurance: "Insurance", Education: "Education",
  Gifts: "Gifts", Taxes: "Fees", Childcare: "Household",
  Transportation: "Transport", Car: "Transport", Bicycle: "Transport", "Bus/train": "Transport",
  Parking: "Transport", Taxi: "Transport", "Gas/fuel": "Fuel", Plane: "Travel", Hotel: "Travel",
  Utilities: "Utilities", Electricity: "Utilities", "Heat/gas": "Utilities", Water: "Utilities",
  Trash: "Utilities", "TV/Phone/Internet": "Utilities", Cleaning: "Utilities",
  General: "Other", Other: "Other",
};
const CANONICAL_ALL = ["Groceries", "Dining", "Alcohol", "Transport", "Fuel", "Utilities", "Rent", "Mortgage",
  "Entertainment", "Travel", "Health", "Insurance", "Shopping", "Household", "Services", "Subscriptions",
  "Education", "Gifts", "Personal Care", "Pets", "Fees", "Income", "Transfer", "Settle-up", "Other"];
const EXCLUDED_FROM_SPEND = ["Transfer", "Income", "Settle-up", "Reimbursement"];
const NEUTRAL = ["Transfer", "Settle-up"];
const INCOME_LIKE = ["Income", "Reimbursement"];

function plaidCanonical(raw) {
  if (raw in DETAILED_OVERRIDES) return DETAILED_OVERRIDES[raw];
  for (const [primary, canon] of Object.entries(PRIMARY_MAP)) if (raw === primary || raw.startsWith(primary + "_")) return canon;
  return null;
}
const cap = (w) => (w.length ? w[0].toUpperCase() + w.slice(1) : w);
const humanized = (raw) => raw.split("_").map((w) => cap(w.toLowerCase())).join(" ");
function displayLabel(raw) {
  const isPlaid = raw.length > 0 && /^[A-Z0-9_]+$/.test(raw) && /[A-Z]/.test(raw);
  return isPlaid ? humanized(raw) : raw;
}
const splitwiseCanonical = (raw) => (raw in SPLITWISE_MAP ? SPLITWISE_MAP[raw] : null);
const mappedSource = (raw, sources) => (sources[raw] === "ondevice" ? "mappedByAI" : "mappedByYou");
const passthrough = (v) => (CANONICAL_ALL.includes(v) ? "explicit" : "raw");

function resolveExpense(raw, lookup, sources) {
  if (!raw) return { category: null, source: "raw" };
  if (raw in lookup) return { category: lookup[raw], source: mappedSource(raw, sources) };
  const p = plaidCanonical(raw); if (p != null) return { category: p, source: "deterministic" };
  const s = splitwiseCanonical(raw); if (s != null) return { category: s, source: "deterministic" };
  return { category: raw, source: passthrough(raw) };
}
function resolveTransaction(t, lookup, sources) {
  if (t.override && t.override.length) return { category: t.override, source: "override" };
  const refined = t.refined && t.refined.length ? t.refined : null;
  const raw = t.category && t.category.length ? t.category : null;
  if (!raw) return refined ? { category: refined, source: "aiRefined" } : { category: null, source: "raw" };
  if (raw in lookup) return { category: lookup[raw], source: mappedSource(raw, sources) };
  if (refined) return { category: refined, source: "aiRefined" };
  const b = plaidCanonical(raw); if (b != null) return { category: b, source: "deterministic" };
  return { category: raw, source: passthrough(raw) };
}
function needsRefinement(t, lookup) {
  if (t.override != null) return false;
  if (t.source !== "plaid") return false;
  const raw = t.category;
  if (!raw || !raw.length) return false;
  if (raw in lookup) return false;
  const b = plaidCanonical(raw);
  return b == null || b === "Other";
}
function runCategory(errs) {
  const { files, cases } = loadModule("category");
  for (const c of cases) {
    const name = `${c.file}:${c.name}`, i = c.input, exp = c.expected;
    const chkCat = (got) => { if ((got.category ?? null) !== (exp.category ?? null) || got.source !== exp.source) errs.push(`${name}: {${got.category},${got.source}} != {${exp.category},${exp.source}}`); };
    switch (c.fn) {
      case "plaidCanonical": { const g = plaidCanonical(i.raw); if ((g ?? null) !== (exp.category ?? null)) errs.push(`${name}: ${g} != ${exp.category}`); break; }
      case "splitwiseCanonical": { const g = splitwiseCanonical(i.raw); if ((g ?? null) !== (exp.category ?? null)) errs.push(`${name}: ${g} != ${exp.category}`); break; }
      case "plaidHumanized": { const g = humanized(i.raw); if (g !== exp.value) errs.push(`${name}: "${g}" != "${exp.value}"`); break; }
      case "plaidDisplayLabel": { const g = displayLabel(i.raw); if (g !== exp.value) errs.push(`${name}: "${g}" != "${exp.value}"`); break; }
      case "resolveExpense": chkCat(resolveExpense(i.raw, i.lookup || {}, i.sources || {})); break;
      case "resolveTransaction": chkCat(resolveTransaction(i.transaction, i.lookup || {}, i.sources || {})); break;
      case "needsRefinement": { const g = needsRefinement(i.transaction, i.lookup || {}); if (g !== exp.needsRefinement) errs.push(`${name}: ${g} != ${exp.needsRefinement}`); break; }
      case "canonicalSets":
        if (!eqArr(CANONICAL_ALL, exp.all)) errs.push(`${name}: taxonomy list drift`);
        if (!eqSet(EXCLUDED_FROM_SPEND, exp.excludedFromSpend)) errs.push(`${name}: excludedFromSpend drift`);
        if (!eqSet(NEUTRAL, exp.neutral)) errs.push(`${name}: neutral drift`);
        if (!eqSet(INCOME_LIKE, exp.incomeLike)) errs.push(`${name}: incomeLike drift`);
        break;
      default: errs.push(`${name}: unknown fn ${c.fn}`);
    }
  }
  return { count: cases.length, files: files.length };
}

// =====================================================================================
// itemized-spend  (exact rational math: attribution uses Decimal division)
// =====================================================================================
function norm(r) { return r.d < 0n ? { n: -r.n, d: -r.d } : r; }
function decToRat(s) {
  s = String(s).trim();
  const neg = s.startsWith("-"); if (neg) s = s.slice(1);
  let [i, f = ""] = s.split(".");
  return { n: BigInt((i || "0") + f) * (neg ? -1n : 1n), d: 10n ** BigInt(f.length) };
}
const RZERO = { n: 0n, d: 1n };
const rmul = (a, b) => norm({ n: a.n * b.n, d: a.d * b.d });
const radd = (a, b) => norm({ n: a.n * b.d + b.n * a.d, d: a.d * b.d });
const rsub = (a, b) => norm({ n: a.n * b.d - b.n * a.d, d: a.d * b.d });
const rdiv = (a, b) => norm({ n: a.n * b.d, d: a.d * b.n });
const rsign = (a) => (a.n < 0n ? -1 : a.n > 0n ? 1 : 0); // d>0 after norm
const rmax0 = (a) => (rsign(a) > 0 ? a : RZERO);
const rEqDec = (a, s) => { const e = decToRat(s); return a.n * e.d === e.n * a.d; };

function canonExpense(raw, lookup) {
  if (raw == null || raw === "") return null;
  return resolveExpense(raw, lookup, {}).category;
}
function itemizedDetailed(expense, me, lookup) {
  const owedSplit = (expense.splits || []).find((s) => s.userIdentifier === me);
  const owed = owedSplit ? decToRat(owedSplit.owedShare) : RZERO;
  const items = expense.items || [];
  const entries = [];
  const add = (rawCat, amount) => {
    if (rsign(amount) <= 0) return;
    const c = canonExpense(rawCat != null ? rawCat : expense.category, lookup);
    if (c == null) return;
    entries.push({ category: c, amount });
  };
  if (!items.length) {
    if (rsign(owed) > 0) { const c = canonExpense(expense.category, lookup); if (c != null) entries.push({ category: c, amount: owed }); }
    return entries;
  }
  const honorOwners = !expense.splitwise;
  const owner = (it) => (honorOwners ? it.owner ?? null : null);
  const mine = items.filter((it) => owner(it) === me);
  for (const it of mine) add(it.category, decToRat(it.price));
  const assignedToMe = mine.reduce((a, it) => radd(a, decToRat(it.price)), RZERO);
  const poolShare = rmax0(rsub(owed, assignedToMe));
  if (rsign(poolShare) > 0) {
    const shared = items.filter((it) => owner(it) === null);
    const itemsTotal = items.reduce((a, it) => radd(a, decToRat(it.price)), RZERO);
    const nonItemRemainder = rmax0(rsub(decToRat(expense.amount), itemsTotal));
    const poolTotal = radd(shared.reduce((a, it) => radd(a, decToRat(it.price)), RZERO), nonItemRemainder);
    if (rsign(poolTotal) > 0) {
      for (const it of shared) add(it.category, rdiv(rmul(poolShare, decToRat(it.price)), poolTotal));
      add(null, rdiv(rmul(poolShare, nonItemRemainder), poolTotal));
    } else add(null, poolShare);
  }
  return entries;
}
function itemizedContributions(expense, me, lookup) {
  const byCat = new Map();
  for (const e of itemizedDetailed(expense, me, lookup)) byCat.set(e.category, radd(byCat.get(e.category) || RZERO, e.amount));
  return byCat;
}
function transactionDetailed(t, lookup) {
  const items = t.items || [];
  if (!items.length) return [];
  const effective = resolveTransaction({ category: t.category, override: null, refined: null, source: t.source }, lookup, {}).category;
  const entries = [];
  let itemsTotal = RZERO;
  for (const it of items) {
    const price = decToRat(it.price);
    itemsTotal = radd(itemsTotal, price);
    if (rsign(price) === 0) continue;
    entries.push({ category: it.category != null ? canonExpense(it.category, lookup) : effective, amount: price });
  }
  const remainder = rsub(decToRat(t.amount), itemsTotal);
  if (rsign(remainder) !== 0 || remainder.n !== 0n) { if (remainder.n !== 0n) entries.push({ category: effective, amount: remainder }); }
  return entries;
}
function checkByCategory(byCatMap, expected, name, errs) {
  const keys = new Set([...byCatMap.keys(), ...Object.keys(expected)]);
  for (const k of keys) {
    const got = byCatMap.get(k);
    if (got === undefined) { errs.push(`${name}: missing category ${k}`); continue; }
    if (!(k in expected)) { errs.push(`${name}: unexpected category ${k}`); continue; }
    if (!rEqDec(got, expected[k])) errs.push(`${name}: ${k} != ${expected[k]}`);
  }
}
function runItemized(errs) {
  const { files, cases } = loadModule("itemized-spend");
  for (const c of cases) {
    const name = `${c.file}:${c.name}`, i = c.input, exp = c.expected;
    if (c.fn === "itemizedContributions") {
      checkByCategory(itemizedContributions(i.expense, i.me, i.lookup || {}), exp.byCategory, name, errs);
    } else if (c.fn === "transactionItemized") {
      const d = transactionDetailed(i.transaction, i.lookup || {});
      const byCat = new Map();
      for (const e of d) if (e.category != null) byCat.set(e.category, radd(byCat.get(e.category) || RZERO, e.amount));
      checkByCategory(byCat, exp.byCategory, name, errs);
      if (exp.total !== undefined) {
        const total = d.reduce((a, e) => radd(a, e.amount), RZERO);
        if (!rEqDec(total, exp.total)) errs.push(`${name}: total != ${exp.total}`);
      }
    } else errs.push(`${name}: unknown fn ${c.fn}`);
  }
  return { count: cases.length, files: files.length };
}

// =====================================================================================
// account-classification
// =====================================================================================
const LIABILITY_SUBTYPES = new Set([
  "credit card", "credit", "loan", "auto", "business", "commercial", "construction", "consumer",
  "home equity", "line of credit", "mortgage", "overdraft", "student"]);
const HOLDINGS_SUBTYPES = new Set([
  "investment", "brokerage", "cd", "hsa", "ira", "roth", "roth ira", "sep ira", "simple ira",
  "401k", "401a", "403b", "457b", "529", "roth 401k", "mutual fund", "stock plan", "pension",
  "retirement", "keogh", "thrift savings plan", "tfsa", "rrsp", "rrif", "lira", "resp", "trust"]);
const KIND_CANON = { cashFlow: "cash_flow", liability: "liability", holdings: "savings" };

function classifyKind(type) {
  const k = (type ?? "").toLowerCase();
  if (LIABILITY_SUBTYPES.has(k)) return "liability";
  if (HOLDINGS_SUBTYPES.has(k)) return "holdings";
  return "cashFlow";
}
function kindFromCanonical(c) {
  if (c === "cash_flow") return "cashFlow";
  if (c === "liability") return "liability";
  if (c === "savings" || c === "holdings") return "holdings";
  return null;
}
function accountKind(a) {
  if (a.kindOverride != null) { const k = kindFromCanonical(a.kindOverride); if (k) return k; }
  return classifyKind(a.type ?? null);
}
const blank = (s) => s == null || s.trim().length === 0;
function accountFlags(a) {
  const kind = accountKind(a);
  const isPlaid = a.plaidAccountId != null;
  const isImported = !isPlaid && (a.institutionName != null && a.institutionName.length > 0);
  return {
    kind: KIND_CANON[kind],
    countsInSpending: a.includeInSpending ?? (kind === "cashFlow" || kind === "liability"),
    countsInCashFlow: a.includeInCashFlow ?? (kind === "cashFlow"),
    isPlaid,
    isImported,
    isManual: !isPlaid && !isImported,
    displayLabel: !blank(a.displayName) ? a.displayName : a.name,
    maskLabel: !blank(a.mask) ? "•••• " + a.mask : null,
  };
}
function runAccountClassification(errs) {
  const { files, cases } = loadModule("account-classification");
  for (const c of cases) {
    const name = `${c.file}:${c.name}`, i = c.input, exp = c.expected;
    switch (c.fn) {
      case "classify": { const g = KIND_CANON[classifyKind(i.type ?? null)]; if (g !== exp.kind) errs.push(`${name}: ${g} != ${exp.kind}`); break; }
      case "kindFromCanonical": { const k = kindFromCanonical(i.canonical); const g = k ? KIND_CANON[k] : null; if (g !== (exp.kind ?? null)) errs.push(`${name}: ${g} != ${exp.kind}`); break; }
      case "accountFlags": {
        const g = accountFlags(i.account);
        for (const key of ["kind", "countsInSpending", "countsInCashFlow", "isPlaid", "isImported", "isManual", "displayLabel"])
          if (g[key] !== exp[key]) errs.push(`${name}: ${key} ${g[key]} != ${exp[key]}`);
        if ((g.maskLabel ?? null) !== (exp.maskLabel ?? null)) errs.push(`${name}: maskLabel ${g.maskLabel} != ${exp.maskLabel}`);
        break;
      }
      default: errs.push(`${name}: unknown fn ${c.fn}`);
    }
  }
  return { count: cases.length, files: files.length };
}

// =====================================================================================
// spend-engine  (reuses category + itemized + account-classification impls above)
// =====================================================================================
const rneg = (a) => ({ n: -a.n, d: a.d });
function accountCountsInSpending(a) { return accountFlags(a).countsInSpending; }
function accountCountsInCashFlow(a) { return accountFlags(a).countsInCashFlow; }

function spendEventsReplay(inp) {
  const transactions = inp.transactions || [], accounts = inp.accounts || [];
  const expenses = inp.expenses || [], groups = inp.groups || [];
  const me = inp.me ?? null, lookup = inp.lookup || {};
  const byId = new Map(accounts.map((a) => [a.id, a]));
  const groupById = new Map(groups.map((g) => [g.id, g]));
  const linkedTxnIds = new Set(expenses.map((e) => e.transactionId).filter((x) => x != null));
  const events = [];
  for (const t of transactions) {
    if (!["plaid", "manual", "simplefin"].includes(t.source)) continue;
    if (linkedTxnIds.has(t.id)) continue;
    const account = t.accountId != null ? byId.get(t.accountId) : undefined;
    if ((t.source === "plaid" || t.source === "simplefin") && account == null) continue;
    const inSpending = t.includeInSpending ?? (account ? accountCountsInSpending(account) : true);
    const inCashFlow = t.includeInCashFlow ?? (account ? accountCountsInCashFlow(account) : true);
    const amt = decToRat(t.amount);
    if (rsign(amt) > 0 && (t.items || []).length) {
      for (const d of transactionDetailed(t, lookup)) events.push({ category: d.category, amount: d.amount, countsInSpending: inSpending, countsInCashFlow: inCashFlow, date: t.date });
      continue;
    }
    const category = resolveTransaction({ category: t.category, override: null, refined: null, source: t.source }, lookup, {}).category;
    events.push({ category, amount: amt, countsInSpending: inSpending, countsInCashFlow: inCashFlow, date: t.date });
  }
  if (me != null) {
    for (const e of expenses) {
      const cat = e.category != null ? resolveExpense(e.category, lookup, {}).category : null;
      if (cat == null || NEUTRAL.includes(cat)) continue;
      const group = groupById.get(e.groupId);
      const incSpend = e.includeInSpending ?? (group ? group.includeInSpending ?? true : true);
      const incCash = e.includeInCashFlow ?? (group ? group.includeInCashFlow ?? true : true);
      const mySplit = (e.splits || []).find((s) => s.userIdentifier === me);
      let amount;
      if (INCOME_LIKE.includes(cat)) {
        const inflow = cat === "Reimbursement" ? decToRat(mySplit?.paidShare ?? "0") : decToRat(mySplit?.owedShare ?? "0");
        if (rsign(inflow) <= 0) continue;
        amount = rneg(inflow);
      } else if ((e.items || []).length) {
        for (const c of itemizedDetailed(e, me, lookup)) events.push({ category: c.category, amount: c.amount, countsInSpending: incSpend, countsInCashFlow: incCash, date: e.date });
        continue;
      } else {
        const share = decToRat(mySplit?.owedShare ?? "0");
        if (rsign(share) <= 0) continue;
        amount = share;
      }
      events.push({ category: cat, amount, countsInSpending: incSpend, countsInCashFlow: incCash, date: e.date });
    }
  }
  return events;
}
function isSpendEvent(ev) {
  return ev.countsInSpending && rsign(ev.amount) > 0 && ev.category != null && !EXCLUDED_FROM_SPEND.includes(ev.category);
}
const ymKey = (dateStr) => { const d = new Date(dateStr); return `${d.getUTCFullYear()}-${d.getUTCMonth()}`; };
function runSpendEngine(errs) {
  const { files, cases } = loadModule("spend-engine");
  for (const c of cases) {
    const name = `${c.file}:${c.name}`, i = c.input, exp = c.expected;
    switch (c.fn) {
      case "spendEvents": {
        const ev = spendEventsReplay(i);
        if (ev.length !== exp.events.length) { errs.push(`${name}: event count ${ev.length} != ${exp.events.length}`); break; }
        ev.forEach((g, idx) => {
          const e = exp.events[idx];
          if ((g.category ?? null) !== (e.category ?? null) || !rEqDec(g.amount, e.amount) || g.countsInSpending !== e.countsInSpending || g.countsInCashFlow !== e.countsInCashFlow)
            errs.push(`${name}[${idx}]: {${g.category},${g.amount.n}/${g.amount.d},${g.countsInSpending},${g.countsInCashFlow}} != {${e.category},${e.amount},${e.countsInSpending},${e.countsInCashFlow}}`);
        });
        break;
      }
      case "isSpend": {
        const ev = { category: i.event.category ?? null, amount: decToRat(i.event.amount), countsInSpending: i.event.countsInSpending, countsInCashFlow: i.event.countsInCashFlow };
        if (isSpendEvent(ev) !== exp.isSpend) errs.push(`${name}: ${isSpendEvent(ev)} != ${exp.isSpend}`);
        break;
      }
      case "byCategory": {
        const target = ymKey(i.month);
        const byCat = new Map();
        for (const ev of spendEventsReplay(i)) if (isSpendEvent(ev) && ymKey(ev.date) === target) byCat.set(ev.category, radd(byCat.get(ev.category) || RZERO, ev.amount));
        checkByCategory(byCat, exp.byCategory, name, errs);
        break;
      }
      default: errs.push(`${name}: unknown fn ${c.fn}`);
    }
  }
  return { count: cases.length, files: files.length };
}

// =====================================================================================
// subscriptions  (+ MerchantText.key, the shared grouping helper)
// =====================================================================================
const MERCHANT_NOISE = new Set([
  "com", "www", "http", "https", "inc", "llc", "ltd", "co", "corp", "pos", "purchase", "recurring",
  "payment", "autopay", "auto", "bill", "online", "usa", "the", "subscription", "monthly", "annual"]);
function merchantWords(details) {
  return [...details.toLowerCase()].map((ch) => (/[a-z]/.test(ch) || ch === " " ? ch : " ")).join("")
    .split(/\s+/).filter((w) => w.length >= 3 && !MERCHANT_NOISE.has(w));
}
const merchantKey = (details) => merchantWords(details).slice(0, 3).join(" ");

const CADENCE = {
  weekly: { ppy: "52", days: 7, unit: "wk", label: "Weekly" },
  biweekly: { ppy: "26", days: 14, unit: "2wk", label: "Every 2 weeks" },
  monthly: { ppy: "12", days: 30, unit: "mo", label: "Monthly" },
  quarterly: { ppy: "4", days: 91, unit: "qtr", label: "Quarterly" },
  yearly: { ppy: "1", days: 365, unit: "yr", label: "Yearly" },
};
function cadenceClassify(d) {
  if (d >= 5 && d <= 9) return "weekly";
  if (d >= 11 && d <= 17) return "biweekly";
  if (d >= 24 && d <= 37) return "monthly";
  if (d >= 80 && d <= 100) return "quarterly";
  if (d >= 330 && d <= 400) return "yearly";
  return null;
}
const rcmp = (a, b) => rsign(rsub(a, b));
function ratMedian(rats) {
  const s = [...rats].sort(rcmp);
  if (!s.length) return RZERO;
  const mid = Math.floor(s.length / 2);
  return s.length % 2 === 0 ? rdiv(radd(s[mid - 1], s[mid]), { n: 2n, d: 1n }) : s[mid];
}
function numMedian(vals) {
  const s = [...vals].sort((a, b) => a - b);
  if (!s.length) return 0;
  const mid = Math.floor(s.length / 2);
  return s.length % 2 === 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid];
}
const dayInterval = (a, b) => Math.round((new Date(b).getTime() - new Date(a).getTime()) / 86400000);
function subMatches(amount, ruleAmount) {
  const a = Number(amount), b = Number(ruleAmount);
  if (!(a > 0) || !(b > 0)) return false;
  return Math.max(a, b) / Math.min(a, b) <= 2.0;
}
function classifyGroup(events) {
  const evs = [...events].sort((x, y) => new Date(x.date) - new Date(y.date));
  if (evs.length < 2) return { kind: "none" };
  const ivals = [];
  for (let i = 1; i < evs.length; i++) { const d = dayInterval(evs[i - 1].date, evs[i].date); if (d > 0) ivals.push(d); }
  if (!ivals.length) return { kind: "none" };
  const cadence = cadenceClassify(numMedian(ivals));
  if (!cadence) return { kind: "none" };
  const band = CADENCE[cadence].days;
  const regularity = ivals.filter((iv) => Math.abs(iv - band) <= band * 0.4).length / ivals.length;
  const medAmount = ratMedian(evs.map((e) => e.amount));
  const amountClusters = rsign(medAmount) > 0 && evs.every((e) => {
    const r = rdiv(e.amount, medAmount);
    return rcmp(r, decToRat("0.5")) >= 0 && rcmp(r, decToRat("1.8")) <= 0;
  });
  const enough = evs.length >= (cadence === "yearly" ? 2 : 3);
  if (enough && regularity >= 0.6 && amountClusters) {
    const latest = evs[evs.length - 1], prior = evs[evs.length - 2].amount;
    return {
      kind: "subscription", cadence, latestAmount: latest.amount, priorAmount: prior,
      annualCost: rmul(latest.amount, { n: BigInt(CADENCE[cadence].ppy), d: 1n }),
      isShared: evs.some((e) => e.shared), increased: rcmp(latest.amount, prior) > 0,
    };
  }
  if (evs.length >= 3 && regularity >= 0.5) {
    return { kind: "candidate", cadence, amount: medAmount, occurrences: evs.length, isShared: evs.some((e) => e.shared) };
  }
  return { kind: "none" };
}
function detectReplay(inp) {
  const transactions = inp.transactions || [], expenses = inp.expenses || [];
  const me = inp.me ?? null, lookup = inp.lookup || {};
  const linked = new Set(expenses.map((e) => e.transactionId).filter((x) => x != null));
  const byKey = new Map();
  const push = (key, ev) => { if (!byKey.has(key)) byKey.set(key, []); byKey.get(key).push(ev); };
  for (const t of transactions) {
    if (!["plaid", "manual", "simplefin"].includes(t.source)) continue;
    if (!(rsign(decToRat(t.amount)) > 0) || (t.id != null && linked.has(t.id))) continue;
    const cat = resolveTransaction({ category: t.category, override: null, refined: null, source: t.source }, lookup, {}).category;
    if (cat != null && EXCLUDED_FROM_SPEND.includes(cat)) continue;
    const key = merchantKey(t.details);
    if (!key) continue;
    push(key, { date: t.date, amount: decToRat(t.amount), shared: false });
  }
  if (me != null) {
    for (const e of expenses) {
      const cat = e.category != null ? resolveExpense(e.category, lookup, {}).category : null;
      if (cat == null || NEUTRAL.includes(cat) || INCOME_LIKE.includes(cat)) continue;
      const share = decToRat((e.splits || []).find((s) => s.userIdentifier === me)?.owedShare ?? "0");
      if (rsign(share) <= 0) continue;
      const key = merchantKey(e.details);
      if (!key) continue;
      push(key, { date: e.date, amount: share, shared: true });
    }
  }
  const subs = [], cands = [];
  for (const [key, events] of byKey) {
    const r = classifyGroup(events);
    if (r.kind === "subscription") subs.push({ id: key, ...r });
    else if (r.kind === "candidate") cands.push({ id: key, ...r });
  }
  subs.sort((a, b) => rcmp(b.annualCost, a.annualCost));
  cands.sort((a, b) => rcmp(b.amount, a.amount));
  return { subscriptions: subs, candidates: cands };
}
function runSubscriptions(errs) {
  const { files, cases } = loadModule("subscriptions");
  for (const c of cases) {
    const name = `${c.file}:${c.name}`, i = c.input, exp = c.expected;
    switch (c.fn) {
      case "cadenceClassify": { const g = cadenceClassify(i.medianDays); if (g !== (exp.cadence ?? null)) errs.push(`${name}: ${g} != ${exp.cadence}`); break; }
      case "cadenceProps": {
        const p = CADENCE[i.cadence];
        if (p.ppy !== exp.periodsPerYear || p.days !== exp.days || p.unit !== exp.unit || p.label !== exp.label) errs.push(`${name}: props drift`);
        break;
      }
      case "ruleMatches": { const g = subMatches(i.amount, i.ruleAmount); if (g !== exp.matches) errs.push(`${name}: ${g} != ${exp.matches}`); break; }
      case "subscriptionProps": {
        const ppy = { n: BigInt(CADENCE[i.cadence].ppy), d: 1n };
        const annual = rmul(decToRat(i.latestAmount), ppy);
        if (!rEqDec(annual, exp.annualCost)) errs.push(`${name}: annualCost != ${exp.annualCost}`);
        if (exp.monthlyEquivalent !== undefined && !rEqDec(rdiv(annual, { n: 12n, d: 1n }), exp.monthlyEquivalent)) errs.push(`${name}: monthlyEquivalent != ${exp.monthlyEquivalent}`);
        const increased = i.priorAmount != null && rcmp(decToRat(i.latestAmount), decToRat(i.priorAmount)) > 0;
        if (increased !== exp.increased) errs.push(`${name}: increased ${increased} != ${exp.increased}`);
        break;
      }
      case "detect": {
        const r = detectReplay(i);
        if (r.subscriptions.length !== exp.subscriptions.length) { errs.push(`${name}: sub count ${r.subscriptions.length} != ${exp.subscriptions.length}`); break; }
        r.subscriptions.forEach((s, idx) => {
          const e = exp.subscriptions[idx];
          if (s.id !== e.id || s.cadence !== e.cadence || !rEqDec(s.latestAmount, e.latestAmount) || !rEqDec(s.priorAmount, e.priorAmount) || !rEqDec(s.annualCost, e.annualCost) || s.isShared !== e.isShared || s.increased !== e.increased)
            errs.push(`${name}: sub[${idx}] ${s.id} mismatch`);
        });
        if (r.candidates.length !== exp.candidates.length) { errs.push(`${name}: cand count ${r.candidates.length} != ${exp.candidates.length}`); break; }
        r.candidates.forEach((cd, idx) => {
          const e = exp.candidates[idx];
          if (cd.id !== e.id || cd.cadence !== e.cadence || !rEqDec(cd.amount, e.amount) || cd.occurrences !== e.occurrences || cd.isShared !== e.isShared)
            errs.push(`${name}: cand[${idx}] ${cd.id} mismatch`);
        });
        break;
      }
      default: errs.push(`${name}: unknown fn ${c.fn}`);
    }
  }
  return { count: cases.length, files: files.length };
}

// =====================================================================================
// matching  (Double/exp scoring: assert order + inclusion, not raw scores)
// =====================================================================================
const MATCH_STOP = new Set([
  "the", "and", "for", "payment", "pmt", "ach", "autopay", "auto", "bill", "online",
  "llc", "inc", "co", "corp", "ltd", "card", "purchase", "pos", "debit", "credit"]);
function matchTokens(text) {
  return new Set(text.toLowerCase().split(/[^a-z0-9]+/).filter((w) => w.length >= 2 && !MATCH_STOP.has(w)));
}
function confidenceLabel(score) {
  if (score >= 0.8) return "Strong match";
  if (score >= 0.5) return "Likely match";
  return "Possible match";
}
const relDiff = (a, b) => (b > 0 ? Math.abs(a - b) / b : Infinity);
function overlap(a, b) {
  if (!a.size || !b.size) return 0;
  let inter = 0;
  for (const x of a) if (b.has(x)) inter++;
  return inter / Math.min(a.size, b.size);
}
const daysBetween = (a, b) => Math.abs(Math.round((new Date(a).getTime() - new Date(b).getTime()) / 86400000));
function matchScore(amount, full, myPaid, days, txnTokens, expTokens, recurring) {
  const kAmount = recurring ? 12.0 : 60.0, kDate = recurring ? 0.05 : 0.12;
  const relAmount = Math.min(relDiff(amount, full), myPaid != null ? relDiff(amount, myPaid) : Infinity);
  const amountScore = Math.exp(-kAmount * relAmount);
  if (amountScore < 0.6) return null;
  const dateScore = Math.exp(-kDate * days);
  let score = 0.55 * amountScore + 0.35 * dateScore + 0.1 * overlap(txnTokens, expTokens);
  if (recurring) score = Math.min(1, score + 0.05);
  return score;
}
function transactionCandidates(inp) {
  const { expense, me = null, limit = 8, windowDays = 21 } = inp;
  const transactions = inp.transactions || [], expensesList = inp.expenses || [];
  const linked = new Set();
  for (const e of expensesList) if (e.id !== expense.id && e.transactionId != null) linked.add(e.transactionId);
  const full = Number(expense.amount);
  const mySplit = me != null ? (expense.splits || []).find((s) => s.userIdentifier === me) : null;
  const myPaid = mySplit ? Number(mySplit.paidShare) : null;
  const expTokens = matchTokens(expense.details);
  const recurring = expense.repeats === true;
  const matches = [];
  for (const t of transactions) {
    if (t.id != null && linked.has(t.id)) continue;
    const days = daysBetween(t.date, expense.date);
    if (days > windowDays) continue;
    const score = matchScore(Number(t.amount), full, myPaid, days, matchTokens(t.details), expTokens, recurring);
    if (score == null) continue;
    matches.push({ details: t.details, score });
  }
  matches.sort((a, b) => b.score - a.score);
  return matches.slice(0, limit).map((m) => m.details);
}
function runMatching(errs) {
  const { files, cases } = loadModule("matching");
  for (const c of cases) {
    const name = `${c.file}:${c.name}`, i = c.input, exp = c.expected;
    switch (c.fn) {
      case "confidenceLabel": { const g = confidenceLabel(i.score); if (g !== exp.label) errs.push(`${name}: "${g}" != "${exp.label}"`); break; }
      case "matchTokens": { const g = matchTokens(i.text); if (!eqSet(g, new Set(exp.tokens))) errs.push(`${name}: {${[...g]}} != {${exp.tokens}}`); break; }
      case "transactionCandidates": { const g = transactionCandidates(i); if (!eqArr(g, exp.order)) errs.push(`${name}: [${g}] != [${exp.order}]`); break; }
      default: errs.push(`${name}: unknown fn ${c.fn}`);
    }
  }
  return { count: cases.length, files: files.length };
}

// =====================================================================================
// merchant-brand  (MerchantText tokens, BrandMatcher, MerchantParse, RelatedTransactions)
// =====================================================================================
const merchantTokens = (text) => new Set(merchantWords(text));
const COMMON_TLDS = new Set(["com", "net", "org", "io", "co", "app", "ai", "tv", "us", "uk", "ca", "de",
  "fr", "eu", "gov", "edu", "me", "info", "biz", "shop", "store", "online", "site", "xyz"]);
const STATES = new Set(["al", "ak", "az", "ar", "ca", "co", "ct", "de", "fl", "ga", "hi", "id", "il", "in",
  "ia", "ks", "ky", "la", "me", "md", "ma", "mi", "mn", "ms", "mo", "mt", "ne", "nv", "nh", "nj", "nm",
  "ny", "nc", "nd", "oh", "ok", "or", "pa", "ri", "sc", "sd", "tn", "tx", "ut", "vt", "va", "wa", "wv", "wi", "wy"]);

function merchantCleaned(merchant) {
  let s = merchant.trim();
  const star = s.indexOf("*");
  if (star >= 0 && star <= 8 && /^[a-z0-9\s]*$/i.test(s.slice(0, star))) s = s.slice(star + 1).trim();
  const letters = (t) => (t.match(/[a-z]/gi) || []).length;
  const digits = (t) => (t.match(/[0-9]/g) || []).length;
  const interiorNoise = (t) => digits(t) >= 3 || (letters(t) === 0 && digits(t) === 0);
  const trailingNoise = (t) => letters(t) === 0 || t.toLowerCase() === "usa" || t.toLowerCase() === "us" || (t.length === 2 && STATES.has(t.toLowerCase()));
  let words = s.split(/ +/).filter(Boolean).filter((w) => !interiorNoise(w));
  while (words.length && trailingNoise(words[words.length - 1])) words.pop();
  const cleaned = words.join(" ");
  return cleaned === "" ? merchant.trim() : cleaned;
}
function embeddedDomain(text) {
  const lower = text.toLowerCase();
  const re = /([a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+([a-z]{2,})/gi;
  let m;
  while ((m = re.exec(lower)) !== null) {
    if (!COMMON_TLDS.has(m[2])) continue;
    let domain = m[0];
    if (domain.startsWith("www.")) domain = domain.slice(4);
    return domain;
  }
  return null;
}
function globToRegex(glob) {
  let out = "";
  for (const ch of glob) out += ch === "*" ? ".*" : ch === "?" ? "." : ch.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return out;
}
function brandCompile(raw) {
  const p = raw.trim();
  const body = p.length >= 2 && p.startsWith("/") && p.endsWith("/") ? p.slice(1, -1) : null;
  if (body !== null) { try { const re = new RegExp(body, "i"); return (h) => re.test(h); } catch { return () => false; } }
  const lower = p.toLowerCase();
  if (lower.includes("*") || lower.includes("?")) { try { const re = new RegExp(globToRegex(lower), "i"); return (h) => re.test(h); } catch { return () => false; } }
  return (h) => h.includes(lower);
}
function amountsCloseRat(a, b) {
  const ra = decToRat(a), rb = decToRat(b);
  const hi = rcmp(ra, rb) >= 0 ? ra : rb, lo = rcmp(ra, rb) >= 0 ? rb : ra;
  if (rcmp(rsub(hi, lo), { n: 1n, d: 1n }) <= 0) return true;
  return rcmp(rmul(hi, { n: 4n, d: 1n }), rmul(lo, { n: 5n, d: 1n })) <= 0;
}
function relatedGroup(inp) {
  const seedTokens = merchantTokens(inp.seedDescription);
  if (seedTokens.size === 0) return [];
  const seedKey = merchantKey(inp.seedDescription);
  const subset = (A, B) => { for (const x of A) if (!B.has(x)) return false; return true; };
  const matchesMerchant = (details) => {
    if (inp.strictness === "exact") return seedKey !== "" && merchantKey(details) === seedKey;
    const c = merchantTokens(details);
    if (inp.strictness === "fuzzy") { for (const x of c) if (seedTokens.has(x)) return true; return false; }
    if (inp.strictness === "balanced") {
      if (!c.size) return false;
      let inter = 0; for (const x of c) if (seedTokens.has(x)) inter++;
      return inter / Math.min(c.size, seedTokens.size) > 0.5;
    }
    if (inp.strictness === "strict") { if (!c.size) return false; return subset(seedTokens, c) || subset(c, seedTokens); }
    return false;
  };
  const matchesAmount = (a) => {
    if (inp.amount === "any" || inp.seedAmount == null) return true;
    if (inp.amount === "equal") return rcmp(decToRat(a), decToRat(inp.seedAmount)) === 0;
    return amountsCloseRat(a, inp.seedAmount);
  };
  return inp.items.filter((it) => matchesMerchant(it.details) && matchesAmount(it.amount))
    .sort((x, y) => new Date(y.date) - new Date(x.date)).map((it) => it.label);
}
function commonTokensReplay(items) {
  if (!items.length) return [];
  let common = merchantTokens(items[0].details);
  for (const it of items.slice(1)) { const t = merchantTokens(it.details); common = new Set([...common].filter((x) => t.has(x))); }
  return [...common].sort();
}
function displayNameReplay(seed) {
  const words = merchantCleaned(seed).split(/ +/).filter(Boolean).slice(0, 3);
  if (!words.length) return seed;
  return words.map((w) => w.slice(0, 1).toUpperCase() + w.slice(1).toLowerCase()).join(" ");
}
function runMerchantBrand(errs) {
  const { files, cases } = loadModule("merchant-brand");
  for (const c of cases) {
    const name = `${c.file}:${c.name}`, i = c.input, exp = c.expected;
    switch (c.fn) {
      case "merchantKey": { const g = merchantKey(i.text); if (g !== exp.key) errs.push(`${name}: "${g}" != "${exp.key}"`); break; }
      case "merchantWords": { const g = merchantWords(i.text); if (!eqArr(g, exp.words)) errs.push(`${name}: [${g}] != [${exp.words}]`); break; }
      case "merchantTokens": { const g = merchantTokens(i.text); if (!eqSet(g, new Set(exp.tokens))) errs.push(`${name}: {${[...g]}} != {${exp.tokens}}`); break; }
      case "merchantCleaned": { const g = merchantCleaned(i.merchant); if (g !== exp.cleaned) errs.push(`${name}: "${g}" != "${exp.cleaned}"`); break; }
      case "embeddedDomain": { const g = embeddedDomain(i.text); if ((g ?? null) !== (exp.domain ?? null)) errs.push(`${name}: ${g} != ${exp.domain}`); break; }
      case "brandMatch": { const g = brandCompile(i.pattern)(i.text); if (g !== exp.matches) errs.push(`${name}: ${g} != ${exp.matches}`); break; }
      case "amountsClose": { const g = amountsCloseRat(i.a, i.b); if (g !== exp.close) errs.push(`${name}: ${g} != ${exp.close}`); break; }
      case "relatedGroup": { const g = relatedGroup(i); if (!eqArr(g, exp.order)) errs.push(`${name}: [${g}] != [${exp.order}]`); break; }
      case "commonTokens": { const g = commonTokensReplay(i.items); if (!eqArr(g, exp.tokens)) errs.push(`${name}: [${g}] != [${exp.tokens}]`); break; }
      case "displayName": { const g = displayNameReplay(i.seedDescription); if (g !== exp.displayName) errs.push(`${name}: "${g}" != "${exp.displayName}"`); break; }
      default: errs.push(`${name}: unknown fn ${c.fn}`);
    }
  }
  return { count: cases.length, files: files.length };
}

// =====================================================================================
// household-budget  (reuses itemizedContributions)
// =====================================================================================
function sharedGroupsReplay(inp) {
  const byGroup = new Map();
  for (const m of inp.members) { if (!byGroup.has(m.groupId)) byGroup.set(m.groupId, new Set()); byGroup.get(m.groupId).add(m.userIdentifier); }
  const partners = inp.partners;
  const ids = [];
  for (const [gid, members] of byGroup) if (members.has(inp.viewer) && partners.some((p) => members.has(p))) ids.push(gid);
  return ids;
}
function combinedByCategoryReplay(inp) {
  const target = ymKey(inp.month);
  const shared = new Set(inp.sharedGroupIds);
  const out = new Map(); // cat -> {mine, partnerTotal}
  const bump = (cat, who, amt) => {
    if (!out.has(cat)) out.set(cat, { mine: RZERO, partnerTotal: RZERO });
    const s = out.get(cat);
    if (who === "mine") s.mine = radd(s.mine, amt); else s.partnerTotal = radd(s.partnerTotal, amt);
  };
  for (const e of inp.expenses) {
    if (!shared.has(e.groupId) || ymKey(e.date) !== target) continue;
    for (const [cat, amt] of itemizedContributions(e, inp.viewer, {})) bump(cat, "mine", amt);
    for (const p of inp.partners) for (const [cat, amt] of itemizedContributions(e, p, {})) bump(cat, "partner", amt);
  }
  return out;
}
function runHousehold(errs) {
  const { files, cases } = loadModule("household-budget");
  for (const c of cases) {
    const name = `${c.file}:${c.name}`, i = c.input, exp = c.expected;
    if (c.fn === "sharedGroups") {
      if (!eqSet(new Set(sharedGroupsReplay(i)), new Set(exp.groupIds))) errs.push(`${name}: shared groups mismatch`);
    } else if (c.fn === "combinedByCategory") {
      const g = combinedByCategoryReplay(i);
      const keys = new Set([...g.keys(), ...Object.keys(exp.byCategory)]);
      for (const k of keys) {
        const got = g.get(k), e = exp.byCategory[k];
        if (!got || !e) { errs.push(`${name}: category ${k} presence mismatch`); continue; }
        if (!rEqDec(got.mine, e.mine)) errs.push(`${name}: ${k} mine != ${e.mine}`);
        if (!rEqDec(got.partnerTotal, e.partnerTotal)) errs.push(`${name}: ${k} partnerTotal != ${e.partnerTotal}`);
        if (!rEqDec(radd(got.mine, got.partnerTotal), e.combined)) errs.push(`${name}: ${k} combined != ${e.combined}`);
      }
    } else errs.push(`${name}: unknown fn ${c.fn}`);
  }
  return { count: cases.length, files: files.length };
}

// =====================================================================================
// goals  (GoalProgress + SpendPeriod + monthly aggregations)
// =====================================================================================
function ymOf(s) { const d = new Date(s); return { y: d.getUTCFullYear(), m: d.getUTCMonth() + 1 }; }
function addMonthsYM(ym, delta) { const idx = ym.y * 12 + (ym.m - 1) + delta; return { y: Math.floor(idx / 12), m: (idx % 12) + 1 }; }
const ymKey2 = (ym) => `${ym.y}-${ym.m}`;
function monthRangeYM(months, ending) { const end = ymOf(ending); const out = []; for (let i = months - 1; i >= 0; i--) out.push(addMonthsYM(end, -i)); return out; }

function budgetStatusR(spent, target) { const s = Number(spent), t = Number(target); if (t <= 0) return s > 0 ? "over" : "under"; if (s > t) return "over"; return s / t >= 0.85 ? "nearing" : "under"; }
function budgetFractionR(spent, target) { const s = Number(spent), t = Number(target); if (t <= 0) return s > 0 ? 1 : 0; return Math.min(Math.max(s / t, 0), 1); }
function saveFractionR(cur, start, tgt, type) {
  const c = Number(cur), st = Number(start), g = Number(tgt), gained = c - st;
  if (type === "balance") { const needed = g - st; if (needed <= 0) return c >= g ? 1 : 0; return Math.min(Math.max(gained / needed, 0), 1); }
  if (g <= 0) return 0; return Math.min(Math.max(gained / g, 0), 1);
}
function spendPeriodR(period, anchor, now) {
  const thisM = ymOf(now), back = (n) => addMonthsYM(thisM, -n);
  const monthsBetween = (s, e) => (e.y * 12 + e.m) - (s.y * 12 + s.m) + 1;
  let start, end;
  switch (period) {
    case "month": { const m = ymOf(anchor); start = m; end = m; break; }
    case "last3": start = back(2); end = thisM; break;
    case "last6": start = back(5); end = thisM; break;
    case "last12": start = back(11); end = thisM; break;
    case "yearToDate": start = { y: thisM.y, m: 1 }; end = thisM; break;
    case "previousYear": start = { y: thisM.y - 1, m: 1 }; end = { y: thisM.y - 1, m: 12 }; break;
  }
  return { start, end, months: monthsBetween(start, end) };
}
function monthlySpendingR(inp) {
  const totals = new Map();
  for (const ev of spendEventsReplay(inp)) if (isSpendEvent(ev)) { const k = ymKey2(ymOf(ev.date)); totals.set(k, radd(totals.get(k) || RZERO, ev.amount)); }
  return monthRangeYM(inp.months, inp.ending).map((ym) => ({ ym, value: totals.get(ymKey2(ym)) || RZERO }));
}
function monthlyNetIncomeR(inp) {
  const totals = new Map();
  for (const ev of spendEventsReplay(inp)) { if (!ev.countsInCashFlow) continue; if (ev.category != null && NEUTRAL.includes(ev.category)) continue; const k = ymKey2(ymOf(ev.date)); totals.set(k, rsub(totals.get(k) || RZERO, ev.amount)); }
  return monthRangeYM(inp.months, inp.ending).map((ym) => ({ ym, value: totals.get(ymKey2(ym)) || RZERO }));
}
function runGoals(errs) {
  const { files, cases } = loadModule("goals");
  const checkMonthly = (got, exp, name) => {
    if (got.length !== exp.length) { errs.push(`${name}: length ${got.length} != ${exp.length}`); return; }
    got.forEach((g, i) => { const e = exp[i]; if (g.ym.y !== e.year || g.ym.m !== e.month || !rEqDec(g.value, e.value)) errs.push(`${name}[${i}]: {${g.ym.y}-${g.ym.m},${g.value.n}/${g.value.d}} != {${e.year}-${e.month},${e.value}}`); });
  };
  for (const c of cases) {
    const name = `${c.file}:${c.name}`, i = c.input, exp = c.expected;
    switch (c.fn) {
      case "budgetStatus": { const g = budgetStatusR(i.spent, i.target); if (g !== exp.status) errs.push(`${name}: ${g} != ${exp.status}`); break; }
      case "budgetFraction": { const g = budgetFractionR(i.spent, i.target); if (g !== exp.fraction) errs.push(`${name}: ${g} != ${exp.fraction}`); break; }
      case "saveFraction": { const g = saveFractionR(i.current, i.starting, i.target, i.type); if (g !== exp.fraction) errs.push(`${name}: ${g} != ${exp.fraction}`); break; }
      case "spendPeriod": {
        const g = spendPeriodR(i.period, i.anchor, i.now);
        if (g.start.y !== exp.startYear || g.start.m !== exp.startMonth || g.end.y !== exp.endYear || g.end.m !== exp.endMonth || g.months !== exp.months) errs.push(`${name}: period mismatch`);
        break;
      }
      case "monthRange": {
        const g = monthRangeYM(i.months, i.ending);
        if (g.length !== exp.range.length || g.some((ym, k) => ym.y !== exp.range[k].year || ym.m !== exp.range[k].month)) errs.push(`${name}: range mismatch`);
        break;
      }
      case "monthlySpending": checkMonthly(monthlySpendingR(i), exp.values, name); break;
      case "monthlyNetIncome": checkMonthly(monthlyNetIncomeR(i), exp.values, name); break;
      default: errs.push(`${name}: unknown fn ${c.fn}`);
    }
  }
  return { count: cases.length, files: files.length };
}

// =====================================================================================
// receipts  (ReceiptHeuristics merchant/total + recentReceiptDate clamp)
// =====================================================================================
function receiptLines(text) { return text.split("\n").map((l) => l.trim()).filter(Boolean); }
function receiptMerchant(text) { const l = receiptLines(text); return l.length ? l[0] : null; }
function amountsIn(line) {
  const out = []; const re = /\d[\d,]*\.\d{2}/g; let m;
  while ((m = re.exec(line)) !== null) out.push(decToRat(m[0].replace(/,/g, "")));
  return out;
}
function receiptTotal(text) {
  const lines = receiptLines(text);
  const totalLines = lines.filter((l) => { const s = l.toLowerCase(); return s.includes("total") && !s.includes("subtotal"); });
  let cands = totalLines.flatMap(amountsIn);
  if (!cands.length) cands = lines.flatMap(amountsIn);
  if (!cands.length) return null;
  return cands.reduce((a, b) => (rcmp(a, b) >= 0 ? a : b));
}
const dayIndex = (s) => Math.floor(new Date(s).getTime() / 86400000);
function ymdOfIndex(idx) { const d = new Date(idx * 86400000); return { y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: d.getUTCDate() }; }
function recentReceiptDateR(dateStr, now, window) {
  const today = dayIndex(now), earliest = today - window;
  let res = today;
  if (dateStr != null) { const dd = dayIndex(dateStr); if (dd >= earliest && dd <= today) res = dd; }
  return ymdOfIndex(res);
}
function runReceipts(errs) {
  const { files, cases } = loadModule("receipts");
  for (const c of cases) {
    const name = `${c.file}:${c.name}`, i = c.input, exp = c.expected;
    switch (c.fn) {
      case "receiptMerchant": { const g = receiptMerchant(i.text); if ((g ?? null) !== (exp.merchant ?? null)) errs.push(`${name}: ${g} != ${exp.merchant}`); break; }
      case "receiptTotal": { const g = receiptTotal(i.text); const ok = g == null ? exp.total == null : rEqDec(g, exp.total); if (!ok) errs.push(`${name}: total mismatch (${exp.total})`); break; }
      case "recentReceiptDate": { const g = recentReceiptDateR(i.date, i.now, i.window ?? 60); if (g.y !== exp.year || g.m !== exp.month || g.d !== exp.day) errs.push(`${name}: ${g.y}-${g.m}-${g.d} != ${exp.year}-${exp.month}-${exp.day}`); break; }
      default: errs.push(`${name}: unknown fn ${c.fn}`);
    }
  }
  return { count: cases.length, files: files.length };
}

// =====================================================================================
// suggestions  (SuggestionRanking + SplitTemplateLearning; ranked asserts order)
// =====================================================================================
const TYPE_WEIGHT = { link: 4, recurringSplit: 4, categorize: 3, overspend: 2, nearingBudget: 2, settleUp: 2, sharedBudgetCandidate: 2, subscription: 1 };
function suggestionRecency(dateStr, now) {
  if (dateStr == null) return 0.5;
  const ageDays = Math.max(0, (new Date(now).getTime() - new Date(dateStr).getTime()) / 86400000);
  return Math.exp(-ageDays / 30.0);
}
function suggestionConfidence(s) {
  switch (s.kind) {
    case "link": return s.matchScore ?? 0.85;
    case "recurringSplit": return 1.0;
    case "categorize": return Math.min(Math.max(s.transactionIdCount ?? 0, 1) / 10.0, 1.0);
    case "subscription": return 0.5;
    default: return 0.6;
  }
}
const suggestionScore = (s, now) => TYPE_WEIGHT[s.kind] + 1.0 * suggestionRecency(s.sortDate, now) + 0.5 * suggestionConfidence(s);
function rankedReplay(inp) {
  return inp.suggestions
    .map((s) => ({ s, score: suggestionScore(s, inp.now) }))
    .sort((a, b) => (a.score !== b.score ? b.score - a.score : a.s.id < b.s.id ? -1 : 1))
    .slice(0, 28)
    .map((x) => x.s.id);
}
function deriveTemplates(inp) {
  const minOcc = inp.minOccurrences ?? 2;
  const byKey = new Map();
  for (const e of inp.expenses) {
    if (e.transactionId == null) continue;
    if ((e.splits || []).filter((s) => Number(s.owedShare) > 0).length < 2) continue;
    if (e.category != null && NEUTRAL.includes(e.category)) continue;
    const key = merchantKey(e.details);
    if (!key) continue;
    if (!byKey.has(key)) byKey.set(key, []); byKey.get(key).push(e);
  }
  const out = [];
  for (const [key, group] of byKey) {
    if (group.length < minOcc) continue;
    const groupIds = new Set(group.map((e) => e.groupId));
    if (groupIds.size !== 1) continue;
    const groupId = [...groupIds][0];
    const sums = new Map();
    for (const e of group) {
      let total = 0;
      for (const s of e.splits) { const o = Number(s.owedShare); if (o > 0) total += o; }
      if (total <= 0) continue;
      for (const s of e.splits) { const o = Number(s.owedShare); if (o > 0) sums.set(s.userIdentifier, (sums.get(s.userIdentifier) || 0) + o / total); }
    }
    if (!sums.size) continue;
    const n = group.length;
    const shares = {};
    for (const [k, v] of sums) shares[k] = v / n;
    out.push({ merchantKey: key, groupId, shares });
  }
  return out;
}
function runSuggestions(errs) {
  const { files, cases } = loadModule("suggestions");
  const near = (a, b) => Math.abs(a - b) <= 1e-9;
  for (const c of cases) {
    const name = `${c.file}:${c.name}`, i = c.input, exp = c.expected;
    switch (c.fn) {
      case "typeWeight": { if (TYPE_WEIGHT[i.kind] !== exp.weight) errs.push(`${name}: ${TYPE_WEIGHT[i.kind]} != ${exp.weight}`); break; }
      case "suggestionConfidence": { const g = suggestionConfidence(i); if (!near(g, exp.confidence)) errs.push(`${name}: ${g} != ${exp.confidence}`); break; }
      case "recency": { const g = suggestionRecency(i.date, i.now); if (!near(g, exp.recency)) errs.push(`${name}: ${g} != ${exp.recency}`); break; }
      case "ranked": { const g = rankedReplay(i); if (!eqArr(g, exp.order)) errs.push(`${name}: [${g}] != [${exp.order}]`); break; }
      case "deriveTemplates": {
        const g = deriveTemplates(i);
        if (g.length !== exp.templates.length) { errs.push(`${name}: template count ${g.length} != ${exp.templates.length}`); break; }
        const byMk = new Map(g.map((t) => [t.merchantKey, t]));
        for (const e of exp.templates) {
          const t = byMk.get(e.merchantKey);
          if (!t) { errs.push(`${name}: missing template ${e.merchantKey}`); continue; }
          if (t.groupId !== e.groupId) errs.push(`${name}: ${e.merchantKey} groupId mismatch`);
          const keys = new Set([...Object.keys(t.shares), ...Object.keys(e.shares)]);
          for (const k of keys) if (!near(t.shares[k] ?? -1, e.shares[k] ?? -2)) errs.push(`${name}: ${e.merchantKey} share ${k} ${t.shares[k]} != ${e.shares[k]}`);
        }
        break;
      }
      default: errs.push(`${name}: unknown fn ${c.fn}`);
    }
  }
  return { count: cases.length, files: files.length };
}

// =====================================================================================
// deep-links  (JoinLink + NotificationTarget)
// =====================================================================================
function joinParse(urlStr) {
  let u;
  try { u = new URL(urlStr); } catch { return null; }
  const isJoin = (u.hostname === "cleave.money" && u.pathname === "/join") ||
    (u.protocol === "cleave:" && (u.hostname === "join" || u.pathname.endsWith("join")));
  if (!isJoin) return null;
  const api = u.searchParams.get("api");
  if (!api) return null;
  const invite = u.searchParams.get("invite");
  return { api, invite: invite ? invite : null };
}
function joinReachable(apiUrl) {
  let host;
  try { host = new URL(apiUrl).hostname.toLowerCase(); } catch { return false; }
  if (!host) return false;
  if (host === "localhost" || host === "127.0.0.1") return false;
  if (host.endsWith(".local") || host.endsWith(".lan")) return false;
  if (host.startsWith("192.168.") || host.startsWith("10.") || host.startsWith("172.")) return false;
  return true;
}
const isUuid = (s) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(s);
function ntParse(type, id) {
  if (type == null || id == null || id === "") return null;
  if (["expense", "transaction", "account", "goal", "group"].includes(type)) return isUuid(id) ? `${type}:${id}` : null;
  if (type === "friend") return `friend:${id}`;
  return null;
}
function runDeepLinks(errs) {
  const { files, cases } = loadModule("deep-links");
  for (const c of cases) {
    const name = `${c.file}:${c.name}`, i = c.input, exp = c.expected;
    switch (c.fn) {
      case "joinParse": {
        const g = joinParse(i.url);
        if (exp.api == null) { if (g !== null) errs.push(`${name}: expected null, got ${JSON.stringify(g)}`); }
        else if (!g || g.api !== exp.api || (g.invite ?? null) !== (exp.invite ?? null)) errs.push(`${name}: ${JSON.stringify(g)} != {${exp.api},${exp.invite}}`);
        break;
      }
      case "joinReachable": { const g = joinReachable(i.url); if (g !== exp.reachable) errs.push(`${name}: ${g} != ${exp.reachable}`); break; }
      case "ntParse": { const g = ntParse(i.type, i.id); if ((g ?? null) !== (exp.target ?? null)) errs.push(`${name}: ${g} != ${exp.target}`); break; }
      default: errs.push(`${name}: unknown fn ${c.fn}`);
    }
  }
  return { count: cases.length, files: files.length };
}

// =====================================================================================
const errs = [];
const modules = [
  ["split-math", runSplitMath], ["category", runCategory],
  ["itemized-spend", runItemized], ["account-classification", runAccountClassification],
  ["spend-engine", runSpendEngine], ["subscriptions", runSubscriptions], ["matching", runMatching],
  ["merchant-brand", runMerchantBrand], ["household-budget", runHousehold], ["goals", runGoals],
  ["receipts", runReceipts], ["suggestions", runSuggestions], ["deep-links", runDeepLinks],
];
let total = 0;
for (const [name, run] of modules) {
  const { count, files } = run(errs);
  total += count;
  console.log(`  ${name}: ${count} cases across ${files} files`);
}
if (errs.length) {
  console.log(`FAIL (${errs.length} of ${total} cases):`);
  errs.forEach((e) => console.log("  -", e));
  process.exit(1);
}
console.log(`OK: ${total} cases reproduced`);
process.exit(0);
