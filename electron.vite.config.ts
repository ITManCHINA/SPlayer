import vue from "@vitejs/plugin-vue";
import { execSync } from "child_process";
import { defineConfig, loadEnv } from "electron-vite";
import { readFileSync } from "fs";
import { resolve } from "path";
import AutoImport from "unplugin-auto-import/vite";
import { NaiveUiResolver } from "unplugin-vue-components/resolvers";
import Components from "unplugin-vue-components/vite";
import viteCompression from "vite-plugin-compression";
import type { MainEnv } from "./env";
// import VueDevTools from "vite-plugin-vue-devtools";
import wasm from "vite-plugin-wasm";

/** 获取当前 git 提交 */
const getGitCommit = (): string => {
  try {
    return execSync("git rev-parse HEAD").toString().trim().slice(0, 7) || "unknown";
  } catch {
    return "unknown";
  }
};

/** 获取当前 git 提交日期 */
const getGitDate = (): string => {
  try {
    return execSync("git log -1 --format=%cI").toString().trim() || "unknown";
  } catch {
    return "unknown";
  }
};

/**
 * 获取实际安装的 Capacitor 版本
 *
 * 读取 node_modules 中已安装的版本，而非 package.json 里声明的 `^x.y.z` 范围，
 * 因此升级依赖后无需改动此处
 */
const getCapacitorVersion = (): string => {
  try {
    const pkgPath = resolve(__dirname, "node_modules/@capacitor/core/package.json");
    return JSON.parse(readFileSync(pkgPath, "utf-8")).version || "unknown";
  } catch {
    return "unknown";
  }
};

const commonResolve = {
  alias: {
    "@": resolve(__dirname, "src/"),
    "@emi": resolve(__dirname, "native/external-media-integration"),
    "@shared": resolve(__dirname, "src/types/shared"),
    "@opencc": resolve(__dirname, "native/ferrous-opencc-wasm/pkg"),
    "@native": resolve(__dirname, "native"),
    "@windows": resolve(__dirname, "windows"),
  },
};

/**
 * 渲染进程构建目标覆盖（用于 iOS / Web 产物，未设置时沿用 electron-vite 默认值）
 *
 * 需使用 `es?` 或 `chrome?` 格式，否则 electron-vite 会输出告警
 * （`safari15` 虽被 esbuild 接受，但会触发 "not chrome? or es?" 告警）
 */
const buildTarget = process.env.SPLAYER_BUILD_TARGET;

export default defineConfig(({ mode }) => {
  // 读取环境变量
  const getEnv = (name: keyof MainEnv): string => {
    return loadEnv(mode, process.cwd())[name];
  };
  // 获取端口
  const webPort: number = Number(getEnv("VITE_WEB_PORT") || 14558);
  const servePort: number = Number(getEnv("VITE_SERVER_PORT") || 25884);
  // 返回配置
  return {
    // 主进程
    main: {
      build: {
        publicDir: resolve(__dirname, "public"),
        rollupOptions: {
          input: {
            index: resolve(__dirname, "electron/main/index.ts"),
            "workers/audio-analysis.worker": resolve(
              __dirname,
              "electron/main/workers/audio-analysis.worker.ts",
            ),
          },
        },
      },
      resolve: commonResolve,
    },
    // 预加载
    preload: {
      build: {
        rollupOptions: {
          input: {
            index: resolve(__dirname, "electron/preload/index.ts"),
          },
        },
      },
      resolve: commonResolve,
    },
    // 渲染进程
    renderer: {
      root: ".",
      define: {
        __COMMIT_HASH__: JSON.stringify(getGitCommit()),
        __COMMIT_DATE__: JSON.stringify(getGitDate()),
        __CAPACITOR_VERSION__: JSON.stringify(getCapacitorVersion()),
      },
      plugins: [
        vue(),
        // mode === "development" && VueDevTools(),
        AutoImport({
          imports: [
            "vue",
            "vue-router",
            "@vueuse/core",
            {
              "naive-ui": ["useDialog", "useMessage", "useNotification", "useLoadingBar"],
            },
          ],
          eslintrc: {
            enabled: true,
            filepath: "./auto-eslint.mjs",
          },
        }),
        Components({
          resolvers: [NaiveUiResolver()],
        }),
        viteCompression(),
        wasm(),
      ],
      resolve: commonResolve,
      css: {
        preprocessorOptions: {
          scss: {
            silenceDeprecations: ["legacy-js-api"],
          },
        },
      },
      server: {
        port: webPort,
        // 代理
        proxy: {
          "/api": {
            target: `http://127.0.0.1:${servePort}`,
            changeOrigin: true,
            rewrite: (path) => path.replace(/^\/api/, "/api"),
          },
        },
      },
      preview: {
        port: webPort,
      },
      build: {
        // 默认由 electron-vite 按 Electron 版本推导（Electron 43 会 fallback 到 chrome142）
        // 构建 iOS / Web 产物时用 SPLAYER_BUILD_TARGET 覆盖，避免语法不降级导致 WKWebView 解析失败
        ...(buildTarget ? { target: buildTarget } : {}),
        minify: "terser",
        publicDir: resolve(__dirname, "public"),
        rollupOptions: {
          input: {
            index: resolve(__dirname, "index.html"),
            loading: resolve(__dirname, "web/loading/index.html"),
            "taskbar-lyric": resolve(__dirname, "windows/taskbar-lyric/index.html"),
          },
          external: ["external-media-integration.node"],
          output: {
            manualChunks: {
              stores: ["src/stores/data.ts", "src/stores/index.ts"],
            },
          },
        },
        terserOptions: {
          compress: {
            pure_funcs: ["console.log"],
          },
        },
        sourcemap: false,
      },
    },
  };
});
