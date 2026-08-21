import { registerPlugin } from "@capacitor/core";
import type { AxiosAdapter, AxiosResponse, InternalAxiosRequestConfig } from "axios";
import { getCookie } from "./cookie";

/**
 * iOS 原生网易云 API 桥接
 *
 * 仅在 iOS (Capacitor) 构建中被引入 —— 其它端由 `__IS_IOS_BUILD__` 条件编译剔除，
 * 详见 electron.vite.config.ts 的 isIosBuild。
 *
 * 之所以需要这层：渲染进程是 WKWebView 里的 JS，无法直接调用 Swift。
 * 而 `VITE_API_URL` 是相对路径 `/api/netease`，在 `capacitor://localhost` 源下
 * 没有任何服务可以命中，所以 iOS 端必须把请求改道到原生的 NeteaseCloudMusicAPI-Swift。
 */

/** 原生插件返回的响应 */
interface NativeApiResponse {
  status: number;
  body: Record<string, unknown> | null;
}

interface NCMNativePlugin {
  request(options: {
    route: string;
    params: Record<string, unknown>;
    cookie?: string;
  }): Promise<NativeApiResponse>;
}

/** 仅前端使用、不应传给原生库的参数 */
const FRONTEND_ONLY_PARAMS = ["noCookie", "timestamp"];

/**
 * Node 后端服务专属参数，直连模式下无意义
 *
 * realIP / randomCNIP 用于让 Node 后端伪装请求来源 IP（绕过网易云的海外限制），
 * proxy 用于让后端走代理。直连模式下请求由设备自身发出，这些都不适用
 */
const SERVER_ONLY_PARAMS = ["realIP", "randomCNIP", "proxy"];

/** 原生库不覆盖的 baseURL —— 这些是内嵌 Fastify 自己实现的接口 */
const UNSUPPORTED_BASE_URLS: Record<string, string> = {
  "/api/unblock": "灰色音源解锁",
  "/api/qqmusic": "QQ 音乐歌词",
};

/**
 * 构造一个会被响应拦截器识别为网络错误的 Error
 *
 * request.ts 的响应拦截器在 message 含 "Network Error" 时会 resolve 成 `{ data: null }`
 * 而非 reject。这里刻意复用那段逻辑，避免在两处维护同一套降级语义。
 *
 * 但拦截器是静默降级的（不打印原因），因此这里必须先自行输出 —— 否则调用方只会看到
 * `null is not an object` 这类下游崩溃，完全看不到根因（例如插件未注册）
 */
const networkError = (detail: string, route: string): Error => {
  console.error(`[NCMNative] 请求失败 route=${route}：${detail}`);
  const error = new Error(`Network Error: ${detail}`);
  error.name = "NativeBridgeError";
  return error;
};

/**
 * 补上 `__csrf`
 *
 * `request.ts:33-36` 的请求拦截器只把 `MUSIC_U` 拼进 `params.cookie`。
 * 桌面端不受影响 —— 同源的 HTTP Cookie 头会把 `__csrf` 一起带上，
 * 且内嵌 Fastify 的 `cookie: req.cookies` 还会覆盖 query 参数。
 *
 * 但 `capacitor://localhost` 源下 WebKit 不存储 cookie（`document.cookie` 恒为空），
 * 根本没有 Cookie 头，只剩 query 这一条通道。网易云大量鉴权接口需要 `csrf_token`，
 * 缺了它在 App 重启后（SDK 的 cookie jar 是空的新进程）就会开始失败。
 */
const withCsrf = (cookie: string | undefined): string | undefined => {
  const csrf = getCookie("__csrf");
  if (!csrf) return cookie;
  if (cookie?.includes("__csrf=")) return cookie;
  const prefix = cookie ? (cookie.endsWith(";") ? cookie : `${cookie};`) : "";
  return `${prefix}__csrf=${csrf};`;
};

/** 合并 params 与 data，并剥离不该传给原生库的键 */
const collectParams = (config: InternalAxiosRequestConfig): Record<string, unknown> => {
  const merged: Record<string, unknown> = { ...(config.params ?? {}) };
  const data = config.data;

  // POST 形态（/song/detail、/playlist/tracks、/song/order/update、/cloud）的载荷在 data 里。
  //
  // 注意：axios 的 transformRequest 在 adapter **之前**执行，普通对象到这里
  // 已经被 JSON.stringify 成字符串了，所以必须先解析。
  // 早期只判断 `typeof data === "object"` 导致 data 永远被忽略 ——
  // 表现为歌单/艺人页/我喜欢的音乐「有容器信息但列表为空」，
  // 因为这几处最终都要靠 /song/detail 把 ID 列表补成歌曲对象
  if (typeof data === "string") {
    try {
      const parsed = JSON.parse(data);
      if (parsed && typeof parsed === "object") Object.assign(merged, parsed);
    } catch {
      // 非 JSON 字符串（如已序列化的表单），原生库用不到，忽略
    }
  } else if (data && typeof data === "object" && !(data instanceof FormData)) {
    Object.assign(merged, data);
  }

  for (const key of [...FRONTEND_ONLY_PARAMS, ...SERVER_ONLY_PARAMS]) {
    delete merged[key];
  }
  return merged;
};

/**
 * 创建把请求改道到原生插件的 axios adapter
 *
 * 之所以用 adapter 而非改写 src/api/ 的调用：adapter 是 axios 内部唯一的传输层抽象，
 * 换掉它可以让 src/api/ 下 1804 行调用代码完全不动
 */
export const createNativeAdapter = (): AxiosAdapter => {
  // 刻意放在函数内而非模块顶层：registerPlugin 是副作用调用，
  // 置于顶层会让 Rollup 无法判定该模块可安全摇掉，导致插件名残留在其它端的产物里
  const NCMNative = registerPlugin<NCMNativePlugin>("NCMNative");

  return async (config: InternalAxiosRequestConfig): Promise<AxiosResponse> => {
    const route = config.url ?? "";
    const baseURL = config.baseURL ?? "";

    // 原生库不覆盖的接口，明确报错而非静默返回空数据
    for (const [prefix, name] of Object.entries(UNSUPPORTED_BASE_URLS)) {
      if (baseURL.startsWith(prefix)) {
        throw networkError(`iOS 端暂不支持${name}`, `${prefix}${route}`);
      }
    }

    // FormData 无法通过 Capacitor 的 JSON 桥传输
    if (config.data instanceof FormData) {
      throw networkError("iOS 端暂不支持文件上传", route);
    }

    // 请求发起前已被取消
    if (config.signal?.aborted) {
      throw networkError("请求已取消", route);
    }

    const params = collectParams(config);
    // 登录态：请求拦截器已把 MUSIC_U 拼成 `MUSIC_U=...;os=pc;` 放进 params.cookie
    const rawCookie = typeof params.cookie === "string" ? params.cookie : undefined;
    delete params.cookie;
    const cookie = withCsrf(rawCookie);

    // 原生调用无法真正中断，但要让 Promise 及时 settle，
    // 否则心动模式来回切换时会堆积悬挂的请求。
    // axios 的 GenericAbortSignal 里 addEventListener 是可选成员，故用可选调用
    const abortSignal = config.signal;
    const abortPromise = abortSignal
      ? new Promise<never>((_, reject) => {
          abortSignal.addEventListener?.("abort", () => reject(networkError("请求已取消", route)), {
            once: true,
          });
        })
      : undefined;

    let native: NativeApiResponse;
    try {
      const call = NCMNative.request({ route, params, cookie });
      native = abortPromise ? await Promise.race([call, abortPromise]) : await call;
    } catch (error) {
      throw networkError(error instanceof Error ? error.message : String(error), route);
    }

    return {
      data: native.body,
      status: native.status,
      statusText: String(native.status),
      headers: {},
      config,
      request: null,
    };
  };
};
