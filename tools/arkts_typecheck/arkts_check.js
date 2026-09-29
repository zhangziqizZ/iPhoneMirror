#!/usr/bin/env node
/*
 * arkts_check.js —— 用 SDK 自带的 OpenHarmony 补丁版 TypeScript
 * （`typescript@4.9.5-r4`，能解析 ArkTS 的 `struct` / `@Component`）对工程做
 * 真类型检查，等价于 dev 侧 `CompileArkTS` 的语义检查部分。
 *
 * 为什么不用 `tsc.js` CLI：
 *   ETS 检查器里的 `checkIfChildComponent()` 会调用 `node.getChildren()`，
 *   而 `getChildren` 只由 TypeScript 的 **services 层** 安装 —— `typescript.js`
 *   里有 48 处，`tsc.js` 里只有 5 处（全是调用点，没有定义）。因此用 CLI 跑，
 *   只要 `build()` 里出现裸 `if`，就会 `TypeError: node.getChildren is not a
 *   function` 直接崩掉，且**退出码为 0、不报任何诊断**（假阴性，极危险）。
 *   走 API（`require('typescript.js')`）`getChildren` 就存在，问题消失。
 *
 * 用法：node arkts_check.js <tsconfig.json>
 * 输出：stdout 一行 JSON：
 *   { "ok": bool, "crash": null|string, "diagnostics": [...], "fileCount": n }
 *   ok=false 且 crash 非空 → 工具自身失败，不代表代码有问题。
 */
'use strict';

const path = require('path');
const fs = require('fs');

function main() {
    const cfgPath = process.argv[2];
    if (!cfgPath) {
        return fail('用法: node arkts_check.js <tsconfig.json>');
    }
    // 编译器来自 tsconfig 里的 __sdkTypescriptDir（由 python 包装层注入）
    let tsDir = process.env.OHOS_TS_DIR;
    let cfgRaw;
    try {
        cfgRaw = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
        if (!tsDir && cfgRaw.__sdkTypescriptDir) tsDir = cfgRaw.__sdkTypescriptDir;
    } catch (e) {
        return fail('读 tsconfig 失败: ' + e.message);
    }
    if (!tsDir) return fail('未指定 patched typescript 目录（OHOS_TS_DIR）');

    let ts;
    try {
        ts = require(path.join(tsDir, 'typescript.js'));
    } catch (e) {
        return fail('加载 typescript.js 失败: ' + e.message);
    }

    // 读配置（走 TS 自己的解析器，能处理 extends / JSON5 风格 / ets 选项）
    let parsed;
    try {
        const read = ts.readConfigFile(cfgPath, ts.sys.readFile);
        if (read.error) return fail('parse tsconfig: ' + ts.flattenDiagnosticMessageText(read.error.messageText, ' '));
        parsed = ts.parseJsonConfigFileContent(
            read.config, ts.sys, path.dirname(cfgPath), undefined, cfgPath
        );
    } catch (e) {
        return fail('解析 tsconfig 失败: ' + e.message);
    }

    const options = Object.assign({}, parsed.options, { noEmit: true });
    const rootNames = parsed.fileNames;

    let program;
    try {
        const host = ts.createCompilerHost(options, true);
        program = ts.createProgram({ rootNames, options, host });
    } catch (e) {
        return fail('createProgram 失败: ' + e.message);
    }

    // 收集诊断。ETS 检查器内部会调 getChildren，services 层已提供，
    // 但仍包一层 try/catch，避免个别节点把整个检查带崩。
    let diags = [];
    let crash = null;
    try {
        diags = ts.getPreEmitDiagnostics(program);
    } catch (e) {
        crash = String((e && e.stack) || e);
    }

    // 逐文件也试一遍，便于在整体失败时仍拿到部分结果
    if (crash) {
        const partial = [];
        for (const sf of program.getSourceFiles()) {
            if (sf.isDeclarationFile) continue;
            try {
                partial.push(...program.getSemanticDiagnostics(sf), ...program.getSyntacticDiagnostics(sf));
            } catch (e2) { /* 该文件跳过 */ }
        }
        diags = partial;
    }

    const out = diags.map((d) => {
        let f = '';
        if (d.file) {
            f = d.file.fileName;
        }
        let line = 0, col = 0;
        if (d.file && typeof d.start === 'number') {
            const p = d.file.getLineAndCharacterOfPosition(d.start);
            line = p.line + 1;
            col = p.character + 1;
        }
        return {
            file: f,
            line: line,
            col: col,
            code: d.code,
            category: ts.DiagnosticCategory[d.category],
            message: ts.flattenDiagnosticMessageText(d.messageText, ' ').replace(/\s+/g, ' ').trim(),
        };
    });

    process.stdout.write(JSON.stringify({
        ok: true,
        crash: crash,
        tsVersion: ts.version,
        fileCount: rootNames.length,
        diagnostics: out,
    }));
    return 0;
}

function fail(msg) {
    process.stdout.write(JSON.stringify({ ok: false, crash: msg, diagnostics: [] }));
    return 0;
}

process.exitCode = main();
