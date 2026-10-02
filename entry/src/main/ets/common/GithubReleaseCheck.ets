/**
 * GitHub Release 更新检查（关于页「检查更新」按钮真做的事）。
 *
 * ── 为什么单独一个文件 ──────────────────────────────────────────────────────
 * 关于页此前把「检查更新」写死成一句「鸿蒙版尚未接入 GitHub Release 检查」——
 * 那是对的做法（不假装检查成功），但用户点按钮永远得不到结果。现在把它做成一条
 * 真的链路：打 GitHub Releases API → 拿最新 tag → 与本机版本号比 → 回报结果。
 *
 * ── 不许假成功（本工程一贯要求）───────────────────────────────────────────
 * 只有下面这些情况会返回真结果：
 *   * HTTP 200 且 JSON 里有 tag_name ⇒ 报"远端版本号 + 比较结果"；
 *   * HTTP 404（仓库还没有任何 Release）⇒ 明确说"仓库暂无 Release"，**不**说"已是最新"；
 *   * 网络不通 / 超时 / JSON 解析失败 ⇒ 报确切原因，**不**说"已是最新"。
 * "已是最新"只在拿到了远端版本号、且它不大于本机版本号时出现。
 *
 * ── 异常纪律（子窗口铁律 1）──────────────────────────────────────────────
 * 这里是 async 函数：抛出的异常会进 Promise 的 reject 分支，而调用方若是 UI 点击
 * 回调且没接住，异常没人接管 ⇒ 整个应用被结束。所以函数内部把所有可疑点都包进
 * try，失败一律转成结果对象里的 reason，绝不上抛。
 */
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@ohos.base';

/** 检查目标仓库（与关于页 GITHUB_REPO_URL 同源）。 */
const OWNER: string = 'zhangziqizZ';
const REPO: string = 'iPhoneMirror';
/** Releases API：latest = 最新一条非草稿 Release（可能含预发布）。 */
const LATEST_RELEASE_URL: string =
  `https://api.github.com/repos/${OWNER}/${REPO}/releases/latest`;

/** 单次检查的超时预算（毫秒）。UI 是同步点一下，等太久就是在为难用户。 */
const CONNECT_TIMEOUT_MS: number = 8000;
const READ_TIMEOUT_MS: number = 8000;

/** 检查结果的四种去向。用数字常量而不是 enum：跨文件的 ArkTS 常常对不上类型。 */
export const UPDATE_OUTCOME_HAS_UPDATE: number = 0;   // 远端版本更新
export const UPDATE_OUTCOME_UP_TO_DATE: number = 1;   // 拿到远端版本，本机不落后
export const UPDATE_OUTCOME_NO_RELEASE: number = 2;   // 仓库还没有任何 Release
export const UPDATE_OUTCOME_FAILED: number = 3;       // 没查成（网络/解析/超时）

/** 一次检查的完整读数：UI 直接拼这一个对象，不必再自己判空。 */
export interface UpdateCheckResult {
  outcome: number;
  /** 远端版本号（已去掉开头的 v）。查不到时为空串。 */
  remoteVersion: string;
  /** 远端发布日期（YYYY-MM-DD，取 published_at 前 10 位）。 */
  remoteDate: string;
  /** 远端这一条是否是预发布（Beta）。 */
  remotePrerelease: boolean;
  /** 该 Release 的网页地址（给用户自己去下载）。 */
  remoteUrl: string;
  /** 远端版本的发布说明（截断到 200 字，正文可能很长）。 */
  remoteNotes: string;
  /** 失败时的人类可读原因；成功时为空串。 */
  reason: string;
  /** 本机版本号（调用方传入，用于在 UI 上核对）。 */
  localVersion: string;
}

/** http 响应体的形态（API 只用到这几个字段，其余忽略）。 */
interface ReleaseApiPayload {
  tag_name?: string;
  name?: string;
  html_url?: string;
  prerelease?: boolean;
  draft?: boolean;
  published_at?: string;
  body?: string;
}

/**
 * 版号比较：把 "v1.8.3-test4" 这样的字符串拆成数字三段。
 *
 * 为什么自己写：Semver 的完整规则用不上，而 "1.8.3-test4" 这种带后缀的
 * 版本号在 GitHub tag 里很常见 —— 后缀是预发布标记，比较时只看前面的数字主体
 * （上游 Windows 的 1.8.4-test4 就是这种写法）。
 *
 * @returns 数字三段；任一主体不是数字时返回 null（调用方据此报"版号读不出来"）。
 */
export function parse_version_core(version: string): number[] | null {
  const text: string = version.trim();
  if (text.length === 0) return null;
  const body: string = text.startsWith('v') || text.startsWith('V')
    ? text.substring(1)
    : text;
  // 只取开头连续的数字与点，遇到 '-'（预发布后缀）、'+'（构建元数据）就停。
  const core: string[] = body.split(/[-+]/)[0].split('.');
  if (core.length === 0) return null;
  const numbers: number[] = [];
  for (const part of core) {
    if (part.length === 0) return null;
    for (let i = 0; i < part.length; i++) {
      const code: number = part.charCodeAt(i);
      if (code < 48 || code > 57) return null;
    }
    numbers.push(Number.parseInt(part, 10));
  }
  // 1.0 / 1 / 1.0.0 都按三段补齐，缺的当 0。
  while (numbers.length < 3) numbers.push(0);
  return numbers;
}

/** 返回 -1/0/1：left 小于/等于/大于 right。 */
export function compare_versions(left: string, right: string): number {
  const a: number[] | null = parse_version_core(left);
  const b: number[] | null = parse_version_core(right);
  if (a === null || b === null) return 0;
  for (let i = 0; i < 3; i++) {
    if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

/** 结果对象里 reason 之外的字段都在这儿初始化，避免调用方各处判空。 */
function empty_result(localVersion: string): UpdateCheckResult {
  return {
    outcome: UPDATE_OUTCOME_FAILED,
    remoteVersion: '',
    remoteDate: '',
    remotePrerelease: false,
    remoteUrl: `https://github.com/${OWNER}/${REPO}/releases`,
    remoteNotes: '',
    reason: '',
    localVersion: localVersion,
  };
}

function failure(localVersion: string, reason: string): UpdateCheckResult {
  const result: UpdateCheckResult = empty_result(localVersion);
  result.outcome = UPDATE_OUTCOME_FAILED;
  result.reason = reason;
  return result;
}

/**
 * 向 GitHub Releases API 查最新一版，与本地版本号比对。
 *
 * ★ 本函数**保证不抛异常**：所有失败都转成 outcome + reason。
 *
 * @param localVersion 本机版本号（形如 "1.0.45"，前缀 v 可有可无）。
 */
export async function check_latest_release(localVersion: string): Promise<UpdateCheckResult> {
  const request = http.createHttp();
  try {
    const response: http.HttpResponse = await request.request(LATEST_RELEASE_URL, {
      method: http.RequestMethod.GET,
      header: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'iPhoneMirror-ohos',
      },
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: CONNECT_TIMEOUT_MS,
      readTimeout: READ_TIMEOUT_MS,
    });
    if (response.responseCode === 404) {
      const noRelease: UpdateCheckResult = empty_result(localVersion);
      noRelease.outcome = UPDATE_OUTCOME_NO_RELEASE;
      return noRelease;
    }
    if (response.responseCode !== 200) {
      return failure(localVersion, `HTTP ${response.responseCode}（稍后再点一次）`);
    }
    if (typeof response.result !== 'string') {
      return failure(localVersion, '响应体不是文本（UA/代理拦截了 GitHub API）');
    }
    const text: string = response.result as string;
    let payload: ReleaseApiPayload;
    try {
      payload = JSON.parse(text) as ReleaseApiPayload;
    } catch (parseError) {
      return failure(localVersion, '响应不是合法 JSON（可能被代理页面替换）');
    }
    const tag: string = payload.tag_name !== undefined ? payload.tag_name : '';
    if (tag.length === 0) {
      return failure(localVersion, '响应里没有 tag_name');
    }
    const result: UpdateCheckResult = empty_result(localVersion);
    result.remoteVersion = (tag.startsWith('v') || tag.startsWith('V'))
      ? tag.substring(1) : tag;
    result.remotePrerelease = payload.prerelease === true;
    if (payload.published_at !== undefined && payload.published_at.length >= 10) {
      result.remoteDate = payload.published_at.substring(0, 10);
    }
    if (payload.html_url !== undefined && payload.html_url.length > 0) {
      result.remoteUrl = payload.html_url;
    }
    if (payload.body !== undefined) {
      // 发布说明可能很长，UI 一行放不下：截断到 200 字，完整版让用户点开网页看。
      const body: string = payload.body.replace(/\r/g, ' ').replace(/\n/g, ' ').trim();
      result.remoteNotes = body.length > 200 ? body.substring(0, 200) + '…' : body;
    }
    if (parse_version_core(result.remoteVersion) === null) {
      // 端倪：拿到了 tag 但读不出数字主体（例如写成了 "release-2026-10"）。
      result.outcome = UPDATE_OUTCOME_FAILED;
      result.reason = `远端版号读不出来：${tag}`;
      return result;
    }
    if (parse_version_core(localVersion) === null) {
      result.outcome = UPDATE_OUTCOME_FAILED;
      result.reason = `本机版号读不出来：${localVersion}`;
      return result;
    }
    result.outcome = compare_versions(result.remoteVersion, localVersion) > 0
      ? UPDATE_OUTCOME_HAS_UPDATE
      : UPDATE_OUTCOME_UP_TO_DATE;
    return result;
  } catch (error) {
    const failureError: BusinessError = error as BusinessError;
    const reason: string = failureError.message !== undefined
      ? `${failureError.code} ${failureError.message}` : '未知原因';
    return failure(localVersion, reason);
  } finally {
    try {
      request.destroy();
    } catch (destroyError) {
      // 销毁失败不影响结果：连接会随进程回收，吞掉即可。
    }
  }
}
