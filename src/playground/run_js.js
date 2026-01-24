/**
 * JS Pug - Process all .pug files in playground folder
 */

const fs = require('fs');
const path = require('path');
const pug = require('../../pug');

const dir = path.join(__dirname, 'examples');

// Get all .pug files
const pugFiles = fs.readdirSync(dir)
  .filter(f => f.endsWith('.pug'))
  .sort();

console.log('=== JS Pug Playground ===\n');
console.log(`Found ${pugFiles.length} .pug files\n`);

let passed = 0;
let failed = 0;
let totalTimeMs = 0;

for (const file of pugFiles) {
  const filePath = path.join(dir, file);
  const source = fs.readFileSync(filePath, 'utf8');

  const iterations = 100;
  let success = false;
  let html = '';
  let error = '';
  let timeMs = 0;

  try {
    const start = process.hrtime.bigint();

    for (let i = 0; i < iterations; i++) {
      html = pug.render(source, {
        filename: filePath,
        basedir: dir
      });
    }

    const end = process.hrtime.bigint();
    timeMs = Number(end - start) / 1_000_000 / iterations;
    success = true;
    passed++;
    totalTimeMs += timeMs;
  } catch (e) {
    error = e.message.split('\n')[0];
    failed++;
  }

  if (success) {
    console.log(`✓ ${file} (${timeMs.toFixed(3)} ms)`);
    // Show first 200 chars of output
    const preview = html.replace(/\s+/g, ' ').substring(0, 200);
    console.log(`  → ${preview}${html.length > 200 ? '...' : ''}\n`);
  } else {
    console.log(`✗ ${file}`);
    console.log(`  → ${error}\n`);
  }
}

console.log('=== Summary ===');
console.log(`Passed: ${passed}/${pugFiles.length}`);
console.log(`Failed: ${failed}/${pugFiles.length}`);
if (passed > 0) {
  console.log(`Total time: ${totalTimeMs.toFixed(3)} ms`);
  console.log(`Average: ${(totalTimeMs / passed).toFixed(3)} ms per file`);
}
