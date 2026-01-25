/**
 * Pug.js Benchmark - Comparison with Pugz
 *
 * Run: npm install && npm run bench
 *
 * Both Pug.js and Pugz benchmarks read from the same files:
 *   ../templates/*.pug  (templates)
 *   ../templates/*.json (data)
 */

const fs = require('fs');
const path = require('path');
const pug = require('pug');

const iterations = 2000;
const templatesDir = path.join(__dirname, '..', 'templates');

const benchmarks = [
  'simple-0',
  'simple-1',
  'simple-2',
  'if-expression',
  'projects-escaped',
  'search-results',
  'friends',
];

// ═══════════════════════════════════════════════════════════════════════════
// Load templates and data from shared files BEFORE benchmarking
// ═══════════════════════════════════════════════════════════════════════════

console.log("");
console.log("Loading templates and data...");

const templates = {};
const data = {};

for (const name of benchmarks) {
  templates[name] = fs.readFileSync(path.join(templatesDir, `${name}.pug`), 'utf8');
  data[name] = JSON.parse(fs.readFileSync(path.join(templatesDir, `${name}.json`), 'utf8'));
}

// Compile all templates BEFORE benchmarking
const compiled = {};
for (const name of benchmarks) {
  compiled[name] = pug.compile(templates[name], { pretty: true });
}

console.log("Templates compiled. Starting benchmark...\n");

// ═══════════════════════════════════════════════════════════════════════════
// Benchmark
// ═══════════════════════════════════════════════════════════════════════════

console.log("╔═══════════════════════════════════════════════════════════════╗");
console.log(`║        Pug.js Benchmark (${iterations} iterations)                    ║`);
console.log("║        Templates: benchmarks/templates/*.pug                   ║");
console.log("║        Data:      benchmarks/templates/*.json                 ║");
console.log("╚═══════════════════════════════════════════════════════════════╝");

let total = 0;

for (const name of benchmarks) {
  const compiledFn = compiled[name];
  const templateData = data[name];

  // Warmup
  for (let i = 0; i < 100; i++) {
    compiledFn(templateData);
  }

  // Benchmark
  const start = process.hrtime.bigint();
  for (let i = 0; i < iterations; i++) {
    compiledFn(templateData);
  }
  const end = process.hrtime.bigint();

  const ms = Number(end - start) / 1_000_000;
  total += ms;
  console.log(`  ${name.padEnd(20)} => ${ms.toFixed(1).padStart(7)}ms`);
}

console.log("");
console.log(`  ${"TOTAL".padEnd(20)} => ${total.toFixed(1).padStart(7)}ms`);
console.log("");
