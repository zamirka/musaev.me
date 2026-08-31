#!/usr/bin/env node
/**
 * Печатает /cv/print/ в public/cv.pdf.
 * Один источник правды – data/cv.yaml, поэтому PDF и страница не могут разойтись.
 * Ожидает уже собранный public/ (npm run build). Используется и локально, и в CI.
 */
import { createServer } from 'node:http';
import { readFile, access, mkdir } from 'node:fs/promises';
import { join, extname, resolve } from 'node:path';
import { chromium } from 'playwright';

const ROOT = resolve(import.meta.dirname, '..');
const PUBLIC = join(ROOT, 'public');
const OUT = join(PUBLIC, 'cv.pdf');
const PORT = Number(process.env.PDF_PORT || 1414);

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.png': 'image/png',
  '.webp': 'image/webp',
  '.woff2': 'font/woff2',
};

async function main() {
  try {
    await access(join(PUBLIC, 'cv', 'print', 'index.html'));
  } catch {
    console.error('Нет public/cv/print/index.html – сначала соберите сайт: npm run build');
    process.exit(1);
  }

  const server = createServer(async (req, res) => {
    let p = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    if (p.endsWith('/')) p += 'index.html';
    const file = join(PUBLIC, p);
    if (!file.startsWith(PUBLIC)) {
      res.writeHead(403).end();
      return;
    }
    try {
      const body = await readFile(file);
      res.writeHead(200, { 'content-type': TYPES[extname(file)] || 'application/octet-stream' });
      res.end(body);
    } catch {
      res.writeHead(404).end('not found');
    }
  });

  await new Promise((r) => server.listen(PORT, '127.0.0.1', r));

  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    // Печатаем в светлой схеме независимо от настроек машины, где идёт сборка.
    await page.emulateMedia({ media: 'print', colorScheme: 'light' });
    const res = await page.goto(`http://127.0.0.1:${PORT}/cv/print/`, { waitUntil: 'networkidle' });
    if (!res || !res.ok()) throw new Error(`страница отдала ${res && res.status()}`);

    await mkdir(PUBLIC, { recursive: true });
    await page.pdf({
      path: OUT,
      format: 'A4',
      printBackground: false,
      margin: { top: '14mm', bottom: '16mm', left: '14mm', right: '14mm' },
      displayHeaderFooter: true,
      headerTemplate: '<div></div>',
      footerTemplate:
        '<div style="width:100%;font-size:8px;color:#8b857a;padding:0 14mm;' +
        'display:flex;justify-content:space-between;font-family:-apple-system,sans-serif">' +
        '<span>Замир Мусаев · musaev.me/cv</span>' +
        '<span><span class="pageNumber"></span> / <span class="totalPages"></span></span></div>',
    });
    console.log(`Готово: ${OUT}`);
  } finally {
    await browser.close();
    server.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
