// fetch_icons.js —— 从 Fluent System Icons 官方仓库取单个图标的原封 SVG。
// 用法: node fetch_icons.js <输出目录> [SymbolName ...]
// 不传 SymbolName 时取内置清单。多镜像依次回退，任一成功即停。
const fs = require('fs');
const path = require('path');

// 内置清单：Symbol 名 -> 仓库内的相对路径
const BUILTIN = {
    Add20: 'assets/Add/SVG/ic_fluent_add_20_regular.svg',
    Bluetooth20: 'assets/Bluetooth/SVG/ic_fluent_bluetooth_20_regular.svg',
};

const MIRRORS = [
    (n) => 'https://cdn.jsdelivr.net/gh/microsoft/fluentui-system-icons@main/' + n,
    (n) => 'https://raw.githubusercontent.com/microsoft/fluentui-system-icons/main/' + n,
    (n) => 'https://ghproxy.net/https://raw.githubusercontent.com/microsoft/fluentui-system-icons/main/' + n,
];

async function grab(rel) {
    for (const mk of MIRRORS) {
        const url = mk(rel);
        const host = url.split('/')[2];
        try {
            const r = await fetch(url, { redirect: 'follow' });
            if (!r.ok) {
                console.log('    ' + r.status + '  ' + host);
                continue;
            }
            const t = await r.text();
            if (t.indexOf('<svg') < 0 || t.indexOf('viewBox') < 0) {
                console.log('    内容不像 SVG  ' + host);
                continue;
            }
            return { text: t, host: host };
        } catch (e) {
            console.log('    ' + e.message + '  ' + host);
        }
    }
    return null;
}

(async () => {
    const outDir = process.argv[2];
    if (!outDir) {
        console.log('用法: node fetch_icons.js <输出目录> [SymbolName ...]');
        process.exitCode = 2;
        return;
    }
    const wanted = process.argv.slice(3);
    const names = wanted.length ? wanted : Object.keys(BUILTIN);

    let failed = 0;
    for (const name of names) {
        const rel = BUILTIN[name];
        if (!rel) {
            console.log('  ✗ ' + name + ': 不在清单里，请先把路径加到 BUILTIN');
            failed++;
            continue;
        }
        console.log('  · ' + name);
        const got = await grab(rel);
        if (!got) {
            console.log('  ✗ ' + name + ' 所有镜像都失败');
            failed++;
            continue;
        }
        fs.mkdirSync(outDir, { recursive: true });
        const dst = path.join(outDir, name + '.svg');
        fs.writeFileSync(dst, got.text);
        console.log('  ✓ ' + name + '.svg  ' + got.text.length + ' B  <- ' + got.host);
    }
    process.exitCode = failed ? 1 : 0;
})();
