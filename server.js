/**
 * Простой HTTP-сервер для раздачи статических файлов.
 *
 * Использование:
 *   node server.js
 *   PORT=8080 node server.js
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const url = require('url');

const PORT = process.env.PORT || 3000;
const HOST = process.env.HOST || '0.0.0.0';
const ROOT_DIR = __dirname;

// Карта базовых MIME-типов.
const MIME_TYPES = {
    '.html': 'text/html; charset=UTF-8',
    '.htm':  'text/html; charset=UTF-8',
    '.css':  'text/css; charset=UTF-8',
    '.js':   'application/javascript; charset=UTF-8',
    '.mjs':  'application/javascript; charset=UTF-8',
    '.json': 'application/json; charset=UTF-8',
    '.svg':  'image/svg+xml',
    '.png':  'image/png',
    '.jpg':  'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif':  'image/gif',
    '.ico':  'image/x-icon',
    '.woff': 'font/woff',
    '.woff2':'font/woff2',
    '.ttf':  'font/ttf',
    '.txt':  'text/plain; charset=UTF-8',
    '.map':  'application/json; charset=UTF-8',
};

/**
 * Определяет MIME-тип по расширению файла.
 */
function getMimeType(filePath) {
    const ext = path.extname(filePath).toLowerCase();
    return MIME_TYPES[ext] || 'application/octet-stream';
}

/**
 * Безопасно резолвит запрошенный путь в файловой системе,
 * не позволяя выйти за пределы корневой директории.
 */
function resolveSafePath(requestedPath) {
    // Декодируем URL и убираем query-string.
    const decoded = decodeURIComponent(requestedPath.split('?')[0]);
    const cleaned = decoded.replace(/^\/+/, '');

    // Запрещаем traversal: блокируем любые сегменты "..".
    const segments = cleaned.split('/').filter(seg => seg !== '' && seg !== '.');
    if (segments.some(seg => seg === '..')) {
        return null;
    }

    const resolved = path.resolve(ROOT_DIR, ...segments);
    if (!resolved.startsWith(ROOT_DIR)) {
        return null;
    }
    return resolved;
}

/**
 * Отправляет HTTP-ответ с файлом или ошибкой.
 */
function sendResponse(res, statusCode, body, headers = {}) {
    res.writeHead(statusCode, headers);
    res.end(body);
}

const server = http.createServer((req, res) => {
    const parsedUrl = url.parse(req.url);
    let pathname = parsedUrl.pathname || '/';

    // Корень -> index.html
    if (pathname === '/') {
        pathname = '/index.html';
    }

    const filePath = resolveSafePath(pathname);

    if (!filePath) {
        sendResponse(res, 403, 'Forbidden', { 'Content-Type': 'text/plain; charset=UTF-8' });
        return;
    }

    fs.stat(filePath, (err, stats) => {
        if (err || !stats.isFile()) {
            // Если файл не найден и запрашивался путь без расширения — пробуем отдать index.html (SPA-fallback).
            if (err && err.code === 'ENOENT' && !path.extname(filePath)) {
                const fallback = path.join(ROOT_DIR, 'index.html');
                fs.readFile(fallback, (readErr, data) => {
                    if (readErr) {
                        sendResponse(res, 404, '404 Not Found', { 'Content-Type': 'text/plain; charset=UTF-8' });
                        return;
                    }
                    sendResponse(res, 200, data, { 'Content-Type': 'text/html; charset=UTF-8' });
                });
                return;
            }
            sendResponse(res, 404, '404 Not Found', { 'Content-Type': 'text/plain; charset=UTF-8' });
            return;
        }

        fs.readFile(filePath, (readErr, data) => {
            if (readErr) {
                sendResponse(res, 500, '500 Internal Server Error', { 'Content-Type': 'text/plain; charset=UTF-8' });
                return;
            }
            sendResponse(res, 200, data, {
                'Content-Type': getMimeType(filePath),
                'Content-Length': data.length,
                'Cache-Control': 'no-cache',
            });
        });
    });
});

server.listen(PORT, HOST, () => {
    console.log(`✅ Сервер запущен: http://${HOST === '0.0.0.0' ? 'localhost' : HOST}:${PORT}/`);
    console.log(`📁 Раздаёт файлы из: ${ROOT_DIR}`);
});

// Корректное завершение по сигналам.
function shutdown(signal) {
    console.log(`\nПолучен сигнал ${signal}, останавливаю сервер...`);
    server.close(() => {
        console.log('Сервер остановлен.');
        process.exit(0);
    });
    // На случай зависших соединений — принудительный выход через 5 секунд.
    setTimeout(() => process.exit(1), 5000).unref();
}

process.on('SIGINT',  () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));